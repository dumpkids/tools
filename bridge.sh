#!/bin/bash

# ==========================================
# 1. Pengecekan Akses Root (Sudo)
# ==========================================
if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Script ini membutuhkan akses root."
  echo "Silakan jalankan ulang dengan perintah: sudo $0"
  exit 1
fi

echo "======================================================"
echo "    ESET Bridge Auto-Setup & Optimization Script      "
echo "======================================================"

# ==========================================
# 2. Cek & Install ESET Bridge
# ==========================================
# Cek apakah layanan EsetBridge sudah terdaftar di systemd
if ! systemctl cat EsetBridge &> /dev/null; then
    echo "[INFO] ESET Bridge belum terinstal di sistem ini."
    echo "[INFO] Mengunduh installer ESET Bridge..."

    # Deteksi downloader yang tersedia (curl/wget)
    if command -v curl &> /dev/null; then
        curl -O https://download.eset.com/com/eset/apps/business/ech/latest/eset-bridge.x86_64.bin
    elif command -v wget &> /dev/null; then
        wget https://download.eset.com/com/eset/apps/business/ech/latest/eset-bridge.x86_64.bin
    else
        echo "[ERROR] 'curl' atau 'wget' tidak ditemukan. Gagal mengunduh installer."
        exit 1
    fi

    echo "[INFO] Menjalankan instalasi ESET Bridge..."
    chmod +x eset-bridge.x86_64.bin
    # Eksekusi installer (.bin akan menangani dependensi spesifik Ubuntu/Rocky secara otomatis)
    ./eset-bridge.x86_64.bin

    # Verifikasi apakah instalasi berhasil membentuk service
    if ! systemctl cat EsetBridge &> /dev/null; then
        echo "[ERROR] Instalasi gagal. Silakan periksa log instalasi secara manual."
        exit 1
    fi
    echo "[INFO] Instalasi ESET Bridge berhasil."

    # Membersihkan file installer
    rm -f eset-bridge.x86_64.bin
else
    echo "[INFO] ESET Bridge sudah terinstal. Melewati proses instalasi..."
fi

# ==========================================
# 3. Optimasi Jaringan TCP (sysctl)
# ==========================================
echo "[INFO] Menerapkan optimasi TCP untuk ESET Bridge..."
cat <<EOF > /etc/sysctl.d/99-eset-bridge.conf
# Optimasi TCP untuk ESET Bridge (1500 Endpoints)
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
EOF

# Terapkan konfigurasi sysctl secara langsung
sysctl -p /etc/sysctl.d/99-eset-bridge.conf

# ==========================================
# 4. Optimasi LimitNOFILE (Systemd Override)
# ==========================================
echo "[INFO] Meningkatkan LimitNOFILE menjadi 65535 pada systemd..."
# Membuat direktori override (ini adalah cara script melakukan 'systemctl edit')
mkdir -p /etc/systemd/system/EsetBridge.service.d
cat <<EOF > /etc/systemd/system/EsetBridge.service.d/override.conf
[Service]
LimitNOFILE=65535
EOF

# ==========================================
# 5. Reload & Restart Service
# ==========================================
echo "[INFO] Mereload daemon dan merestart layanan EsetBridge..."
systemctl daemon-reload
systemctl restart EsetBridge

# Memberikan waktu 2 detik agar layanan benar-benar hidup dan PID terbentuk
sleep 2

# ==========================================
# 6. Verifikasi Otomatis
# ==========================================
echo ""
echo "======================================================"
echo "                 HASIL VERIFIKASI                     "
echo "======================================================"

# Menarik Main PID langsung dari systemctl tanpa perlu grep manual
MAIN_PID=$(systemctl show -p MainPID --value EsetBridge)

if [ -z "$MAIN_PID" ] || [ "$MAIN_PID" -eq 0 ]; then
    echo "[ERROR] Layanan EsetBridge gagal berjalan. Cek dengan 'systemctl status EsetBridge'."
else
    echo "[OK] EsetBridge berjalan normal dengan PID: $MAIN_PID"
    echo "[OK] Limit 'Max open files' saat ini:"
    # Menampilkan limit berdasarkan PID yang ditemukan
    cat /proc/$MAIN_PID/limits | grep "Max open files"
fi
echo "======================================================"
