#!/bin/bash

# --- Warna untuk output konsol ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- DEFINISI PASSWORD (EDIT SESUAI KEBUTUHAN ANDA) ---
# CATATAN: Sangat disarankan untuk mengubah password ini setelah instalasi berhasil untuk keamanan.
MYSQL_ROOT_PASSWORD="Webadmin123" # Ganti dengan password MySQL root Anda
ESET_SERVER_ROOT_PASSWORD="Webadmin@2025ber"      # Ganti dengan password root ESET PROTECT Anda (jika berbeda)

# --- DEFINISI URL UNDUHAN (EDIT JIKA VERSI ATAU ALAMAT BERUBAH) ---
TOMCAT_DOWNLOAD_URL="https://dlcdn.apache.org/tomcat/tomcat-9/v9.0.107/bin/apache-tomcat-9.0.107.tar.gz"

echo -e "${YELLOW}Starting ESET PROTECT and Tomcat Webapps installation script.${NC}"
echo -e "${YELLOW}This script requires root privileges. Please run with 'sudo bash install_eset.sh'.${NC}"
echo -e "${YELLOW}Ensure you have an active internet connection.${NC}"
echo ""

# --- Fungsi untuk memeriksa keberhasilan perintah ---
check_success() {
    if [ $? -ne 0 ]; then
        echo -e "${RED}ERROR: $1 failed. Exiting.${NC}"
        exit 1
    else
        echo -e "${GREEN}SUCCESS: $1 completed.${NC}"
    fi
}

# --- Bagian 1: Implementasi Tomcat Webapps ---
echo -e "${YELLOW}--- Starting Tomcat Webapps Implementation ---${NC}"

echo -e "${GREEN}Updating and upgrading system packages...${NC}"
apt update && apt upgrade -y
check_success "apt update & apt upgrade"

echo -e "${GREEN}Installing OpenJDK 17...${NC}"
apt install openjdk-17-jdk -y
check_success "OpenJDK 17 installation"

echo -e "${GREEN}Creating 'tomcat' user...${NC}"
useradd -m -U -d /opt/tomcat -s /bin/false tomcat
check_success "tomcat user creation"

echo -e "${GREEN}Downloading Apache Tomcat 9 from ${TOMCAT_DOWNLOAD_URL}...${NC}"
wget "${TOMCAT_DOWNLOAD_URL}" -P /tmp/
check_success "Tomcat download"

echo -e "${GREEN}Extracting Tomcat to /opt/tomcat...${NC}"
# Nama file di sini harus diekstrak dari URL, atau jika Anda tahu polanya
# Anda bisa menggunakan wildcard seperti apache-tomcat-9*tar.gz
# Untuk kejelasan, kita bisa ekstrak nama file dari URL
TOMCAT_FILENAME=$(basename "${TOMCAT_DOWNLOAD_URL}")
tar xzvf "/tmp/${TOMCAT_FILENAME}" -C /opt/tomcat --strip-components=1
check_success "Tomcat extraction"

echo -e "${GREEN}Setting ownership for /opt/tomcat...${NC}"
chown -R tomcat:tomcat /opt/tomcat
check_success "Setting Tomcat ownership"

# Mencari JAVA_HOME secara dinamis
JAVA_HOME=$(update-java-alternatives --list | grep 'java-1.17.0-openjdk' | awk '{print $NF}')
if [ -z "$JAVA_HOME" ]; then
    echo -e "${RED}WARNING: Could not automatically detect JAVA_HOME for OpenJDK 17. Using a common path.${NC}"
    JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64" # Fallback path
fi
echo -e "${GREEN}Detected JAVA_HOME: ${JAVA_HOME}${NC}"


echo -e "${GREEN}Creating tomcat9.service systemd file...${NC}"
cat <<EOF >> /etc/systemd/system/tomcat9.service
[Unit]
Description=Tomcat Server
After=network.target

[Service]
Type=forking
User=tomcat
Group=tomcat
Environment="JAVA_HOME=${JAVA_HOME}"
WorkingDirectory=/opt/tomcat/

ExecStart=/opt/tomcat/bin/startup.sh
ExecStop=/opt/tomcat/bin/shutdown.sh

[Install]
WantedBy=multi-user.target
EOF
check_success "Creating tomcat9.service"

echo -e "${GREEN}Reloading systemd daemon...${NC}"
systemctl daemon-reload
check_success "systemctl daemon-reload"

echo -e "${GREEN}Starting Tomcat9 service...${NC}"
systemctl start tomcat9
check_success "Start tomcat9 service"

echo -e "${GREEN}Checking Tomcat9 service status...${NC}"
systemctl status tomcat9 --no-pager
echo ""

echo -e "${GREEN}Downloading ESET ERA WAR file...${NC}"
wget https://download.eset.com/com/eset/apps/business/era/webconsole/latest/era.war -P /tmp/
check_success "ERA WAR download"

echo -e "${GREEN}Copying era.war to Tomcat webapps directory...${NC}"
cp /tmp/era.war /opt/tomcat/webapps/
check_success "Copying era.war"

echo -e "${GREEN}Stopping and restarting Tomcat9 service for ERA deployment...${NC}"
systemctl stop tomcat9
check_success "Stop tomcat9 service"
systemctl start tomcat9
check_success "Start tomcat9 service"

echo -e "${YELLOW}Tomcat and Webapps implementation completed.${NC}"
echo -e "${YELLOW}Please check access to Tomcat with http://your-ip-address:8080/era${NC}"
echo ""

# --- Bagian 2: ESET PROTECT + Dependencies ---
echo -e "${YELLOW}--- Starting ESET PROTECT + Dependencies Installation ---${NC}"

echo -e "${GREEN}Downloading MySQL Connector ODBC and MySQL APT Config...${NC}"
wget https://cdn.mysql.com/archives/mysql-connector-odbc-9.2/mysql-connector-odbc-9.2.0-linux-glibc2.28-x86-64bit.tar.gz -P /tmp/
check_success "MySQL Connector ODBC download"
wget https://repo.mysql.com//mysql-apt-config_0.8.34-1_all.deb -P /tmp/
check_success "MySQL APT Config download"

echo -e "${GREEN}Installing MySQL APT Config (you will be prompted to choose MySQL version, select 8.4.x)...${NC}"
dpkg -i /tmp/mysql-apt-config_0.8.34-1_all.deb
check_success "MySQL APT Config installation"

echo -e "${GREEN}Adding PPA for Qt4 dependencies...${NC}"
add-apt-repository ppa:rock-core/qt4 -y
check_success "Adding Qt4 PPA"

echo -e "${GREEN}Updating and upgrading packages again...${NC}"
apt update -y && apt upgrade -y
check_success "apt update & upgrade"

echo -e "${GREEN}Installing ESET PROTECT dependencies...${NC}"
apt install -y wget lshw unixodbc libodbc2 xvfb cifs-utils krb5-user winbind ldap-utils snmp ldap-utils libsasl2-modules-gssapi-mit selinux-policy-dev libqt5webkit5
check_success "ESET PROTECT dependencies installation"

echo -e "${GREEN}Installing MySQL Community Server...${NC}"
# Perintah instalasi MySQL Community Server akan meminta password root baru.
# Gunakan 'debconf-set-selections' untuk pre-seed password.
echo "mysql-community-server mysql-community-server/root-pass password ${MYSQL_ROOT_PASSWORD}" | debconf-set-selections
echo "mysql-community-server mysql-community-server/re-root-pass password ${MYSQL_ROOT_PASSWORD}" | debconf-set-selections
apt-get install mysql-community-server -y
check_success "MySQL Community Server installation"

echo -e "${GREEN}Configuring MySQL settings for ESET requirements...${NC}"
# Membuat backup file config asli
cp /etc/mysql/mysql.conf.d/mysqld.cnf /etc/mysql/mysql.conf.d/mysqld.cnf.bak_eset_$(date +%Y%m%d%H%M%S)

# Menambahkan konfigurasi ke mysqld.cnf
cat <<EOF >> /etc/mysql/mysql.conf.d/mysqld.cnf

# ESET Requirement
max_allowed_packet = 500M
log_bin_trust_function_creators=1
innodb_log_file_size = 200M
innodb_log_files_in_group = 4
innodb_lock_wait_timeout=600
EOF
check_success "MySQL configuration update"

echo -e "${GREEN}Restarting MySQL service...${NC}"
systemctl restart mysql
check_success "MySQL service restart"

# Otomatisasi pengecekan login MySQL (opsional, karena password sudah di-set)
echo -e "${GREEN}Verifying MySQL root login...${NC}"
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT User, Host FROM mysql.user;" > /dev/null 2>&1
check_success "MySQL root login verification"

echo -e "${GREEN}Installing ODBC utilities...${NC}"
apt-get install odbcinst -y
check_success "odbcinst installation"

echo -e "${GREEN}Checking ODBC status path config...${NC}"
odbcinst -j
echo ""

echo -e "${GREEN}Extracting MySQL Connector ODBC...${NC}"
tar xvzf /tmp/mysql-connector-odbc-9.2.0-linux-glibc2.28-x86-64bit.tar.gz -C /tmp/
check_success "MySQL Connector ODBC extraction"

echo -e "${GREEN}Copying ODBC driver to /usr/lib/x86_64-linux-gnu/...${NC}"
cp /tmp/mysql-connector-odbc-9.2.0-linux-glibc2.28-x86-64bit/lib/libmyodbc9* /usr/lib/x86_64-linux-gnu/
check_success "Copying ODBC driver"

echo -e "${GREEN}Checking copied ODBC driver file...${NC}"
ls -lsb /usr/lib/x86_64-linux-gnu/ | grep libmyodbc9
echo ""

echo -e "${GREEN}Configuring /etc/odbcinst.ini for MySQL ODBC 9.2...${NC}"
# Membuat backup file config asli
cp /etc/odbcinst.ini /etc/odbcinst.ini.bak_eset_$(date +%Y%m%d%H%M%S)

# Menambahkan konfigurasi ke odbcinst.ini
cat <<EOF >> /etc/odbcinst.ini

[MySQL ODBC 9.2]
Driver=/usr/lib/x86_64-linux-gnu/libmyodbc9w.so
#SETUP=/usr/lib/x86_64-linux-gnu/libmyodbc9S.so
UsageCount=1
EOF
check_success "odbcinst.ini configuration"

echo -e "${GREEN}Checking Name DSN ODBC Config...${NC}"
odbcinst -q -d
echo ""

echo -e "${GREEN}Downloading ESET PROTECT Server, Bridge, and RDSensor installers...${NC}"
wget https://download.eset.com/com/eset/apps/business/era/server/linux/latest/server-linux-x86_64.sh -P /tmp/
check_success "ESET PROTECT Server download"
wget https://download.eset.com/com/eset/apps/business/ech/latest/eset-bridge.x86_64.bin -P /tmp/
check_success "ESET Bridge download"
wget https://download.eset.com/com/eset/apps/business/era/rdsensor/latest/rdsensor-linux-x86_64.sh -P /tmp/
check_success "RDSensor download"

echo -e "${GREEN}Making installers executable...${NC}"
chmod +x /tmp/server-linux-x86_64.sh
chmod +x /tmp/eset-bridge.x86_64.bin
chmod +x /tmp/rdsensor-linux-x86_64.sh
check_success "Making installers executable"

echo -e "${GREEN}Running ESET PROTECT Server installer (this may take some time)...${NC}"
/tmp/server-linux-x86_64.sh \
    --skip-license \
    --db-driver="MySQL ODBC 9.2" \
    --db-hostname=127.0.0.1 \
    --db-port=3306 \
    --db-admin-username=root \
    --db-admin-password="${MYSQL_ROOT_PASSWORD}" \
    --server-root-password="${ESET_SERVER_ROOT_PASSWORD}" \
    --db-user-username=root \
    --db-user-password="${MYSQL_ROOT_PASSWORD}" \
    --cert-hostname="*" \
    --enable-imp-program
check_success "ESET PROTECT Server installation"

echo -e "${GREEN}Running ESET Bridge installer...${NC}"
/tmp/eset-bridge.x86_64.bin -y
check_success "ESET Bridge installation"

echo -e "${GREEN}Running RDSensor installer...${NC}"
/tmp/rdsensor-linux-x86_64.sh
check_success "RDSensor installation"

echo -e "${YELLOW}--- ESET PROTECT + Dependencies installation completed ---${NC}"
echo -e "${GREEN}All installations completed successfully!${NC}"
echo -e "${YELLOW}Tested on Ubuntu 24.04.2 LTS.${NC}"
echo -e "${YELLOW}Installer Agent didapatkan via Console ESET PROTECT, jika installer didapatkan anda dapat menjalankan script installer Agentnya.${NC}"
echo ""
