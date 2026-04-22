#!/usr/bin/env bash
# ==============================================================================
# Script: setup_httpserver.sh
# Usage : curl -sSL https://raw.githubusercontent.com/.../setup_httpserver.sh | sudo bash
# ==============================================================================

main() {
    set -euo pipefail

    # --- 1. Sudo Check ---
    if [[ "$EUID" -ne 0 ]]; then
        echo "🚨 ERROR: Eksekusi gagal. Silakan tambahkan 'sudo bash' di akhir perintah." >&2
        exit 1
    fi

    # --- 2. Setup Logging Instalasi ---
    CURRENT_DIR=$(pwd)
    SETUP_LOG="${CURRENT_DIR}/setup_httpserver_$(date +%Y%m%d_%H%M%S).log"
    exec > >(tee -a "$SETUP_LOG") 2>&1

    echo "==================================================="
    echo "🚀 Setup ESET Advanced HTTP Server (With UI & Logging)"
    echo "==================================================="

    # --- 3. Install Dependensi ---
    echo "[*] Mengecek dependensi (python3, iproute2, logrotate)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y -q
    apt-get install -y -q python3 iproute2 logrotate

    # --- 4. Interactive Port Input ---
    while true; do
        echo ""
        read -p "👉 Masukkan port yang ingin digunakan (1-65535): " HTTP_PORT < /dev/tty

        if [[ -z "$HTTP_PORT" ]]; then
            echo "❌ ERROR: Port tidak boleh kosong."
            continue
        fi

        if [[ ! "$HTTP_PORT" =~ ^[0-9]+$ ]] || [ "$HTTP_PORT" -lt 1 ] || [ "$HTTP_PORT" -gt 65535 ]; then
            echo "❌ ERROR: Masukkan angka yang valid (1 - 65535)."
            continue
        fi

        if ss -tuln | grep -q ":${HTTP_PORT} "; then
            echo "❌ ERROR: Port $HTTP_PORT sedang DIPAKAI oleh aplikasi lain!"
            continue
        fi

        echo "✅ Port $HTTP_PORT valid dan tersedia."
        break
    done

    # --- 5. Setup Direktori Log & Aplikasi ---
    MIRRORTOOL_DIR="/opt/mirrortool"
    TARGET_DIR="${MIRRORTOOL_DIR}/dir"
    ACCESS_LOG_DIR="/var/log/esetmirrortools"
    
    mkdir -p "$TARGET_DIR"
    mkdir -p "$ACCESS_LOG_DIR"
    touch "${ACCESS_LOG_DIR}/esetmirrortools.log"

    # --- 6. Generate Custom Python Server Script ---
    echo "[*] Membuat script Python Server (UI Sorting & Access Log)..."
    
    # Perhatikan penggunaan 'EOF_PYTHON' dengan kutip agar bash tidak mengganggu kode Python
    cat << 'EOF_PYTHON' > "${MIRRORTOOL_DIR}/server.py"
import os, urllib.parse, html, io, sys, datetime
from http.server import SimpleHTTPRequestHandler, HTTPServer
import logging

LOG_FILE = "/var/log/esetmirrortools/esetmirrortools.log"

# Konfigurasi Logging Kustom
logging.basicConfig(filename=LOG_FILE, level=logging.INFO, 
                    format='[%(asctime)s] %(clientip)s - %(message)s', datefmt='%Y-%m-%d %H:%M:%S')

class AdvancedHTTPHandler(SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        # Override output log standar agar masuk ke file
        logging.info(format % args, extra={'clientip': self.client_address[0]})
        
    def list_directory(self, path):
        try:
            entries = list(os.scandir(path))
        except OSError:
            self.send_error(404, "No permission to list directory")
            return None
            
        displaypath = html.escape(urllib.parse.unquote(self.path))
        
        # Injeksi HTML, CSS, dan Javascript Sorting
        html_content = f"""<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Index of {displaypath}</title>
    <style>
        body {{ font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 30px; color: #333; }}
        h2 {{ border-bottom: 2px solid #0056b3; padding-bottom: 10px; color: #0056b3; }}
        table {{ width: 100%; border-collapse: collapse; margin-top: 15px; font-size: 14px; }}
        th, td {{ padding: 12px 15px; text-align: left; border-bottom: 1px solid #ddd; }}
        th {{ cursor: pointer; background-color: #f4f4f4; user-select: none; transition: background 0.2s; }}
        th:hover {{ background-color: #e0e0e0; }}
        tr:hover {{ background-color: #f9f9f9; }}
        a {{ text-decoration: none; color: #0056b3; font-weight: 500; }}
        a:hover {{ text-decoration: underline; color: #003d82; }}
        .icon {{ display: inline-block; width: 20px; }}
    </style>
    <script>
        function sortTable(n, isNumber) {{
            var table, rows, switching, i, x, y, shouldSwitch, dir, switchcount = 0;
            table = document.getElementById("dirTable");
            switching = true; dir = "asc"; 
            while (switching) {{
                switching = false; rows = table.rows;
                for (i = 1; i < (rows.length - 1); i++) {{
                    shouldSwitch = false;
                    x = rows[i].getElementsByTagName("TD")[n];
                    y = rows[i + 1].getElementsByTagName("TD")[n];
                    var valX = isNumber ? parseFloat(x.getAttribute("data-val")) : (x.getAttribute("data-val") || x.innerHTML.toLowerCase());
                    var valY = isNumber ? parseFloat(y.getAttribute("data-val")) : (y.getAttribute("data-val") || y.innerHTML.toLowerCase());
                    
                    if (dir == "asc") {{ if (valX > valY) {{ shouldSwitch = true; break; }} }} 
                    else if (dir == "desc") {{ if (valX < valY) {{ shouldSwitch = true; break; }} }}
                }}
                if (shouldSwitch) {{
                    rows[i].parentNode.insertBefore(rows[i + 1], rows[i]);
                    switching = true; switchcount++;      
                }} else {{
                    if (switchcount == 0 && dir == "asc") {{ dir = "desc"; switching = true; }}
                }}
            }}
        }}
    </script>
</head>
<body>
    <h2>Index of {displaypath}</h2>
    <table id="dirTable">
        <tr>
            <th onclick="sortTable(0, false)">Name ↕</th>
            <th onclick="sortTable(1, true)">Last Modified ↕</th>
            <th onclick="sortTable(2, true)">Size ↕</th>
        </tr>
"""
        if self.path != "/":
            html_content += '<tr><td data-val="!"><span class="icon">📁</span><a href="../">../ (Parent Directory)</a></td><td data-val="0">-</td><td data-val="0">-</td></tr>\n'

        files = []
        for entry in entries:
            stat = entry.stat()
            mtime = stat.st_mtime
            size = stat.st_size if entry.is_file() else 0
            dt = datetime.datetime.fromtimestamp(mtime).strftime('%Y-%m-%d %H:%M:%S')
            
            is_dir = entry.is_dir()
            name = entry.name + ("/" if is_dir else "")
            displayname = html.escape(name)
            linkname = urllib.parse.quote(name)
            
            # Format size to readable format
            if is_dir: size_str = "-"
            elif size < 1024: size_str = f"{size} B"
            elif size < 1024 * 1024: size_str = f"{size / 1024:.2f} KB"
            else: size_str = f"{size / (1024 * 1024):.2f} MB"
            
            icon = "📁" if is_dir else "📄"
            
            files.append({
                'name': displayname, 'link': linkname, 'mtime': mtime, 
                'dt': dt, 'size': size, 'size_str': size_str, 'is_dir': is_dir, 'icon': icon
            })
            
        # Urutkan default: Folder di atas, lalu abjad
        files.sort(key=lambda x: (not x['is_dir'], x['name'].lower()))
        
        for f in files:
            # Gunakan data-val agar script Javascript mensortir angka dengan benar, bukan sebagai teks abjad
            html_content += f'<tr><td data-val="{f["name"]}"><span class="icon">{f["icon"]}</span><a href="{f["link"]}">{f["name"]}</a></td><td data-val="{f["mtime"]}">{f["dt"]}</td><td data-val="{f["size"]}">{f["size_str"]}</td></tr>\n'
            
        html_content += """
    </table>
</body>
</html>
"""
        encoded = html_content.encode("utf-8", "surrogateescape")
        f = io.BytesIO()
        f.write(encoded)
        f.seek(0)
        self.send_response(200)
        self.send_header("Content-type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        return f

if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    server = HTTPServer(('0.0.0.0', port), AdvancedHTTPHandler)
    server.serve_forever()
EOF_PYTHON

    # --- 7. Setup Systemd Service ---
    echo "[*] Membuat Systemd Service..."
    cat << EOF_SYSTEMD > /etc/systemd/system/eset-mirror-http.service
[Unit]
Description=ESET Mirror Advanced HTTP Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${TARGET_DIR}
ExecStart=/usr/bin/python3 ${MIRRORTOOL_DIR}/server.py ${HTTP_PORT}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD

    # --- 8. Setup Logrotate (Kompresi Harian Otomatis) ---
    echo "[*] Mengatur rotasi log harian (Logrotate)..."
    cat << 'EOF_LOGROTATE' > /etc/logrotate.d/esetmirrortools
/var/log/esetmirrortools/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 0644 root root
    postrotate
        systemctl restart eset-mirror-http.service > /dev/null 2>/dev/null || true
    endscript
}
EOF_LOGROTATE

    # --- 9. Konfigurasi Firewall Otomatis ---
    echo "[*] Mengecek status Firewall..."
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then
        echo "[+] UFW aktif. Mengizinkan port $HTTP_PORT/tcp..."
        ufw allow "$HTTP_PORT"/tcp
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        echo "[+] Firewalld aktif. Mengizinkan port $HTTP_PORT/tcp..."
        firewall-cmd --add-port="$HTTP_PORT"/tcp --permanent
        firewall-cmd --reload
    elif command -v iptables >/dev/null 2>&1; then
        echo "[!] Menambahkan rule iptables sementara..."
        iptables -I INPUT -p tcp --dport "$HTTP_PORT" -j ACCEPT
    fi

    # --- 10. Start Service ---
    echo "[*] Menjalankan HTTP Server..."
    systemctl daemon-reload
    systemctl enable eset-mirror-http.service
    systemctl restart eset-mirror-http.service

    # --- Finalisasi ---
    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo "==================================================="
    echo "✅ Setup Selesai & Sukses!"
    echo "🌐 Akses Web Directory: http://${SERVER_IP}:${HTTP_PORT}/"
    echo "📝 File Access Log    : /var/log/esetmirrortools/esetmirrortools.log"
    echo "⚙️  Logrotate          : Aktif (Log akan dikompres setiap hari)"
    echo "==================================================="
}

main "$@"
