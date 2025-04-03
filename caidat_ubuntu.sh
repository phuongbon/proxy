#!/bin/bash

# ==============================================
# 3PROXY INSTALLER FOR UBUNTU (FULL VERSION)
# ==============================================

# Check root
if [ "$(id -u)" != "0" ]; then
  echo -e "\033[0;31mERROR: This script must be run as root!\033[0m" 1>&2
  exit 1
fi

# Global Config
WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
LOG_FILE="${WORKDIR}/install.log"
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Clean install
clean_install() {
  echo -e "${YELLOW}[+] Cleaning previous installation...${NC}"
  rm -rf "$WORKDIR" 2>/dev/null
  rm -f /usr/local/etc/3proxy/3proxy.cfg 2>/dev/null
  systemctl stop 3proxy 2>/dev/null
}

# Install dependencies
install_deps() {
  echo -e "${YELLOW}[+] Updating packages...${NC}"
  apt-get update >> "$LOG_FILE" 2>&1 || {
    echo -e "${RED}ERROR: Failed to update packages! Check ${LOG_FILE}${NC}" >&2
    exit 1
  }

  echo -e "${YELLOW}[+] Installing dependencies...${NC}"
  apt-get install -y \
    gcc make wget tar libssl-dev \
    net-tools curl automake libtool >> "$LOG_FILE" 2>&1 || {
    echo -e "${RED}ERROR: Dependency installation failed! Check ${LOG_FILE}${NC}" >&2
    exit 1
  }
}

# Install 3proxy
install_3proxy() {
  echo -e "${YELLOW}[+] Downloading 3proxy...${NC}"
  cd /tmp/ || exit 1
  wget -q "https://github.com/z3APA3A/3proxy/archive/refs/tags/0.8.6.tar.gz" -O 3proxy-0.8.6.tar.gz || {
    echo -e "${RED}ERROR: Failed to download 3proxy!${NC}" >&2
    exit 1
  }

  echo -e "${YELLOW}[+] Extracting 3proxy...${NC}"
  tar xzf 3proxy-0.8.6.tar.gz >> "$LOG_FILE" 2>&1 || {
    echo -e "${RED}ERROR: Extraction failed! Check ${LOG_FILE}${NC}" >&2
    exit 1
  }

  cd 3proxy-0.8.6/ || {
    echo -e "${RED}ERROR: Cannot enter 3proxy directory!${NC}" >&2
    exit 1
  }

  echo -e "${YELLOW}[+] Compiling 3proxy...${NC}"
  make -f Makefile.Linux >> "$LOG_FILE" 2>&1 || {
    echo -e "${RED}ERROR: Compilation failed! Check ${LOG_FILE}${NC}" >&2
    exit 1
  }

  echo -e "${YELLOW}[+] Installing 3proxy...${NC}"
  mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
  cp src/3proxy /usr/local/etc/3proxy/bin/
  cp scripts/init.d/3proxy /etc/init.d/
  chmod +x /etc/init.d/3proxy
  update-rc.d 3proxy defaults >> "$LOG_FILE" 2>&1
}

# Generate random credentials
random() {
  tr </dev/urandom -dc A-Za-z0-9 | head -c5
  echo
}

# Generate IPv6 addresses
gen_ipv6() {
  array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
  ip64() {
    echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
  }
  echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# Generate proxy data
gen_data() {
  seq "$FIRST_PORT" "$LAST_PORT" | while read -r port; do
    echo "user$(random)/pass$(random)/$IP4/$port/$(gen_ipv6 "$IP6")"
  done
}

# Generate config files
gen_configs() {
  echo -e "${YELLOW}[+] Generating config files...${NC}"

  # iptables rules
  awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 "  -m state --state NEW -j ACCEPT"}' "${WORKDATA}" > "${WORKDIR}/boot_iptables.sh"

  # IPv6 config
  awk -F "/" '{print "ip -6 addr add " $5 "/64 dev eth0"}' "${WORKDATA}" > "${WORKDIR}/boot_ifconfig.sh"

  # 3proxy config
  cat > /usr/local/etc/3proxy/3proxy.cfg <<EOF
daemon
maxconn 2000
nserver 1.1.1.1
nserver 8.8.4.4
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
flush
auth strong

users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' "${WORKDATA}")

$(awk -F "/" '{print "auth strong\n" \
"allow " $1 "\n" \
"proxy -6 -n -a -p" $4 " -i" $3 " -e" $5 "\n" \
"flush\n"}' "${WORKDATA}")
EOF

  chmod +x "${WORKDIR}/boot_"*.sh
}

# Setup autostart
setup_autostart() {
  echo -e "${YELLOW}[+] Configuring autostart...${NC}"
  cat > /etc/rc.local <<EOF
#!/bin/bash
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 10048
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
exit 0
EOF
  chmod +x /etc/rc.local
  systemctl enable rc-local >> "$LOG_FILE" 2>&1
}

# Main installation
main_install() {
  mkdir -p "$WORKDIR"
  cd "$WORKDIR" || exit 1

  echo -e "${YELLOW}Enter number of proxies to create:${NC}"
  read -r COUNT
  FIRST_PORT=10000
  LAST_PORT=$((FIRST_PORT + COUNT - 1))

  echo -e "${YELLOW}[+] Generating proxy data...${NC}"
  gen_data > "$WORKDATA"

  gen_configs
  setup_autostart

  echo -e "${YELLOW}[+] Starting services...${NC}"
  bash /etc/rc.local >> "$LOG_FILE" 2>&1

  # Generate proxy list
  awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' "${WORKDATA}" > "${WORKDIR}/proxy.txt"

  echo -e "${GREEN}[+] Installation completed!${NC}"
  echo -e "${GREEN}• Proxy list: ${WORKDIR}/proxy.txt${NC}"
  echo -e "${GREEN}• Config file: /usr/local/etc/3proxy/3proxy.cfg${NC}"
  echo -e "${GREEN}• Log file: ${LOG_FILE}${NC}"
}

# Start installation
clean_install
install_deps
install_3proxy
main_install

# Create management alias
echo "alias proxy-menu='bash $(realpath "$0") menu'" >> /root/.bashrc
source /root/.bashrc

echo -e "${GREEN}Use 'proxy-menu' to access management console${NC}"
