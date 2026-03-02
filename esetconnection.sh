#!/bin/bash

echo "========================================================="
echo "   Mengecek Konektivitas Server ESET (Paralel Mode)      "
echo "========================================================="

# ==========================================
# 1. Pengecekan Dependency (curl & netcat)
# ==========================================
MISSING_PKGS=""
if ! command -v curl &> /dev/null; then
    MISSING_PKGS+="curl "
fi
if ! command -v nc &> /dev/null; then
    MISSING_PKGS+="netcat "
fi

if [ -n "$MISSING_PKGS" ]; then
    echo "[INFO] Script ini membutuhkan dependency yang belum terinstall: $MISSING_PKGS"
    read -p "Apakah Anda ingin menginstall dependency tersebut sekarang? (y/n): " INSTALL_DEPS
    
    if [[ "$INSTALL_DEPS" =~ ^[Yy]$ ]]; then
        # Instalasi membutuhkan akses root
        if [ "$EUID" -ne 0 ]; then
            echo "[ERROR] Proses instalasi membutuhkan akses root."
            echo "Silakan jalankan ulang script ini dengan perintah: sudo $0"
            exit 1
        fi
        
        echo "[INFO] Mendeteksi OS dan memulai instalasi tanpa proxy..."
        if command -v apt-get &> /dev/null; then
            apt-get update -yq
            apt-get install -yq curl netcat
        elif command -v dnf &> /dev/null; then
            dnf install -yq curl nc
        elif command -v yum &> /dev/null; then
            yum install -yq curl nc
        else
            echo "[ERROR] Package manager tidak dikenali. Silakan install $MISSING_PKGS secara manual."
            exit 1
        fi
        
        # Verifikasi apakah instalasi benar-benar berhasil
        if ! command -v curl &> /dev/null || ! command -v nc &> /dev/null; then
            echo "[ERROR] Instalasi gagal. Silakan periksa koneksi internet server Anda."
            exit 1
        fi
        echo "[INFO] Semua dependency berhasil diinstall!"
        echo "---------------------------------------------------------"
    else
        echo "[ERROR] Script tidak dapat dilanjutkan tanpa dependency tersebut. Dibatalkan."
        exit 1
    fi
fi

# ==========================================
# 2. Interaksi Tanya Jawab Proxy
# ==========================================
read -p "Apakah ingin cek via proxy? (y/n): " USE_PROXY

if [[ "$USE_PROXY" =~ ^[Yy]$ ]]; then
    read -p "IP Proxy: " PROXY_IP
    read -p "Port Proxy: " PROXY_PORT
    read -p "Username (kosongkan jika tidak ada): " PROXY_USER
    read -s -p "Password (kosongkan jika tidak ada): " PROXY_PASS
    echo "" # Memunculkan baris baru setelah mengetik password yang disembunyikan
    
    # Format argumen proxy untuk curl
    if [[ -n "$PROXY_USER" ]]; then
        PROXY_ARGS="-x http://$PROXY_USER:$PROXY_PASS@$PROXY_IP:$PROXY_PORT"
    else
        PROXY_ARGS="-x http://$PROXY_IP:$PROXY_PORT"
    fi
    echo "[INFO] Mode Proxy AKTIF menggunakan $PROXY_IP:$PROXY_PORT"
else
    PROXY_ARGS=""
    echo "[INFO] Mode Proxy NONAKTIF"
fi
echo "---------------------------------------------------------"

# ==========================================
# 3. Daftar Target URL/Port
# ==========================================
TARGETS=(
  # --- 1. Module Updates & Repositories (Port 80) ---
  "http://update.eset.com"
  "http://eu-update.eset.com"
  "http://us-update.eset.com"
  "http://repository.eset.com"
  "http://pki.eset.com"

  # --- 2. Downloads ---
  "http://download.eset.com"
  "https://eu.download.protect.eset.com"

  # --- 3. Aktivasi & Data Framework (Port 443) ---
  "https://edf.eset.com"
  "https://iploc.eset.com"

  # --- 4. ESET PROTECT Management (Port 443) ---
  "https://protect.eset.com"
  "https://protecthub.eset.com"
  "https://identity.eset.com"

  # --- 5. ESET Inspect / XDR / EDR ---
  "nc:eu01.server.xdr.eset.systems:443"
  "nc:eu01.agent.edr.eset.systems:8093"
  "nc:epx-k8s-prod-eu-a.westeurope.cloudapp.azure.com:444"

  # --- 6. ESET Push Notification Service (Port 8883) ---
  "nc:epns.eset.com:8883"
  
  # --- 7. ESET LiveGrid & LiveGuard ---
  "nc:avcloud.e5.sk:53535"               # LiveGrid DNS/UDP/TCP
  "http://livegrid.eset.systems"         # LiveGrid Reputation
  "http://augur.scanners.eset.systems"   # LiveGuard / Advanced Machine Learning

  # --- 8. ESET Bridge Whitelisting (Port 443) ---
  "nc:login.microsoftonline.com:443"
)

# ==========================================
# 4. Fungsi untuk mengecek satu target
# ==========================================
check_target() {
    local target=$1
    
    if [[ "$target" == nc:* ]]; then
        # Memisahkan host dan port
        local host=$(echo "$target" | cut -d':' -f2)
        local port=$(echo "$target" | cut -d':' -f3)
        
        if [[ "$USE_PROXY" =~ ^[Yy]$ ]]; then
            # Jika pakai proxy, gunakan trik cURL CONNECT untuk mengecek port TCP.
            if curl -s -v -m 5 $PROXY_ARGS "https://$host:$port" 2>&1 | grep -qi "200 Connection established"; then
                printf "[\e[32m  OK  \e[0m] %-55s (via Proxy cURL)\n" "$host:$port"
            else
                printf "[\e[31m FAIL \e[0m] %-55s (via Proxy cURL)\n" "$host:$port"
            fi
        else
            # Jika normal tanpa proxy, gunakan Netcat
            if nc -vz -w 5 "$host" "$port" &> /dev/null; then
                printf "[\e[32m  OK  \e[0m] %-55s (via Netcat)\n" "$host:$port"
            else
                printf "[\e[31m FAIL \e[0m] %-55s (via Netcat)\n" "$host:$port"
            fi
        fi
    else
        # Mode cURL untuk cek URL HTTP/HTTPS (Argumen proxy otomatis disisipkan jika aktif)
        if curl -s -m 5 $PROXY_ARGS "$target" &> /dev/null; then
            if [[ "$USE_PROXY" =~ ^[Yy]$ ]]; then
                printf "[\e[32m  OK  \e[0m] %-55s (via Proxy cURL)\n" "$target"
            else
                printf "[\e[32m  OK  \e[0m] %-55s (via cURL)\n" "$target"
            fi
        else
            if [[ "$USE_PROXY" =~ ^[Yy]$ ]]; then
                printf "[\e[31m FAIL \e[0m] %-55s (via Proxy cURL)\n" "$target"
            else
                printf "[\e[31m FAIL \e[0m] %-55s (via cURL)\n" "$target"
            fi
        fi
    fi
}

echo "[INFO] Memulai pengecekan ke ${#TARGETS[@]} url ESET..."
echo "---------------------------------------------------------"

# Mengeksekusi semua pengecekan secara paralel
for target in "${TARGETS[@]}"; do
    check_target "$target" &
done

# Menunggu semua proses background (&) selesai
wait

echo "---------------------------------------------------------"
echo "Pengecekan selesai."
echo "========================================================="
