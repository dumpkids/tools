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
# 3. Konfigurasi Direktori & Rotasi Log
# ==========================================
LOG_DIR="$PWD"
LATEST_LOG="$LOG_DIR/iotest.log"
TEST_FILE="testfile.dat"

if [ -f "$LATEST_LOG" ]; then
    i=1
    while [ -f "$LOG_DIR/iotest${i}.log" ]; do
        ((i++))
    done
    mv "$LATEST_LOG" "$LOG_DIR/iotest${i}.log"
    echo "[INFO] Log pengujian sebelumnya diarsipkan ke: $LOG_DIR/iotest${i}.log"
fi

# ==========================================
# 4. Eksekusi Pengujian (60 Detik)
# ==========================================
echo "[INFO] Memulai pengujian disk IOPS dengan fio..."
echo "[INFO] Proses ini memakan waktu tepat 60 detik (1 menit), silakan tunggu..."

fio --name=test_eset \
    --filename="$TEST_FILE" \
    --size=1000M \
    --bs=4k \
    --runtime=60 \
    --time_based \
    --direct=1 \
    --rw=randrw \
    --rwmixwrite=50 \
    --ioengine=libaio \
    --iodepth=1 \
    --scramble_buffers=1 > "$LATEST_LOG" 2>&1

# ==========================================
# 5. Menampilkan Ringkasan & Pembersihan
# ==========================================
echo ""
echo "============================================="
echo "          RINGKASAN HASIL PENGUJIAN          "
echo "============================================="
grep -E "read: IOPS=|write: IOPS=" "$LATEST_LOG" | sed 's/^[ \t]*//'
echo "============================================="
echo "[INFO] Detail log lengkap tersimpan di: $LATEST_LOG"

# Menghapus file dummy 1GB agar tidak memenuhi disk
if [ -f "$TEST_FILE" ]; then
    rm -f "$TEST_FILE"
    echo "[INFO] File temporary pengujian ($TEST_FILE) telah dihapus."
fi
