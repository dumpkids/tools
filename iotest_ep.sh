#!/bin/bash

# ==========================================
# 1. Pengecekan Akses Root (Sudo)
# ==========================================
if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Script ini membutuhkan akses penuh ke sistem penyimpanan."
  echo "Silakan jalankan ulang dengan perintah: sudo $0"
  exit 1
fi

# ==========================================
# 2. Pengecekan OS dan Instalasi 'fio'
# ==========================================
if ! command -v fio &> /dev/null; then
    echo "[INFO] Aplikasi 'fio' belum terinstal di sistem ini."
    echo "[INFO] Mendeteksi jenis sistem operasi untuk instalasi otomatis..."

    if command -v apt-get &> /dev/null; then
        echo "[INFO] OS terdeteksi: Ubuntu/Debian. Menggunakan apt-get..."
        apt-get update -yq
        apt-get install fio -yq
    elif command -v dnf &> /dev/null; then
        echo "[INFO] OS terdeteksi: Rocky/RHEL/CentOS 8+. Menggunakan dnf..."
        dnf install fio -yq
    elif command -v yum &> /dev/null; then
        echo "[INFO] OS terdeteksi: CentOS/RHEL Lama. Menggunakan yum..."
        yum install fio -yq
    else
        echo "[ERROR] Package manager (apt/dnf/yum) tidak ditemukan."
        echo "Silakan install 'fio' secara manual."
        exit 1
    fi

    # Memastikan instalasi benar-benar berhasil sebelum lanjut
    if ! command -v fio &> /dev/null; then
        echo "[ERROR] Gagal menginstal 'fio'. Pastikan VM ini memiliki koneksi internet."
        exit 1
    fi
    echo "[INFO] 'fio' berhasil diinstal. Melanjutkan proses..."
    echo "---------------------------------------------"
fi

# ==========================================
# 3. Konfigurasi Direktori & File
# ==========================================
LOG_DIR="$PWD"
LATEST_LOG="$LOG_DIR/eset_realworld_result.txt"
TEST_FILE="/var/lib/mysql/testfile.dat"

# Cek apakah direktori /var/lib/mysql ada, jika tidak gunakan fallback
if [ ! -d "/var/lib/mysql" ]; then
    echo "[WARNING] Direktori /var/lib/mysql tidak ditemukan."
    echo "[INFO] Menggunakan direktori saat ini sebagai fallback..."
    TEST_FILE="$PWD/testfile.dat"
fi

# Rotasi log jika sudah ada
if [ -f "$LATEST_LOG" ]; then
    i=1
    while [ -f "$LOG_DIR/eset_realworld_result${i}.txt" ]; do
        ((i++))
    done
    mv "$LATEST_LOG" "$LOG_DIR/eset_realworld_result${i}.txt"
    echo "[INFO] Log pengujian sebelumnya diarsipkan ke: $LOG_DIR/eset_realworld_result${i}.txt"
fi

# ==========================================
# 4. Eksekusi Pengujian (120 Detik - Real World)
# ==========================================
echo "[INFO] Memulai pengujian disk IOPS dengan FIO (Real-World / Incompressible)..."
echo "[INFO] Proses ini memakan waktu tepat 120 detik (2 menit), silakan tunggu..."
echo "[INFO] File test: $TEST_FILE"
echo "[INFO] Mode: Random 4KB, 50% Read / 50% Write (Incompressible Data)"
echo ""

fio --name=eset_production_real \
    --filename="$TEST_FILE" \
    --size=1000M \
    --bs=4k \
    --runtime=120 \
    --time_based \
    --direct=1 \
    --rw=randrw \
    --rwmixwrite=50 \
    --randrepeat=0 \
    --refill_buffers \
    --ioengine=libaio \
    --iodepth=1 \
    --output="$LATEST_LOG" 2>&1

# ==========================================
# 5. Menampilkan Ringkasan & Pembersihan
# ==========================================
echo ""
echo "============================================="
echo "       RINGKASAN HASIL PENGUJIAN (REAL)      "
echo "============================================="
if [ -f "$LATEST_LOG" ]; then
    grep -E "read: IOPS=|write: IOPS=" "$LATEST_LOG" | sed 's/^[ \t]*//'
    echo ""
    grep -E "READ: bw=|WRITE: bw=" "$LATEST_LOG" | sed 's/^[ \t]*//'
else
    echo "[ERROR] File log tidak ditemukan."
fi
echo "============================================="
echo "[INFO] Detail log lengkap tersimpan di: $LATEST_LOG"

# Menghapus file dummy agar tidak memenuhi disk
if [ -f "$TEST_FILE" ]; then
    rm -f "$TEST_FILE"
    echo "[INFO] File temporary pengujian ($TEST_FILE) telah dihapus."
fi

echo ""
echo "[NOTE] Hasil ini mensimulasikan beban kerja database MySQL/ESET sebenarnya"
echo "[NOTE] (incompressible data). Gunakan hasil ini untuk capacity planning,"
echo "[NOTE] bukan untuk validasi vendor (yang menggunakan zero/compressible data)."
