#!/bin/bash
#===============================================================================
# ESET Connectivity Checker v2.9 - Removed Failed URLs
#===============================================================================
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="2.9"
readonly MAX_PARALLEL=8
readonly TIMEOUT=10
readonly TEMP_DIR=$(mktemp -d)

USE_PROXY="n"
PROXY_IP=""
PROXY_PORT=""
PROXY_USER=""

cleanup() {
    local exit_code=$?
    rm -rf "$TEMP_DIR" 2>/dev/null || true
    unset PROXY_PASS 2>/dev/null || true
    unset PROXY_USER 2>/dev/null || true
    unset http_proxy 2>/dev/null || true
    unset https_proxy 2>/dev/null || true
    wait 2>/dev/null || true
    exit $exit_code
}
trap cleanup EXIT INT TERM

log_info() { printf "\e[34m[INFO]\e[0m  %s\n" "$(date '+%H:%M:%S') - $*"; }
log_ok()   { printf "\e[32m[OK]\e[0m    %s\n" "$(date '+%H:%M:%S') - $*"; }
log_warn() { printf "\e[33m[WARN]\e[0m  %s\n" "$(date '+%H:%M:%S') - $*" >&2; }
log_err()  { printf "\e[31m[ERROR]\e[0m %s\n" "$(date '+%H:%M:%S') - $*" >&2; }

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
    
    if [[ ! -r /dev/tty ]]; then
        log_err "Mode non-interaktif tanpa TTY. Install manual: sudo apt install curl netcat"
        exit 1
    fi
    
    read -rp "Install dependency sekarang? [y/N]: " choice < /dev/tty
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        log_err "Dibatalkan oleh user"
        exit 1
    fi
    
    if [[ $EUID -ne 0 ]]; then
        log_err "Installasi membutuhkan root. Jalankan: curl -sSL <url> | sudo bash"
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

#-------------------------------------------------------------------------------
# 2. Proxy Validation - Test ke download.eset.com:443
#-------------------------------------------------------------------------------
test_proxy_connection() {
    local test_output
    local exit_code=0
    
    log_info "Testing proxy tunnel ke download.eset.com:443 ..."
    
    test_output=$(curl -v -x "$http_proxy" \
        --connect-timeout "$TIMEOUT" \
        --max-time "$TIMEOUT" \
        "telnet://download.eset.com:443" 2>&1) || exit_code=$?
    
    if echo "$test_output" | grep -q "CONNECT tunnel established"; then
        echo "OK"
        return 0
    elif echo "$test_output" | grep -q "200 Connection established"; then
        echo "OK"
        return 0
    else
        echo "$test_output" | grep -E "(Could not connect|Failed to connect|403|407|502|503|timeout)" | tail -1
        return 1
    fi
}

input_proxy_config() {
    PROXY_IP=""
    PROXY_PORT=""
    PROXY_USER=""
    unset PROXY_PASS 2>/dev/null || true
    unset http_proxy 2>/dev/null || true
    unset https_proxy 2>/dev/null || true
    
    echo ""
    echo "----------------------------------------------------------"
    log_info "Konfigurasi Proxy"
    
    while true; do
        read -rp "Proxy IP/Hostname: " PROXY_IP < /dev/tty
        if [[ -n "$PROXY_IP" ]]; then
            break
        fi
        log_warn "IP/Hostname tidak boleh kosong"
    done
    
    while true; do
        read -rp "Proxy Port [3128]: " PROXY_PORT < /dev/tty
        PROXY_PORT=${PROXY_PORT:-3128}
        if [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] && [ "$PROXY_PORT" -ge 1 ] && [ "$PROXY_PORT" -le 65535 ]; then
            break
        fi
        log_warn "Port harus angka 1-65535"
    done
    
    read -rp "Proxy Username (kosongkan jika tidak ada): " PROXY_USER < /dev/tty
    if [[ -n "$PROXY_USER" ]]; then
        read -rsp "Proxy Password: " PROXY_PASS < /dev/tty
        echo ""
        export http_proxy="http://$PROXY_USER:$PROXY_PASS@$PROXY_IP:$PROXY_PORT"
        export https_proxy="http://$PROXY_USER:$PROXY_PASS@$PROXY_IP:$PROXY_PORT"
    else
        export http_proxy="http://$PROXY_IP:$PROXY_PORT"
        export https_proxy="http://$PROXY_IP:$PROXY_PORT"
    fi
}

setup_proxy() {
    USE_PROXY="n"
    unset http_proxy 2>/dev/null || true
    unset https_proxy 2>/dev/null || true
    
    if [[ ! -r /dev/tty ]]; then
        log_info "Mode non-interaktif (tidak ada TTY). Skip konfigurasi proxy."
        return 0
    fi
    
    while true; do
        echo ""
        read -rp "Gunakan proxy? [y/N]: " use_proxy < /dev/tty
        
        if [[ ! "$use_proxy" =~ ^[Yy]$ ]]; then
            log_info "Mode: Direct Connection"
            unset http_proxy https_proxy
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
                read -rp "Pilihan [R/S/C]: " choice < /dev/tty
                choice=${choice^^}
                
                case "$choice" in
                    R)
                        log_info "Mengulang konfigurasi proxy..."
                        break
                        ;;
                    S)
                        log_info "Beralih ke mode Direct Connection"
                        USE_PROXY="n"
                        unset http_proxy https_proxy
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

# URL yang dihapus:
# - http://repository.eset.com
# - http://us-update.eset.com
# - http://eu-update.eset.com
# - https://eu.download.protect.eset.com
# - https://identity.eset.com

declare -a TARGETS=(
    "nc:update.eset.com:443"
    "nc:download.eset.com:443"
    "nc:edf.eset.com:443"
    "nc:https://iploc.eset.com:43"
    "nc:eu01.server.xdr.eset.systems:443"
    "nc:eu01.agent.edr.eset.systems:8093"
    "nc:epx-k8s-prod-eu-a.westeurope.cloudapp.azure.com:444"
    "nc:epns.eset.com:8883"
    "nc:avcloud.e5.sk:53535"
    "nc:livegrid.eset.systems:443"
    "curl:https://augur.scanners.eset.systems"
    "nc:login.microsoftonline.com:443"
)

check_target() {
    local target="$1"
    local type="${target%%:*}"
    local address="${target#*:}"
    local status="FAIL"
    local latency="-"
    local start_time end_time duration
    
    start_time=$(date +%s%N)
    
    if [[ "$type" == "nc" ]]; then
        local host="${address%:*}"
        local port="${address##*:}"
        local method="Netcat"
        
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
            method="Netcat"
            if nc -vz -w "$TIMEOUT" "$host" "$port" &>/dev/null; then
                status="OK"
            fi
        fi
        address="$host:$port"
    else
        local method="Direct"
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

export -f check_target log_info log_ok log_warn log_err
export USE_PROXY http_proxy https_proxy TIMEOUT TEMP_DIR

main() {
    echo "=========================================================="
    echo " ESET Connectivity Checker v${SCRIPT_VERSION} (Cleaned)      "
    echo "=========================================================="
    echo ""
    
    check_dependencies
    setup_proxy
    
    echo ""
    log_info "Memulai pengecekan ke ${#TARGETS[@]} target..."
    echo "----------------------------------------------------------"
    
    rm -rf "$TEMP_DIR"/result_* 2>/dev/null || true
    
    printf "%s\n" "${TARGETS[@]}" | xargs -P "$MAX_PARALLEL" -I {} bash -c 'check_target "{}"'
    
    echo "----------------------------------------------------------"
    
    local total_ok=0
    local total_fail=0
    
    for f in "$TEMP_DIR"/result_*; do
        if [[ -f "$f" ]]; then
            local res
            res=$(cut -d':' -f1 < "$f")
            if [[ "$res" == "OK" ]]; then
                ((total_ok++))
            else
                ((total_fail++))
            fi
        fi
    done
    
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
