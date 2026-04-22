#!/usr/bin/env bash
# ==============================================================================
# Script: setup_httpserver.sh
# Usage : curl -sSL https://raw.githubusercontent.com/username/repo/main/setup_httpserver.sh | sudo bash
# ==============================================================================

main() {
    set -euo pipefail

    # --- 1. Sudo Check ---
    if [[ "$EUID" -ne 0 ]]; then
        echo "🚨 ERROR: Eksekusi gagal. Silakan tambahkan 'sudo bash' di akhir perintah." >&2
        exit 1
    fi

    # --- 2. Setup Logging di Current Directory ---
    CURRENT_DIR=$(pwd)
    LOG_FILE="${CURRENT_DIR}/setup_httpserver_$(date +%Y%m%d_%H%M%S).log"
    
    # Alihkan output ke layar dan ke file log
    exec > >(tee -a "$LOG_FILE") 2>&1

    echo "==================================================="
    echo "🚀 Setup ESET Mirror HTTP Server via Python"
    echo "==================================================="

    # --- 3. Install Dependensi ---
    echo "[*] Mengecek dependensi (python3, iproute2 untuk cek port)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y -q
    apt-get install -y -q python3 iproute2

    # --- 4. Interactive Port Input (Dengan /dev/tty bypass) ---
    while true; do
        echo ""
        # < /dev/tty WAJIB ada agar prompt bisa muncul saat script di-pipe via curl
        read -p "👉 Masukkan port yang ingin digunakan (1-65535): " HTTP_PORT < /dev/tty

        # Cek jika kosong
        if [[ -z "$HTTP_PORT" ]]; then
            echo "❌ ERROR: Port tidak boleh kosong. Silakan input ulang."
            continue
        fi

        # Cek apakah inputan murni angka dan berada di range 1 - 65535
        if [[ ! "$HTTP_PORT" =~ ^[0-9]+$ ]] || [ "$HTTP_PORT" -lt 1 ] || [ "$HTTP_PORT" -gt 65535 ]; then
            echo "❌ ERROR: Invalid! Masukkan hanya angka antara 1 hingga 65535."
            continue
        fi

        # Cek apakah port sudah dipakai oleh aplikasi lain (menggunakan 'ss')
        if ss -tuln | grep -q ":${HTTP_PORT} "; then
            echo "❌ ERROR: Port $HTTP_PORT sedang DENGAN DIPAKAI oleh aplikasi lain!"
            echo "Silakan pilih port yang berbeda."
            continue
        fi

        echo "✅ Port $HTTP_PORT valid dan tersedia."
        break
    done

    # --- 5. Konfigurasi Firewall Otomatis ---
    echo "[*] Mengecek status Firewall di server..."
    
    # Deteksi UFW (Ubuntu/Debian)
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then
        echo "[+] UFW terdeteksi AKTIF. Menambahkan allow port $HTTP_PORT/tcp..."
        ufw allow "$HTTP_PORT"/tcp
        
    # Deteksi Firewalld (CentOS/RHEL/Rocky)
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        echo "[+] Firewalld terdeteksi AKTIF. Menambahkan allow port $HTTP_PORT/tcp..."
        firewall-cmd --add-port="$HTTP_PORT"/tcp --permanent
        firewall-cmd --reload
        
    # Fallback ke Iptables dasar jika ada
    elif command -v iptables >/dev/null 2>&1; then
        echo "[!] UFW/Firewalld tidak aktif. Menambahkan rule iptables sementara..."
        iptables -I INPUT -p tcp --dport "$HTTP_PORT" -j ACCEPT
    else
        echo "[!] Tidak ada firewall aktif yang terdeteksi. Melewati konfigurasi firewall."
    fi

    # --- 6. Setup Systemd Service ---
    echo "[*] Membuat Systemd Service untuk Python HTTP Server..."
    MIRRORTOOL_DIR="/opt/mirrortool"
    TARGET_DIR="${MIRRORTOOL_DIR}/dir"

    # Buat foldernya jika belum dibuat oleh script setup sebelumnya
    mkdir -p "$TARGET_DIR"

    cat << EOF > /etc/systemd/system/eset-mirror-http.service
[Unit]
Description=ESET Mirror HTTP Server (Python)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${TARGET_DIR}
ExecStart=/usr/bin/python3 -m http.server ${HTTP_PORT}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    echo "[*] Mengaktifkan dan menjalankan service HTTP..."
    systemctl daemon-reload
    systemctl enable eset-mirror-http.service
    systemctl restart eset-mirror-http.service

    # --- 7. Finalisasi ---
    # Mengambil IP Public/Private utama dari server
    SERVER_IP=$(hostname -I | awk '{print $1}')

    echo "==================================================="
    echo "✅ Setup HTTP Server Selesai!"
    echo "🌐 Akses ESET Update di : http://${SERVER_IP}:${HTTP_PORT}/eset_upd/"
    echo "🌐 Akses Folder ZIP di  : http://${SERVER_IP}:${HTTP_PORT}/download/"
    echo "📁 File Log tersimpan di: $LOG_FILE"
    echo "==================================================="
}

# Panggil fungsi utama
main "$@"
