#!/usr/bin/env bash

set -Eeuo pipefail

# ESET PROTECT database storage IOPS check for Ubuntu/Debian.
# Reads the database connection from StartupConfiguration.ini at runtime.
# The database password is never printed or written to the result file.

CONFIG_FILE="${ESET_STARTUP_CONFIG:-/etc/opt/eset/RemoteAdministrator/Server/StartupConfiguration.ini}"
TEST_SIZE_MIB=1000
TEST_SIZE_BYTES=$((TEST_SIZE_MIB * 1024 * 1024))
TEST_RUNTIME=120
MIN_FREE_PERCENT_AFTER_TEST=10

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_SOURCE" && -f "$SCRIPT_SOURCE" ]]; then
    SCRIPT_PATH="$(readlink -f -- "$SCRIPT_SOURCE")"
    SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
else
    # When invoked through `curl ... | sudo bash`, there is no script file.
    # Save the result in the directory from which the pipeline was run.
    SCRIPT_PATH=""
    SCRIPT_DIR="$PWD"
fi
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
RESULT_FILE="${SCRIPT_DIR}/eset-fio-result-${TIMESTAMP}.txt"

TEST_FILE=""
TEST_FILE_OWNED=0
RESULT_CREATED=0
DB_PASS=""

log() {
    printf '%s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup_on_exit() {
    local exit_code=$?

    DB_PASS=""
    unset MYSQL_PWD 2>/dev/null || true

    if (( TEST_FILE_OWNED == 1 )) && [[ -n "$TEST_FILE" && -e "$TEST_FILE" ]]; then
        rm -f -- "$TEST_FILE" || printf 'WARNING: Gagal menghapus file tes: %s\n' "$TEST_FILE" >&2
    fi

    if (( RESULT_CREATED == 1 )) && [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
        chown "${SUDO_UID}:${SUDO_GID}" "$RESULT_FILE" 2>/dev/null || true
    fi

    return "$exit_code"
}
trap cleanup_on_exit EXIT

trim() {
    local value=$1
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# Split an ODBC connection string on semicolons that are outside {...}.
# Prints one key=value pair per line.
split_odbc_connection_string() {
    local input=$1 token="" char next
    local in_braces=0
    local i

    for ((i = 0; i < ${#input}; i++)); do
        char="${input:i:1}"

        if [[ "$char" == "{" && $in_braces -eq 0 ]]; then
            in_braces=1
            token+="$char"
            continue
        fi

        if [[ "$char" == "}" && $in_braces -eq 1 ]]; then
            next="${input:i+1:1}"
            if [[ "$next" == "}" ]]; then
                token+="}}"
                ((i += 1))
            else
                in_braces=0
                token+="$char"
            fi
            continue
        fi

        if [[ "$char" == ";" && $in_braces -eq 0 ]]; then
            printf '%s\n' "$token"
            token=""
        else
            token+="$char"
        fi
    done

    [[ -z "$token" ]] || printf '%s\n' "$token"
}

odbc_value() {
    local wanted=${1,,}
    local pair key value

    while IFS= read -r pair; do
        [[ "$pair" == *=* ]] || continue
        key="$(trim "${pair%%=*}")"
        value="$(trim "${pair#*=}")"
        if [[ "${key,,}" == "$wanted" ]]; then
            printf '%s' "$value"
            return 0
        fi
    done < <(split_odbc_connection_string "$DB_CONNECTION_STRING")

    return 1
}

odbc_value_any() {
    local key value

    for key in "$@"; do
        if value="$(odbc_value "$key")"; then
            printf '%s' "$value"
            return 0
        fi
    done

    return 1
}

# Decode an ODBC braced value and ESET-style backslash escapes.
# Examples: {p@ss;word} -> p@ss;word, {\@secret} -> @secret,
# and {one\\two} -> one\two. No eval is used.
decode_odbc_value() {
    local value=$1 output="" char
    local i

    if (( ${#value} >= 2 )) && [[ "${value:0:1}" == "{" && "${value: -1}" == "}" ]]; then
        value="${value:1:${#value}-2}"
        value="${value//\}\}/\}}"
    fi

    for ((i = 0; i < ${#value}; i++)); do
        char="${value:i:1}"
        if [[ "$char" == "\\" && $((i + 1)) -lt ${#value} ]]; then
            ((i += 1))
            output+="${value:i:1}"
        else
            output+="$char"
        fi
    done

    printf '%s' "$output"
}

human_bytes() {
    numfmt --to=iec-i --suffix=B "$1"
}

confirm() {
    local prompt=$1 answer
    read -r -p "$prompt" answer
    [[ "$answer" == "JALANKAN" ]]
}

find_real_fio() {
    local candidate version
    local -a candidates=(/usr/bin/fio)

    if command -v fio >/dev/null 2>&1; then
        candidates+=("$(command -v fio)")
    fi

    for candidate in "${candidates[@]}"; do
        [[ -x "$candidate" ]] || continue
        version="$($candidate --version 2>/dev/null || true)"
        if [[ "$version" == fio-* ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    return 1
}

if (( EUID != 0 )); then
    log "Skrip memerlukan akses root untuk membaca konfigurasi ESET dan menguji storage database."
    if [[ -n "$SCRIPT_PATH" ]]; then
        exec sudo -- "$SCRIPT_PATH" "$@"
    fi
    die "Untuk eksekusi melalui pipeline, gunakan: curl ... | sudo bash"
fi

[[ -r "$CONFIG_FILE" ]] || die "Konfigurasi ESET tidak dapat dibaca: $CONFIG_FILE"

if ! command -v numfmt >/dev/null 2>&1; then
    die "Perintah numfmt tidak ditemukan (paket coreutils diperlukan)."
fi

FIO_BIN="$(find_real_fio || true)"
if [[ -z "$FIO_BIN" ]]; then
    log "fio belum terpasang."
    if command -v apt-get >/dev/null 2>&1; then
        read -r -p "Instal fio sekarang menggunakan apt-get? [y/N]: " INSTALL_ANSWER
        if [[ "${INSTALL_ANSWER,,}" == "y" || "${INSTALL_ANSWER,,}" == "yes" ]]; then
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y fio
            FIO_BIN="$(find_real_fio || true)"
        else
            die "Pengujian dibatalkan karena fio belum terpasang."
        fi
    else
        die "fio belum terpasang dan apt-get tidak tersedia. Instal fio lalu jalankan kembali."
    fi
fi

[[ -n "$FIO_BIN" && -x "$FIO_BIN" ]] || die "Flexible I/O Tester (fio) tidak ditemukan setelah instalasi."

if ! "$FIO_BIN" --enghelp 2>/dev/null | awk '$1 == "libaio" {found=1} END {exit !found}'; then
    die "fio tidak menyediakan ioengine libaio yang diperlukan oleh pengujian ESET."
fi

if command -v mariadb >/dev/null 2>&1; then
    DB_CLIENT="$(command -v mariadb)"
elif command -v mysql >/dev/null 2>&1; then
    DB_CLIENT="$(command -v mysql)"
else
    die "Client MariaDB/MySQL tidak ditemukan. Instal mariadb-client atau mysql-client."
fi

DB_TYPE="$(awk '
    /^[[:space:]]*DatabaseType[[:space:]]*=/ {
        sub(/^[^=]*=[[:space:]]*/, "")
        print
        exit
    }
' "$CONFIG_FILE")"
DB_CONNECTION_STRING="$(awk '
    /^[[:space:]]*DatabaseConnectionString[[:space:]]*=/ {
        sub(/^[^=]*=[[:space:]]*/, "")
        print
        exit
    }
' "$CONFIG_FILE")"

[[ -n "$DB_CONNECTION_STRING" ]] || die "DatabaseConnectionString tidak ditemukan di $CONFIG_FILE"
[[ "${DB_TYPE,,}" == *mysql* || "${DB_TYPE,,}" == *maria* ]] || \
    die "DatabaseType bukan MySQL/MariaDB: ${DB_TYPE:-tidak diketahui}"

DB_HOST="$(decode_odbc_value "$(odbc_value_any Server Host || true)")"
DB_PORT="$(decode_odbc_value "$(odbc_value_any Port || true)")"
DB_NAME="$(decode_odbc_value "$(odbc_value_any Database DB || true)")"
DB_USER="$(decode_odbc_value "$(odbc_value_any Uid User 'User ID' Username || true)")"
DB_PASS="$(decode_odbc_value "$(odbc_value_any Pwd Password || true)")"

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"

[[ -n "$DB_NAME" ]] || die "Nama database tidak ditemukan dalam connection string."
[[ -n "$DB_USER" ]] || die "User database tidak ditemukan dalam connection string."
[[ "$DB_PORT" =~ ^[0-9]+$ ]] || die "Port database tidak valid: $DB_PORT"

DB_ERROR_FILE="$(mktemp)"
chmod 600 "$DB_ERROR_FILE"

set +e
DB_DATADIR="$(MYSQL_PWD="$DB_PASS" "$DB_CLIENT" \
    --protocol=tcp \
    --host="$DB_HOST" \
    --port="$DB_PORT" \
    --user="$DB_USER" \
    --connect-timeout=10 \
    --batch \
    --skip-column-names \
    --execute='SELECT @@datadir;' \
    "$DB_NAME" 2>"$DB_ERROR_FILE")"
DB_QUERY_STATUS=$?
set -e

DB_PASS=""
unset MYSQL_PWD 2>/dev/null || true

if (( DB_QUERY_STATUS != 0 )); then
    DB_ERROR="$(sed -E 's/(password:?).*/\1 [REDACTED]/Ig' "$DB_ERROR_FILE")"
    rm -f -- "$DB_ERROR_FILE"
    die "Gagal terhubung ke database: ${DB_ERROR:-error tidak diketahui}"
fi
rm -f -- "$DB_ERROR_FILE"

DB_DATADIR="$(trim "$DB_DATADIR")"
[[ -n "$DB_DATADIR" ]] || die "Query database tidak mengembalikan lokasi data directory."
[[ -d "$DB_DATADIR" ]] || die "Data directory database tidak ditemukan: $DB_DATADIR"
DB_DATADIR="$(readlink -f -- "$DB_DATADIR")"

TEST_FILE="${DB_DATADIR%/}/eset-fio-test.dat"
[[ ! -e "$TEST_FILE" ]] || die "File tes sudah ada dan tidak akan ditimpa: $TEST_FILE"

read -r FS_TOTAL FS_AVAILABLE < <(df -PB1 --output=size,avail "$DB_DATADIR" | awk 'NR == 2 {print $1, $2}')
[[ "$FS_TOTAL" =~ ^[0-9]+$ && "$FS_AVAILABLE" =~ ^[0-9]+$ ]] || \
    die "Tidak dapat membaca kapasitas filesystem database."

if (( FS_AVAILABLE < TEST_SIZE_BYTES )); then
    die "Ruang kosong tidak cukup. Tersedia $(human_bytes "$FS_AVAILABLE"), diperlukan minimal $(human_bytes "$TEST_SIZE_BYTES")."
fi

AVAILABLE_AFTER_TEST=$((FS_AVAILABLE - TEST_SIZE_BYTES))
MIN_FREE_AFTER_TEST=$((FS_TOTAL * MIN_FREE_PERCENT_AFTER_TEST / 100))
LOW_SPACE_WARNING=0
if (( AVAILABLE_AFTER_TEST < MIN_FREE_AFTER_TEST )); then
    LOW_SPACE_WARNING=1
fi

FILESYSTEM_INFO="$(findmnt -T "$DB_DATADIR" -o SOURCE,FSTYPE,SIZE,AVAIL,USE%,TARGET -n 2>/dev/null || true)"

log ""
log "Ringkasan pengujian"
log "  Database       : $DB_NAME"
log "  Server database: $DB_HOST:$DB_PORT"
log "  Data directory : $DB_DATADIR"
log "  File tes       : $TEST_FILE"
log "  Ruang tersedia : $(human_bytes "$FS_AVAILABLE")"
log "  Ukuran file tes: ${TEST_SIZE_MIB} MiB"
[[ -z "$FILESYSTEM_INFO" ]] || log "  Filesystem      : $FILESYSTEM_INFO"
log "  Hasil fio       : $RESULT_FILE"

if (( LOW_SPACE_WARNING == 1 )); then
    log ""
    log "WARNING: Setelah file tes dibuat, ruang kosong filesystem diperkirakan kurang dari ${MIN_FREE_PERCENT_AFTER_TEST}%."
fi

log ""
log "PERINGATAN:"
log "  Tes berlangsung 120 detik dan membebani disk cukup berat."
log "  Sebaiknya jangan dijalankan pada jam produksi karena bisa memperlambat ESET dan database."
log "  File tes akan dihapus otomatis setelah pengujian selesai atau dihentikan."
log ""

if ! confirm "Ketik JALANKAN untuk memulai pengujian: "; then
    die "Pengujian dibatalkan oleh pengguna."
fi

touch "$RESULT_FILE"
chmod 600 "$RESULT_FILE"
RESULT_CREATED=1
TEST_FILE_OWNED=1

set +e
{
    printf 'ESET PROTECT storage IOPS test\n'
    printf 'Waktu mulai     : %s\n' "$(date --iso-8601=seconds)"
    printf 'Database        : %s\n' "$DB_NAME"
    printf 'Server database : %s:%s\n' "$DB_HOST" "$DB_PORT"
    printf 'Data directory  : %s\n' "$DB_DATADIR"
    printf 'Test file       : %s\n' "$TEST_FILE"
    printf 'Filesystem      : %s\n' "${FILESYSTEM_INFO:-tidak tersedia}"
    printf 'Ruang tersedia  : %s\n' "$(human_bytes "$FS_AVAILABLE")"
    printf 'fio version     : %s\n' "$($FIO_BIN --version 2>&1)"
    printf '\n'

    "$FIO_BIN" \
        --name=eset-iops-test \
        --filename="$TEST_FILE" \
        --size=1000M \
        --bs=4k \
        --rw=randrw \
        --rwmixwrite=50 \
        --iodepth=32 \
        --numjobs=4 \
        --runtime="$TEST_RUNTIME" \
        --time_based \
        --direct=1 \
        --randrepeat=0 \
        --refill_buffers \
        --group_reporting \
        --ioengine=libaio
} 2>&1 | tee "$RESULT_FILE"
FIO_STATUS=${PIPESTATUS[0]}
set -e

if [[ -e "$TEST_FILE" ]]; then
    rm -f -- "$TEST_FILE"
fi
TEST_FILE_OWNED=0

{
    printf '\nWaktu selesai   : %s\n' "$(date --iso-8601=seconds)"
    printf 'Exit status fio : %s\n' "$FIO_STATUS"
    printf 'Cleanup         : file tes telah dihapus\n'
} | tee -a "$RESULT_FILE"

if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
    chown "${SUDO_UID}:${SUDO_GID}" "$RESULT_FILE" 2>/dev/null || true
fi

if (( FIO_STATUS != 0 )); then
    die "fio selesai dengan error (status $FIO_STATUS). Detail tersimpan di $RESULT_FILE"
fi

log ""
log "Pengujian selesai. Hasil tersimpan di: $RESULT_FILE"
