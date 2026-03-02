#!/bin/bash
#===============================================================================
# ESET Connectivity Checker v2.1 - Optimized Edition (Fixed pipe stdin)
# Original by: Dumpkids
# Optimizations: Security, Performance, Code Quality, Better TTY handling
# Usage: bash <(curl -sSL https://raw.githubusercontent.com/dumpkids/tools/refs/heads/main/esetconnection-v2.1.sh)
#===============================================================================
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="2.1"
readonly MAX_PARALLEL=8
readonly TIMEOUT=10
readonly TEMP_DIR=$(mktemp -d)

USE_PROXY="n"
PROXY_IP=""
PROXY_PORT=""
PROXY_USER=""

#===============================================================================
# Cleanup & Signal Handling
#===============================================================================
cleanup() {
    local exit_code=$?
    rm -rf "$TEMP_DIR" 2>/dev/null || true
    unset PROXY_PASS PROXY_USER http_proxy https_proxy 2>/dev/null || true
    wait 2>/dev/null || true
    exit $exit_code
}
trap cleanup EXIT INT TERM

#===============================================================================
# Logging Functions
#===============================================================================
_get_timestamp() {
    printf '%(%H:%M:%S)T' -1
}

log_info() { 
    printf "\e[34m[INFO]\e[0m  %s\n" "$(_get_timestamp) - $*"
}

log_ok() { 
    printf "\e[32m[OK]\e[0m    %s\n" "$(_get_timestamp) - $*"
}

log_warn() { 
    printf "\e[33m[WARN]\e[0m  %s\n" "$(_get_timestamp) - $*" >&2
}

log_err() { 
    printf "\e[31m[ERROR]\e[0m %s\n" "$(_get_timestamp) - $*" >&2
}

#===============================================================================
# FIX: Better TTY Detection & Input Handling
#===============================================================================
_get_input_source() {
    # Try multiple methods to get a valid input source
    if [[ -r /dev/tty ]]; then
        echo "/dev/tty"
    elif [[ -r /proc/self/fd/0 ]]; then
        echo "/proc/self/fd/0"
    else
        echo "/dev/stdin"
    fi
}

_read_input() {
    local prompt="$1"
    local varname="$2"
    local is_password="${3:-false}"
    local input_source=$(_get_input_source)
    
    if [[ "$is_password" == "true" ]]; then
        read -rsp "$prompt" "$varname" < "$input_source"
        echo ""
    else
        read -rp "$prompt" "$varname" < "$input_source"
    fi
}

#===============================================================================
# Dependency Check
#===============================================================================
check_dependencies() {
    local missing=()

    if ! command -v curl &>/dev/null; then
        missing+=("curl")
    fi

    if ! command -v nc &>/dev/null; then
        missing+=("netcat")
    fi

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    log_warn "Dependency belum terinstall: ${missing[*]}"

    local input_source=$(_get_input_source)
    if [[ ! -r "$input_source" ]]; then
        log_err "Mode non-interaktif tanpa input. Install manual: sudo apt install curl netcat"
        exit 1
    fi

    read -rp "Install dependency sekarang? [y/N]: " choice < "$input_source"
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        log_err "Dibatalkan oleh user"
        exit 1
    fi

    if [[ $EUID -ne 0 ]]; then
        log_err "Installasi membutuhkan root. Jalankan: sudo bash <(curl -sSL <url>)"
        exit 1
    fi

    log_info "Menginstall dependency..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq curl netcat-openbsd
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl nc
    elif command -v yum &>/dev/null; then
        yum install -y -q curl nc
    elif command -v apk &>/dev/null; then
        apk add --no-cache curl netcat-openbsd
    else
        log_err "Package manager tidak dikenali. Install manual: ${missing[*]}"
        exit 1
    fi

    if ! command -v curl &>/dev/null || ! command -v nc &>/dev/null; then
        log_err "Instalasi gagal. Periksa koneksi internet."
        exit 1
    fi

    log_ok "Dependency terinstall"
}

#===============================================================================
# Proxy Connection Test
#===============================================================================
test_proxy_connection() {
    local test_output exit_code=0

    log_info "Testing proxy tunnel ke download.eset.com:443 ..."

    test_output=$(curl -v -x "$http_proxy" \
        --connect-timeout "$TIMEOUT" \
        --max-time "$TIMEOUT" \
        "telnet://download.eset.com:443" 2>&1) || exit_code=$?

    if echo "$test_output" | grep -q "CONNECT tunnel established\|200 Connection established"; then
        echo "OK"
        return 0
    else
        echo "$test_output" | grep -E "(Could not connect|Failed to connect|403|407|502|503|timeout)" | tail -1
        return 1
    fi
}

#===============================================================================
# Proxy Configuration Input (FIXED: Better input handling)
#===============================================================================
input_proxy_config() {
    PROXY_IP=""
    PROXY_PORT=""
    PROXY_USER=""
    unset PROXY_PASS http_proxy https_proxy 2>/dev/null || true

    echo ""
    echo "----------------------------------------------------------"
    log_info "Konfigurasi Proxy"

    # Input: Proxy IP/Hostname
    while true; do
        _read_input "Proxy IP/Hostname: " PROXY_IP
        if [[ -n "$PROXY_IP" ]]; then
            break
        fi
        log_warn "IP/Hostname tidak boleh kosong"
    done

    # Input: Proxy Port
    while true; do
        _read_input "Proxy Port [3128]: " PROXY_PORT
        PROXY_PORT=${PROXY_PORT:-3128}
        if [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] && [ "$PROXY_PORT" -ge 1 ] && [ "$PROXY_PORT" -le 65535 ]; then
            break
        fi
        log_warn "Port harus angka 1-65535"
    done

    # Input: Proxy Username
    _read_input "Proxy Username (kosongkan jika tidak ada): " PROXY_USER
    
    if [[ -n "$PROXY_USER" ]]; then
        _read_input "Proxy Password: " PROXY_PASS "true"
        export http_proxy="http://$PROXY_USER:$PROXY_PASS@$PROXY_IP:$PROXY_PORT"
        export https_proxy="http://$PROXY_USER:$PROXY_PASS@$PROXY_IP:$PROXY_PORT"
    else
        export http_proxy="http://$PROXY_IP:$PROXY_PORT"
        export https_proxy="http://$PROXY_IP:$PROXY_PORT"
    fi
}

#===============================================================================
# Proxy Setup (FIXED: Better input handling)
#===============================================================================
setup_proxy() {
    USE_PROXY="n"
    unset http_proxy https_proxy 2>/dev/null || true

    local input_source=$(_get_input_source)
    if [[ ! -r "$input_source" ]]; then
        log_info "Mode non-interaktif (tidak ada input). Skip konfigurasi proxy."
        return 0
    fi

    while true; do
        echo ""
        _read_input "Gunakan proxy? [y/N]: " use_proxy

        if [[ ! "$use_proxy" =~ ^[Yy]$ ]]; then
            log_info "Mode: Direct Connection"
            unset http_proxy https_proxy 2>/dev/null || true
            return 0
        fi

        input_proxy_config

        echo ""
        local test_result

        if test_result=$(test_proxy_connection); then
            if [[ "$test_result" == "OK" ]]; then
                log_ok "Proxy tunnel aktif! (download.eset.com:443)"
            fi
            USE_PROXY="y"
            return 0

        else
            log_err "KONEKSI PROXY GAGAL!"
            log_err "Detail: $test_result"
            echo ""
            echo "----------------------------------------------------------"
            echo "Pilihan:"
            echo "  [R] Retry    - Input ulang konfigurasi proxy"
            echo "  [S] Skip     - Lanjut tanpa proxy (direct connection)"
            echo "  [C] Cancel   - Keluar dari script"
            echo "----------------------------------------------------------"

            while true; do
                _read_input "Pilihan [R/S/C]: " choice
                choice=${choice^^}

                case "$choice" in
                    R)
                        log_info "Mengulang konfigurasi proxy..."
                        break
                        ;;
                    S)
                        log_info "Beralih ke mode Direct Connection"
                        USE_PROXY="n"
                        unset http_proxy https_proxy 2>/dev/null || true
                        return 0
                        ;;
                    C)
                        log_err "Dihentikan oleh user"
                        exit 1
                        ;;
                    *)
                        log_warn "Pilihan tidak valid. Masukkan R, S, atau C"
                        ;;
                esac
            done
        fi
    done
}

#===============================================================================
# Target Definitions
#===============================================================================
declare -a TARGETS=(
    "nc:update.eset.com:443"
    "nc:repository.eset.com:80"
    "nc:download.eset.com:443"
    "nc:edf.eset.com:443"
    "nc:iploc.eset.com:443"
    "nc:eu01.server.xdr.eset.systems:443"
    "nc:eu.download.protect.eset.com:443"
    "nc:eu01.agent.edr.eset.systems:8093"
    "nc:epx-k8s-prod-eu-a.westeurope.cloudapp.azure.com:444"
    "nc:epns.eset.com:8883"
    "nc:avcloud.e5.sk:53535"
    "nc:livegrid.eset.systems:443"
    "curl:https://augur.scanners.eset.systems"
)

#===============================================================================
# Target Connectivity Check
#===============================================================================
check_target() {
    local target="$1"
    local type="${target%%:*}"
    local address="${target#*:}"
    local status="FAIL"
    local start_time end_time duration
    local method=""

    if [[ -z "$type" || -z "$address" ]]; then
        log_err "Invalid target format: $target"
        echo "FAIL:0" > "$TEMP_DIR/result_$(echo "$target" | tr '/:' '_')"
        return 1
    fi

    start_time=$(date +%s%N)

    if [[ "$type" == "nc" ]]; then
        local host="${address%:*}"
        local port="${address##*:}"

        method="Netcat"
        
        if [[ "${USE_PROXY:-}" == "y" ]]; then
            method="Proxy-TCP"
            if curl -v -x "$http_proxy" \
                     --connect-timeout "$TIMEOUT" \
                     --max-time "$TIMEOUT" \
                     "telnet://$host:$port" 2>&1 | \
                     grep -q "CONNECT tunnel established\|200 Connection established"; then
                status="OK"
            fi
        else
            if nc -vz -w "$TIMEOUT" "$host" "$port" &>/dev/null; then
                status="OK"
            fi
        fi
        address="$host:$port"
    else
        method="Direct"
        [[ "${USE_PROXY:-}" == "y" ]] && method="Proxy"

        if curl -sf --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" "$address" &>/dev/null; then
            status="OK"
        fi
    fi

    end_time=$(date +%s%N)
    duration=$(( (end_time - start_time) / 1000000 ))

    if [[ "$status" == "OK" ]]; then
        printf "[\e[32m OK \e[0m] %-55s %6sms (%s)\n" "$address" "$duration" "$method"
    else
        printf "[\e[31mFAIL\e[0m] %-55s    -   (%s)\n" "$address" "$method"
    fi

    echo "$status:$duration" > "$TEMP_DIR/result_$(echo "$target" | tr '/:' '_')"
}

export -f check_target log_info log_ok log_warn log_err _get_timestamp
export USE_PROXY http_proxy https_proxy TIMEOUT TEMP_DIR

#===============================================================================
# Main Function
#===============================================================================
main() {
    echo "=========================================================="
    echo " ESET Connectivity Checker v${SCRIPT_VERSION} (Optimized)    "
    echo "=========================================================="
    echo ""

    check_dependencies
    setup_proxy

    echo ""
    log_info "Memulai pengecekan ke ${#TARGETS[@]} target... [SOURCE : https://support.eset.com/en/kb332]"
    echo "----------------------------------------------------------"

    rm -rf "$TEMP_DIR"/result_* 2>/dev/null || true

    printf "%s\n" "${TARGETS[@]}" | xargs -P "$MAX_PARALLEL" -I {} bash -c 'check_target "$@"' _ {}

    echo "----------------------------------------------------------"

    local total_ok=0
    local total_fail=0

    while IFS=: read -r res _; do
        if [[ "$res" == "OK" ]]; then
            ((total_ok++))
        else
            ((total_fail++))
        fi
    done < <(cat "$TEMP_DIR"/result_* 2>/dev/null)

    echo ""
    echo "======================= SUMMARY =========================="
    printf "  Total Target : %d\n" "${#TARGETS[@]}"
    printf "  \e[32mBerhasil\e[0m     : %d\n" "$total_ok"
    printf "  \e[31mGagal\e[0m        : %d\n" "$total_fail"

    if [[ "${USE_PROXY:-}" == "y" ]]; then
        printf "  Mode         : Proxy (%s:%s)\n" "$PROXY_IP" "$PROXY_PORT"
        [[ -n "${PROXY_USER:-}" ]] && printf "  Auth         : %s (authenticated)\n" "$PROXY_USER"
    else
        printf "  Mode         : Direct Connection\n"
    fi

    echo "=========================================================="

    if [[ $total_fail -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
