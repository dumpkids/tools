#!/usr/bin/env bash

set -u

DEFAULT_DNS="1.1.1.1"
DEFAULT_DOMAIN="ecaserver.eset.com"

read_tty() {
  local prompt="$1"
  local default_value="$2"
  local result=""

  if [ -r /dev/tty ]; then
    printf "%s [%s]: " "$prompt" "$default_value" > /dev/tty
    IFS= read -r result < /dev/tty
  else
    printf "%s [%s]: " "$prompt" "$default_value"
    IFS= read -r result
  fi

  if [ -z "$result" ]; then
    result="$default_value"
  fi

  echo "$result"
}

section() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

DNS_SERVER="$(read_tty 'Masukkan IP DNS yang mau dites' "$DEFAULT_DNS")"
DOMAIN="$(read_tty 'Masukkan domain yang mau dites' "$DEFAULT_DOMAIN")"

section "Informasi Test"
echo "DNS server target : $DNS_SERVER"
echo "Domain target     : $DOMAIN"
echo "Mode              : test only, tidak mengubah konfigurasi DNS"

section "DNS resolver saat ini"
if [ -f /etc/resolv.conf ]; then
  cat /etc/resolv.conf
else
  echo "/etc/resolv.conf tidak ditemukan"
fi

section "Route ke DNS target"
if command -v ip >/dev/null 2>&1; then
  ip route get "$DNS_SERVER" 2>/dev/null || echo "Tidak bisa membaca route ke $DNS_SERVER"
else
  echo "Command 'ip' tidak tersedia"
fi

section "Cek tools"
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 tidak ditemukan."
  echo "Script ini butuh python3 untuk melakukan DNS UDP query tanpa install dnsutils."
  exit 1
fi

echo "python3: OK"

section "Test DNS langsung ke $DNS_SERVER"

DNS_SERVER="$DNS_SERVER" DOMAIN="$DOMAIN" python3 - <<'PY'
import os
import socket
import random
import struct
import ipaddress
import sys

dns_server = os.environ.get("DNS_SERVER", "").strip()
domain = os.environ.get("DOMAIN", "").strip().rstrip(".")

try:
    ip_obj = ipaddress.ip_address(dns_server)
except Exception:
    print(f"ERROR: DNS server '{dns_server}' bukan IP address yang valid")
    sys.exit(2)

family = socket.AF_INET6 if ip_obj.version == 6 else socket.AF_INET
server = (dns_server, 53)

def build_query(domain):
    tid = random.randint(0, 65535)
    header = struct.pack("!HHHHHH", tid, 0x0100, 1, 0, 0, 0)
    qname = b"".join(bytes([len(part)]) + part.encode() for part in domain.split(".")) + b"\x00"
    question = qname + struct.pack("!HH", 1, 1)  # A record, IN
    return tid, header + question

def read_name(data, offset):
    labels = []
    jumped = False
    original_offset = offset
    seen = set()

    while True:
        if offset >= len(data):
            return ".", offset + 1

        length = data[offset]

        if length == 0:
            offset += 1
            break

        if (length & 0xC0) == 0xC0:
            if offset + 1 >= len(data):
                break
            pointer = ((length & 0x3F) << 8) | data[offset + 1]
            if pointer in seen:
                break
            seen.add(pointer)
            if not jumped:
                original_offset = offset + 2
            offset = pointer
            jumped = True
            continue

        offset += 1
        labels.append(data[offset:offset + length].decode(errors="ignore"))
        offset += length

    return ".".join(labels), (original_offset if jumped else offset)

def parse_response(data, tid):
    if len(data) < 12:
        return {"ok": False, "error": "Response terlalu pendek"}

    r_tid, flags, qd, an, ns, ar = struct.unpack("!HHHHHH", data[:12])
    if r_tid != tid:
        return {"ok": False, "error": "Transaction ID tidak cocok"}

    rcode = flags & 0xF
    offset = 12

    for _ in range(qd):
        _, offset = read_name(data, offset)
        offset += 4

    ips = []
    for _ in range(an):
        _, offset = read_name(data, offset)
        if offset + 10 > len(data):
            break

        rtype, rclass, ttl, rdlen = struct.unpack("!HHIH", data[offset:offset + 10])
        offset += 10
        rdata = data[offset:offset + rdlen]
        offset += rdlen

        if rtype == 1 and rclass == 1 and rdlen == 4:
            ips.append(socket.inet_ntoa(rdata))

    return {
        "ok": True,
        "rcode": rcode,
        "answers": an,
        "a_records": ips
    }

def udp_test():
    tid, packet = build_query(domain)
    sock = socket.socket(family, socket.SOCK_DGRAM)
    sock.settimeout(5)

    try:
        sock.sendto(packet, server)
        data, addr = sock.recvfrom(4096)
        result = parse_response(data, tid)

        print("UDP/53 result:")
        print(f"  Reply from : {addr[0]}:{addr[1]}")

        if not result["ok"]:
            print(f"  Status     : FAILED")
            print(f"  Error      : {result['error']}")
            return False

        print(f"  RCODE      : {result['rcode']}")
        print(f"  Answers    : {result['answers']}")

        if result["a_records"]:
            print("  A records  : " + ", ".join(result["a_records"]))
            print("  Status     : OK")
            return True

        if result["rcode"] == 3:
            print("  Status     : DNS reachable, tapi domain NXDOMAIN")
            return True

        print("  Status     : DNS reachable, tapi tidak ada A record")
        return True

    except socket.timeout:
        print("UDP/53 result:")
        print("  Status     : TIMEOUT")
        print("  Meaning    : UDP DNS ke target kemungkinan diblok / tidak ada response")
        return False
    except Exception as e:
        print("UDP/53 result:")
        print(f"  Status     : ERROR")
        print(f"  Error      : {e}")
        return False
    finally:
        sock.close()

def tcp_test():
    tid, packet = build_query(domain)
    payload = struct.pack("!H", len(packet)) + packet

    sock = socket.socket(family, socket.SOCK_STREAM)
    sock.settimeout(5)

    try:
        sock.connect(server)
        sock.sendall(payload)

        length_data = sock.recv(2)
        if len(length_data) < 2:
            print("TCP/53 result:")
            print("  Status     : FAILED")
            print("  Error      : Tidak menerima DNS length header")
            return False

        length = struct.unpack("!H", length_data)[0]
        data = b""

        while len(data) < length:
            chunk = sock.recv(length - len(data))
            if not chunk:
                break
            data += chunk

        result = parse_response(data, tid)

        print()
        print("TCP/53 result:")

        if not result["ok"]:
            print("  Status     : FAILED")
            print(f"  Error      : {result['error']}")
            return False

        print(f"  RCODE      : {result['rcode']}")
        print(f"  Answers    : {result['answers']}")

        if result["a_records"]:
            print("  A records  : " + ", ".join(result["a_records"]))
            print("  Status     : OK")
            return True

        if result["rcode"] == 3:
            print("  Status     : DNS reachable, tapi domain NXDOMAIN")
            return True

        print("  Status     : DNS reachable, tapi tidak ada A record")
        return True

    except socket.timeout:
        print()
        print("TCP/53 result:")
        print("  Status     : TIMEOUT")
        print("  Meaning    : TCP DNS ke target kemungkinan diblok / tidak ada response")
        return False
    except Exception as e:
        print()
        print("TCP/53 result:")
        print("  Status     : ERROR")
        print(f"  Error      : {e}")
        return False
    finally:
        sock.close()

udp_ok = udp_test()
tcp_ok = tcp_test()

print()
print("Final verdict:")

if udp_ok:
    print(f"  OK: DNS UDP/53 ke {dns_server} berhasil.")
    print("  Artinya outbound DNS normal tidak diblok dari server ini ke DNS target.")
elif tcp_ok:
    print(f"  PARTIAL: UDP/53 gagal, tapi TCP/53 ke {dns_server} berhasil.")
    print("  Artinya UDP DNS kemungkinan diblok, tapi TCP DNS masih bisa.")
else:
    print(f"  FAILED: UDP/53 dan TCP/53 ke {dns_server} gagal.")
    print("  Artinya DNS langsung ke luar kemungkinan diblok / tidak reachable dari server ini.")

PY

section "Test resolver sistem saat ini"
if command -v getent >/dev/null 2>&1; then
  echo "Mengetes resolve via DNS sistem saat ini:"
  if getent hosts "$DOMAIN"; then
    echo "System resolver: OK"
  else
    echo "System resolver: FAILED"
  fi
else
  echo "Command getent tidak tersedia"
fi

section "Selesai"
echo "Script ini hanya melakukan pengecekan. Tidak ada konfigurasi DNS yang diubah."
