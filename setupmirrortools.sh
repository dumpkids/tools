#!/usr/bin/env bash
# ==============================================================================
# Script: setupmirror.sh
# Usage : curl -sSL https://raw.githubusercontent.com/dumpkids/tools/refs/heads/main/setupmirror.sh | sudo bash
# ==============================================================================

main() {
    set -euo pipefail

    # --- 1. Sudo Check ---
    if [[ "$EUID" -ne 0 ]]; then
        echo "🚨 ERROR: Eksekusi gagal. Silakan tambahkan 'sudo bash' di akhir perintah." >&2
        exit 1
    fi

    # --- 2. Variabel & Direktori ---
    MIRRORTOOL_DIR="/opt/mirrortool"
    LOG_DIR="${MIRRORTOOL_DIR}/log"
    SETUP_LOG="${LOG_DIR}/setup_$(date +%Y%m%d_%H%M%S).log"
    DOWNLOAD_URL="https://download.eset.com/com/eset/tools/protect/mirror/latest/mirrortool_linux_x86_64.zip"

    mkdir -p "$LOG_DIR"
    mkdir -p "${MIRRORTOOL_DIR}/temp"
    mkdir -p "${MIRRORTOOL_DIR}/dir"
    mkdir -p "${MIRRORTOOL_DIR}/download"

    # Alihkan output ke file log sekaligus tampil di layar
    exec > >(tee -a "$SETUP_LOG") 2>&1

    echo "==================================================="
    echo "🚀 Memulai Setup ESET Mirror Tool Win 7 ONLY"
    echo "==================================================="

    # --- 3. Install Dependensi ---
    echo "[*] Mengecek dependensi sistem..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y -q
    apt-get install -y -q wget unzip zip curl

    # --- 4. Download & Setup Master ESET ---
    echo "[*] Mendownload ESET Mirror Tool..."
    wget -q --show-progress -O "${MIRRORTOOL_DIR}/master.zip" "$DOWNLOAD_URL"
    unzip -o -q "${MIRRORTOOL_DIR}/master.zip" -d "${MIRRORTOOL_DIR}"
    chmod +x "${MIRRORTOOL_DIR}/MirrorTool"
    rm -f "${MIRRORTOOL_DIR}/master.zip"

    # --- 5. Generate update.sh secara On-the-Fly ---
    echo "[*] Membuat script cron (update.sh)..."
    cat << 'EOF' > "${MIRRORTOOL_DIR}/update.sh"
#!/usr/bin/env bash
set -euo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

MIRRORTOOL_DIR="/opt/mirrortool"
LOG_DIR="${MIRRORTOOL_DIR}/log"
UPDATE_LOG="${LOG_DIR}/update_$(date +\%Y\%m\%d).log"

exec >> "$UPDATE_LOG" 2>&1

echo "==================================================="
echo "🔄 Update Dimulai: $(date)"

# Rotasi Log (Hapus log lebih tua dari 30 hari)
find "$LOG_DIR" -name "update_*.log" -type f -mtime +30 -delete

OUTPUT_DIR="${MIRRORTOOL_DIR}/dir"
EP9_PARENT="${OUTPUT_DIR}/eset_upd"
EP9_DIR="${EP9_PARENT}/ep9"
DOWNLOAD_DIR="${MIRRORTOOL_DIR}/download"

# Eksekusi Mirror Tool
"${MIRRORTOOL_DIR}/MirrorTool" \
  --offlineLicenseFilename "${MIRRORTOOL_DIR}/offlinelicensemirrortools.lf" \
  --intermediateUpdateDirectory "${MIRRORTOOL_DIR}/temp" \
  --outputDirectory "${OUTPUT_DIR}" \
  --mirrorType regular \
  --excludedProducts ep6 ep7 ep8 ep10 ep11 ep12 ep13 era6 \
  --useSecureConnection

if [[ ! -d "$EP9_DIR" ]]; then
  echo "🚨 ERROR: Folder ep9 tidak ditemukan!" >&2
  exit 1
fi

mkdir -p "$DOWNLOAD_DIR"
find "$DOWNLOAD_DIR" -maxdepth 1 -type f -regextype posix-extended -regex '.*/[0-9]{12}\.zip' -delete

ZIPNAME="$(date +'%H%M%d%m%Y').zip"
ZIPPATH="${DOWNLOAD_DIR}/${ZIPNAME}"

cd "$EP9_PARENT"
zip -r "$ZIPPATH" "ep9" -q
chmod 775 "$ZIPPATH"

echo "✅ Berhasil -> $ZIPNAME dibuat."
echo "==================================================="
EOF

    chmod +x "${MIRRORTOOL_DIR}/update.sh"

    # --- 6. Setup Crontab ---
    echo "[*] Mendaftarkan jadwal Crontab (Setiap jam 21:00 WIB)..."
    CRON_JOB="0 21 * * * ${MIRRORTOOL_DIR}/update.sh"
    if crontab -l 2>/dev/null | grep -q "${MIRRORTOOL_DIR}/update.sh"; then
        echo "[!] Cronjob sudah terdaftar, melewati tahap ini."
    else
        (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
        echo "[+] Cronjob berhasil didaftarkan."
    fi

    # --- 7. Finalisasi ---
    echo "==================================================="
    echo "✅ Setup Selesai!"
    echo "📁 Direktori Instalasi: $MIRRORTOOL_DIR"
    echo ""
    echo "⚠️  LANGKAH TERAKHIR (WAJIB) ⚠️"
    echo "Upload file lisensi offline Anda ke server ini di lokasi:"
    echo "Cara GENERATE OFFLINE LISENSI https://help.eset.com/protect_hub/customer/en-US/create_offline_license_file.html"
    echo "👉 /opt/mirrortool/offlinelicensemirrortools.lf"
    echo "==================================================="
}

# Panggil fungsi utama
main "$@"
