#!/bin/bash
set -e

# ============================================
# TTYD Manager (With UFW Fix for Docker)
# Usage: bash <(curl -sSL https://github.com/dumpkids/tools/raw/refs/heads/main/tty.sh)
# ============================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

TTYD_PORT=3001
TTYD_USER="admin"
TTYD_BIND="0.0.0.0"
SHELL_PATH=${SHELL:-/bin/bash}
TTYD_BIN="/usr/local/bin/ttyd"

echo -e "${BLUE}[INFO]${NC} Mengecek status ttyd..."

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} Run as root/sudo"
    exit 1
fi

# Check status
if ! command -v ttyd &> /dev/null; then
    echo -e "${YELLOW}[STATUS]${NC} TTYD belum terinstall"
    INSTALL_NEEDED=1
elif systemctl is-active --quiet ttyd 2>/dev/null; then
    echo -e "${GREEN}[STATUS]${NC} TTYD sudah terinstall dan RUNNING"
    echo -e "  URL:      http://$TTYD_BIND:$TTYD_PORT"
    if [ -f "/etc/ttyd/.env" ]; then
        echo -e "  Username: $(grep TTYD_USER /etc/ttyd/.env | cut -d= -f2)"
        echo -e "  Password: $(grep TTYD_PASS /etc/ttyd/.env | cut -d= -f2)"
    fi
    INSTALL_NEEDED=0
else
    echo -e "${YELLOW}[STATUS]${NC} TTYD terinstall tapi STOPPED"
    INSTALL_NEEDED=2
fi

# Kalau sudah running, tanya mau reinstall?
if [ "$INSTALL_NEEDED" == "0" ]; then
    if [ -t 0 ]; then
        echo ""
        read -p "Mau reinstall/reset password? [y/N]: " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Exit."
            exit 0
        fi
        INSTALL_NEEDED=1
    else
        exit 0
    fi
fi

# Kalau stopped, tanya start atau reinstall
if [ "$INSTALL_NEEDED" == "2" ]; then
    if [ -t 0 ]; then
        read -p "Start service (s) atau Reinstall (r)? [s/r/N]: " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Ss]$ ]]; then
            systemctl start ttyd
            echo -e "${GREEN}[OK]${NC} Service started"
            exit 0
        elif [[ $REPLY =~ ^[Rr]$ ]]; then
            INSTALL_NEEDED=1
        else
            exit 0
        fi
    else
        systemctl start ttyd || true
        exit 0
    fi
fi

# Install/Reinstall
if [ "$INSTALL_NEEDED" == "1" ]; then
    echo -e "${YELLOW}[ACTION]${NC} Install TTYD..."
    
    # Input password
    if [ -z "$TTYD_PASS" ]; then
        if [ -t 0 ]; then
            echo -n "Masukkan password untuk user admin: "
            read -s TTYD_PASS
            echo ""
            
            if [ -z "$TTYD_PASS" ]; then
                echo -e "${RED}[ERROR]${NC} Password tidak boleh kosong!"
                exit 1
            fi
            
            echo -n "Konfirmasi password: "
            read -s TTYD_CONFIRM
            echo ""
            
            if [ "$TTYD_PASS" != "$TTYD_CONFIRM" ]; then
                echo -e "${RED}[ERROR]${NC} Password tidak cocok!"
                exit 1
            fi
        else
            echo -e "${RED}[ERROR]${NC} Password harus di-set!"
            echo -e "Cara: ${YELLOW}sudo TTYD_PASS=mypassword $0${NC}"
            exit 1
        fi
    fi
    
    # Detect OS
    if [ -f /etc/os-release ]; then 
        . /etc/os-release
        OS=$ID
    else 
        OS="unknown"
    fi
    
    # Install ttyd
    if ! command -v ttyd &> /dev/null; then
        echo -e "${BLUE}[INFO]${NC} Installing ttyd..."
        case $OS in
            ubuntu|debian)
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -qq && apt-get install -y ttyd -qq
                ;;
            centos|rhel|fedora|rocky|almalinux)
                yum install -y ttyd 2>/dev/null || dnf install -y ttyd 2>/dev/null
                ;;
            alpine)
                apk add ttyd
                ;;
        esac
        
        if ! command -v ttyd &> /dev/null; then
            # Binary fallback
            ARCH=$(uname -m)
            case $ARCH in
                x86_64) ARCH="x86_64" ;;
                aarch64|arm64) ARCH="aarch64" ;;
                armv7l) ARCH="armv7" ;;
            esac
            URL=$(curl -s https://api.github.com/repos/tsl0922/ttyd/releases/latest | grep "browser_download_url.*$ARCH" | cut -d'"' -f4)
            [ -z "$URL" ] && URL="https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.${ARCH}"
            curl -fsSL -o "$TTYD_BIN" "$URL"
            chmod +x "$TTYD_BIN"
        fi
    fi
    
    TTYD_PATH=$(which ttyd)
    if [ "$TTYD_PATH" != "$TTYD_BIN" ]; then
        ln -sf "$TTYD_PATH" "$TTYD_BIN"
    fi
    
    # Setup service
    echo -e "${BLUE}[INFO]${NC} Setup service..."
    mkdir -p /etc/ttyd
    echo "TTYD_USER=$TTYD_USER" > /etc/ttyd/.env
    echo "TTYD_PASS=$TTYD_PASS" >> /etc/ttyd/.env
    chmod 600 /etc/ttyd/.env
    
    # Detect ttyd version untuk opsi writable
    TTYD_VERSION=$($TTYD_BIN --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [[ "$TTYD_VERSION" =~ ^1\.[0-6] ]]; then
        WRITABLE_OPT="-W"  # Old version
    else
        WRITABLE_OPT="--writable"  # New version
    fi
    
    cat > /etc/systemd/system/ttyd.service <<EOF
[Unit]
Description=TTYD Web Terminal
After=network.target

[Service]
Type=simple
ExecStart=$TTYD_BIN --interface $TTYD_BIND --port $TTYD_PORT -c "${TTYD_USER}:${TTYD_PASS}" $WRITABLE_OPT $SHELL_PATH
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable ttyd
    systemctl restart ttyd
    
    sleep 2
    if systemctl is-active --quiet ttyd; then
        SERVER_IP=$(ip route get 1 2>/dev/null | awk '{print $7;exit}' || hostname -I | awk '{print $1}')
        echo ""
        echo -e "${GREEN}✓ TTYD Terinstall & Running!${NC}"
        echo -e "URL:      http://$SERVER_IP:$TTYD_PORT"
        echo -e "Username: $TTYD_USER"
        echo -e "Password: [hidden]"
    else
        echo -e "${RED}[ERROR]${NC} Service gagal start!"
        journalctl -u ttyd -n 3 --no-pager
        exit 1
    fi
    
    # ============================================
    # UFW FIX - Allow Docker Network
    # ============================================
    echo -e "${BLUE}[INFO]${NC} Konfigurasi firewall (UFW)..."
    
    if command -v ufw &> /dev/null; then
        # Cek status UFW
        if ufw status | grep -q "Status: active"; then
            echo -e "${YELLOW}[UFW]${NC} UFW aktif, menambahkan rule..."
            
            # Allow dari Docker default network (172.17.0.0/16)
            ufw allow from 172.17.0.0/16 to any port $TTYD_PORT proto tcp comment 'TTYD Docker' 2>/dev/null || true
            
            # Allow dari Docker custom networks (172.18.0.0/16 s/d 172.31.0.0/16)
            for i in {18..31}; do
                ufw allow from 172.$i.0.0/16 to any port $TTYD_PORT proto tcp comment "TTYD Docker $i" 2>/dev/null || true
            done
            
            # Allow dari 192.168.x.x (private network)
            ufw allow from 192.168.0.0/16 to any port $TTYD_PORT proto tcp comment 'TTYD Local' 2>/dev/null || true
            
            # Allow dari 10.x.x.x (private network)
            ufw allow from 10.0.0.0/8 to any port $TTYD_PORT proto tcp comment 'TTYD Private' 2>/dev/null || true
            
            echo -e "${GREEN}[OK]${NC} UFW rules added untuk port $TTYD_PORT"
            echo -e "      (Allow from: 172.17.0.0/16, 172.18-31.0.0/16, 192.168.0.0/16, 10.0.0.0/8)"
        else
            echo -e "${YELLOW}[UFW]${NC} UFW tidak aktif, skip firewall rules"
        fi
    else
        echo -e "${YELLOW}[UFW]${NC} UFW tidak terinstall, skip"
    fi
    
    # Cek firewalld (CentOS/RHEL)
    if command -v firewall-cmd &> /dev/null; then
        if systemctl is-active --quiet firewalld; then
            echo -e "${YELLOW}[FIREWALLD]${NC} Firewalld aktif, menambahkan zone..."
            firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='172.17.0.0/16' port protocol='tcp' port='$TTYD_PORT' accept" 2>/dev/null || true
            firewall-cmd --reload 2>/dev/null || true
            echo -e "${GREEN}[OK]${NC} Firewalld rules added"
        fi
    fi
    
    echo ""
    echo -e "${YELLOW}⚠️  IMPORTANT:${NC}"
    echo -e "    Port $TTYD_PORT dibuka untuk:"
    echo -e "    - Docker networks (172.17.0.0/16 dst)"
    echo -e "    - Private networks (192.168.x.x, 10.x.x.x)"
    echo -e "    - ${RED}TETAP BLOCK dari internet publik${NC} (pastikan via cloud firewall)"
    echo ""
    echo -e "Status:   systemctl status ttyd"
    echo -e "Logs:     journalctl -u ttyd -f"
fi
