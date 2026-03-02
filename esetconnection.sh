#!/bin/bash

echo "========================================================="
echo "   Mengecek Konektivitas Server ESET (Paralel Mode)      "
echo "========================================================="

# Daftar target utama berdasarkan ESET KB332 & XDR/EDR Requirements
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

# Fungsi untuk mengecek satu target
check_target() {
    local target=$1
    
    if [[ "$target" == nc:* ]]; then
        # Mode Netcat untuk cek Host dan Port spesifik
        local host=$(echo "$target" | cut -d':' -f2)
        local port=$(echo "$target" | cut -d':' -f3)
        
        # -w 5 berarti timeout 5 detik
        if nc -vz -w 5 "$host" "$port" &> /dev/null; then
            printf "[\e[32m  OK  \e[0m] %-55s (via Netcat)\n" "$host:$port"
        else
            printf "[\e[31m FAIL \e[0m] %-55s (via Netcat)\n" "$host:$port"
        fi
    else
        # Mode cURL untuk cek URL HTTP/HTTPS
        # -m 5 berarti timeout 5 detik, -s untuk silent, -f untuk fail on error
        if curl -s -m 5 "$target" &> /dev/null; then
            printf "[\e[32m  OK  \e[0m] %-55s (via cURL)\n" "$target"
        else
            printf "[\e[31m FAIL \e[0m] %-55s (via cURL)\n" "$target"
        fi
    fi
}

echo "[INFO] Memulai pengecekan ke ${#TARGETS[@]} endpoint ESET..."
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
