#!/bin/bash
set -e

# ============================================
# TTYD Uninstaller
# Usage: curl -fsSL .../uninstall.sh | sudo bash
# ============================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

echo -e "${BLUE}[INFO]${NC} Uninstalling ttyd..."

# Check root
[ "$EUID" -ne 0 ] && { echo -e "${RED}[ERROR]${NC} Run as root/sudo"; exit 1; }

# 1. Stop dan disable service
echo -e "${BLUE}[INFO]${NC} Stopping service..."
systemctl stop ttyd 2>/dev/null || true
systemctl disable ttyd 2>/dev/null || true

# 2. Hapus file service
if [ -f "/etc/systemd/system/ttyd.service" ]; then
    rm -f /etc/systemd/system/ttyd.service
    echo -e "${GREEN}[OK]${NC} Service file removed"
fi

# 3. Reload systemd
systemctl daemon-reload

# 4. Hapus binary
if [ -f "/usr/local/bin/ttyd" ]; then
    rm -f /usr/local/bin/ttyd
    echo -e "${GREEN}[OK]${NC} Binary removed from /usr/local/bin/ttyd"
fi

# 5. Hapus config dan credentials
if [ -d "/etc/ttyd" ]; then
    rm -rf /etc/ttyd
    echo -e "${GREEN}[OK]${NC} Config & credentials removed"
fi

# 6. Opsional: Uninstall package ttyd kalau install dari repo (pilihan)
read -p "Hapus package ttyd dari sistem (apt/yum)? [y/N]: " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if command -v apt-get &> /dev/null; then
        apt-get remove -y ttyd 2>/dev/null || echo -e "${YELLOW}[WARN]${NC} Package ttyd tidak ditemukan di apt"
    elif command -v yum &> /dev/null; then
        yum remove -y ttyd 2>/dev/null || echo -e "${YELLOW}[WARN]${NC} Package ttyd tidak ditemukan di yum"
    elif command -v dnf &> /dev/null; then
        dnf remove -y ttyd 2>/dev/null || echo -e "${YELLOW}[WARN]${NC} Package ttyd tidak ditemukan di dnf"
    fi
fi

# 7. Bersihkan firewall rules (opsional)
echo -e "${BLUE}[INFO]${NC} Note: Firewall rules (ufw/firewalld) tidak dihapus otomatis."
echo -e "        Jika perlu, hapus manual: ufw delete allow 3001"

echo ""
echo -e "${GREEN}✓ TTYD Uninstalled!${NC}"
echo -e "Port 3001 sudah tidak digunakan lagi."
