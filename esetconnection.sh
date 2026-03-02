#!/bin/bash
#===============================================================================
# ESET Connectivity Checker - Optimized Version
#===============================================================================
set -euo pipefail
IFS=$'\n\t'

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_VERSION="2.0"
readonly MAX_PARALLEL=8
readonly TIMEOUT=10
readonly PROXY_TEST_URL="http://httpbin.org/ip"
readonly TEMP_DIR=$(mktemp -d)
readonly NETRC_FILE="$TEMP_DIR/.netrc"

# Cleanup on exit
cleanup() {
    local exit_code=$?
    rm -rf "$TEMP_DIR" 2>/dev/null || true
    # Clear sensitive variables
    unset PROXY_PASS 2>/dev/null || true
    unset PROXY_USER 2>/dev/null || true
    # Wait for any remaining background jobs
    wait 2>/dev/null || true
    exit $exit_code
}
trap cleanup EXIT INT TERM

#-------------------------------------------------------------------------------
# Logging Functions
#-------------------------------------------------------------------------------
log_info() { printf "\e[34m[INFO]\e[0m  %s\n" "$(date '+%H:%M:%S') - $*"; }
log_ok()   { printf "\e[32m[OK]\e[0m    %s\n" "$(date '+%H:%M:%S') - $*"; }
log_warn() { printf "\e[33m[WARN]\e[0m  %s\n" "$(date '+%H:%M:%S') - $*" >&2; }
log_err()  { printf "\e[31m[ERROR]\e[0m %s\n" "$(date '+%H:%M:%S') - $*" >&2; }

#-------------------------------------------------------------------------------
# 1. Dependency Check
#-------------------------------------------------------------------------------
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
    
    # Force read from TTY even if piped
    if [[ ! -t 0 ]]; then
        log_err "Script dijalankan via pipe. Install manual: sudo apt install curl netcat"
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
    
    # Verify installation
    if ! command -v curl &>/dev/null || ! command -v nc &>/dev/null; then
        log_err "Instalasi gagal. Periksa koneksi internet."
        exit 1
    fi
    
    log_ok "Dependency terinstall"
}

#-------------------------------------------------------------------------------
# 2. Proxy Setup & Validation
#-------------------------------------------------------------------------------
setup_proxy() {
    USE_PROXY="n"
    PROXY_ARGS=""
    export http_proxy=""
    export https_proxy=""
    
    if [[ ! -t 0 ]]; then
        log_info "Mode non-interaktif (pipe). Skip konfigurasi proxy."
        return 0
    fi
    
    read -rp "Gunakan proxy? [y/N]: " use_proxy < /dev/tty
    
    if [[ ! "$use_proxy" =~ ^[Yy]$ ]]; then
        log_info "Mode: Direct Connection"
        return 0
    fi
    
    # Input validation loop
    while true; do
        read -rp "Proxy IP/Hostname: " PROXY_IP < /dev/tty
        if [[ -n "$PROXY_IP" ]]; then
            break
        fi
        log_warn "IP/Hostname tidak boleh kosong"
    done
    
    while true; do
        read -rp "Proxy Port [8080]: " PROXY_PORT < /dev/tty
        PROXY_PORT=${PROXY_PORT:-8080}
        if [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] && [ "$PROXY_PORT" -ge 1 ] && [ "$PROXY_PORT" -le 65535 ]; then
            break
        fi
        log_warn "Port harus angka 1-65535"
    done
    
    read -rp "Proxy Username (kosongkan jika tidak ada): " PROXY_USER < /dev/tty
    if [[ -n "$PROXY_USER" ]]; then
        read -rsp "Proxy Password: " PROXY_PASS < /dev/tty
        echo "" # newline after silent input
    fi
    
    # Create .netrc for secure credential storage (not visible in ps aux)
    if [[ -n "${PROXY_USER:-}" && -n "${PROXY_PASS:-}" ]]; then
        cat > "$NETRC_FILE" <<EOF
machine $PROXY_IP
login $PROXY_USER
password $PROXY_PASS
EOF
        chmod 600 "$NETRC_FILE"
        PROXY_ARGS="--proxy http://$PROXY_IP:$PROXY_PORT --netrc-file $NETRC_FILE"
    else
        PROXY_ARGS="--proxy http://$PROXY_IP:$PROXY_PORT"
    fi
    
    log_info "Menguji koneksi proxy ke $PROXY_IP:$PROXY_PORT..."
    
    # Test proxy connection
    local proxy_test_output
    local proxy_exit_code=0
    
    proxy_test_output=$(curl -s --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
        $PROXY_ARGS "$PROXY_TEST_URL" 2>&1) || proxy_exit_code=$?
    
    if [[ $proxy_exit_code -ne 0 ]]; then
        log_err "KONEKSI PROXY GAGAL!"
        log_err "Error: $proxy_test_output"
        log_err "Periksa konfigurasi proxy Anda dan jalankan ulang script."
        exit 1
    fi
    
    # Verify proxy actually works (response should contain origin IP)
    if echo "$proxy_test_output" | grep -q "origin"; then
        local proxy_ip_detected
        proxy_ip_detected=$(echo "$proxy_test_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        log_ok "Proxy aktif (Detected IP: $proxy_ip_detected)"
    else
        log_warn "Proxy merespons tapi format tidak sesuai standar"
    fi
    
    USE_PROXY="y"
    export http_proxy="http://$PROXY_IP:$PROXY_PORT"
    export https_proxy="http://$PROXY_IP:$PROXY_PORT"
}

#-------------------------------------------------------------------------------
# 3. Target Definitions
#-------------------------------------------------------------------------------
declare -a TARGETS=(
    # Module Updates & Repositories
    "curl:http://update.eset.com"
    "curl:http://eu-update.eset.com"
    "curl:http://us-update.eset.com"
    "curl:http://repository.eset.com"
    "curl:http://pki.eset.com"
    
    # Downloads
    "curl:http://download.eset.com"
    "curl:https://eu.download.protect.eset.com"
    
    # Aktivasi & Licensing
    "curl:https://edf.eset.com"
    "curl:https://iploc.eset.com"
    
    # ESET PROTECT Management
    "curl:https://protect.eset.com"
    "curl:https://protecthub.eset.com"
    "curl:https://identity.eset.com"
    
    # ESET Inspect / XDR / EDR
    "nc:eu01.server.xdr.eset.systems:443"
    "nc:eu01.agent.edr.eset.systems:8093"
    "nc:epx-k8s-prod-eu-a.westeurope.cloudapp.azure.com:444"
    
    # Push Notification Service
    "nc:epns.eset.com:8883"
    
    # LiveGrid & LiveGuard
    "nc:avcloud.e5.sk:53535"
    "curl:http://livegrid.eset.systems"
    "curl:http://augur.scanners.eset.systems"
    
    # Microsoft Azure AD (untuk ESET Bridge)
    "nc:login.microsoftonline.com:443"
)

# Export results array untuk tracking
declare -A RESULTS
declare -A LATENCIES

#-------------------------------------------------------------------------------
# 4. Check Function (untuk xargs)
#-------------------------------------------------------------------------------
check_target() {
    local target="$1"
    local type="${target%%:*}"
    local address="${target#*:}"
    local status="FAIL"
    local latency="-"
    local start_time end_time duration
    
    start_time=$(date +%s%N)
    
    if [[ "$type" == "nc" ]]; then
        # Format: nc:host:port
        local host="${address%:*}"
        local port="${address##*:}"
        local method="Netcat"
        
        if [[ "$USE_PROXY" == "y" ]]; then
            method="Proxy-TCP"
            # Untuk TCP check via proxy, gunakan CONNECT method
            if curl -s -o /dev/null --connect-timeout "$TIMEOUT" \
                 --max-time "$TIMEOUT" $PROXY_ARGS \
                 "https://$host:$port" 2>&1 | grep -q "Connection established\|200\|301\|302"; then
                status="OK"
            fi
        else
            if nc -vz -w "$TIMEOUT" "$host" "$port" &>/dev/null; then
                status="OK"
            fi
        fi
        
        address="$host:$port"
    else
        # Format: curl:url
        local method="Direct"
        [[ "$USE_PROXY" == "y" ]] && method="Proxy"
        
        if curl -sf --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
             $PROXY_ARGS "$address" &>/dev/null; then
            status="OK"
        fi
    fi
    
    end_time=$(date +%s%N)
    duration=$(( (end_time - start_time) / 1000000 )) # Convert to ms
    
    # Output hasil
    if [[ "$status" == "OK" ]]; then
        printf "[\e[32m OK \e[0m] %-55s %6sms (%s)\n" "$address" "$duration" "$method"
    else
        printf "[\e[31mFAIL\e[0m] %-55s    -   (%s)\n" "$address" "$method"
    fi
    
    # Simpan ke file temporary untuk summary (karena xargs subprocess)
    echo "$status:$duration" > "$TEMP_DIR/result_$(echo "$target" | tr '/:' '_')"
}

export -f check_target
export USE_PROXY PROXY_ARGS TIMEOUT TEMP_DIR NETRC_FILE

#-------------------------------------------------------------------------------
# 5. Main Execution
#-------------------------------------------------------------------------------
main() {
    echo "=========================================================="
    echo " ESET Connectivity Checker v${SCRIPT_VERSION} (Optimized)      "
    echo "=========================================================="
    echo ""
    
    check_dependencies
    setup_proxy
    
    echo ""
    log_info "Memulai pengecekan ke ${#TARGETS[@]} target..."
    echo "----------------------------------------------------------"
    
    # Reset results directory
    rm -rf "$TEMP_DIR"/result_* 2>/dev/null || true
    
    # Parallel execution dengan xargs (rate limited)
    printf "%s\n" "${TARGETS[@]}" | xargs -P "$MAX_PARALLEL" -I {} bash -c 'check_target "{}"'
    
    echo "----------------------------------------------------------"
    
    # Summary
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
    printf "  Mode         : %s\n" "$([ "$USE_PROXY" == "y" ] && echo "Proxy ($http_proxy)" || echo "Direct")"
    echo "=========================================================="
    
    if [[ $total_fail -gt 0 ]]; then
        exit 1
    fi
}

# Run main
main "$@"
