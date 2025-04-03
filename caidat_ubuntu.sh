#!/bin/bash

# =========================================
# PROXY INSTALLER FOR UBUNTU (FULL VERSION)
# =========================================

# Check root
if [ "$(id -u)" != "0" ]; then
  echo "ERROR: This script must be run as root!" 1>&2
  exit 1
fi

# Global variables
WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Random string generator
random() {
  tr </dev/urandom -dc A-Za-z0-9 | head -c5
  echo
}

# IPv6 generator
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
  ip64() {
    echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
  }
  echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# Spinner animation
spinner() {
  local pid=$1
  local delay=0.15
  local spinstr='|/-\'
  while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
    local temp=${spinstr#?}
    printf " [%c]  " "$spinstr"
    spinstr=$temp${spinstr%"$temp"}
    sleep $delay
    printf "\b\b\b\b\b\b"
  done
  printf "    \b\b\b\b"
}

# Install dependencies
install_deps() {
  echo -e "${YELLOW}[+] Installing dependencies...${NC}"
  apt-get update > /dev/null 2>&1
  apt-get install -y gcc make wget tar libssl-dev net-tools > /dev/null 2>&1
}

# Install 3proxy
install_3proxy() {
  echo -e "${YELLOW}[+] Downloading 3proxy...${NC}"
  cd /tmp/ || exit 1
  wget -q https://github.com/z3APA3A/3proxy/archive/0.8.6.tar.gz
  tar xzf 0.8.6.tar.gz
  cd 3proxy-0.8.6 || exit 1

  echo -e "${YELLOW}[+] Compiling 3proxy...${NC}"
  make -f Makefile.Linux > /dev/null 2>&1 & spinner $!

  echo -e "${YELLOW}[+] Installing 3proxy...${NC}"
  mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
  cp src/3proxy /usr/local/etc/3proxy/bin/
  cp scripts/init.d/3proxy /etc/init.d/
  chmod +x /etc/init.d/3proxy
  update-rc.d 3proxy defaults > /dev/null 2>&1
}

# Generate proxy data
gen_data() {
  seq $FIRST_PORT $LAST_PORT | while read port; do
    echo "user$(random)/pass$(random)/$IP4/$port/$(gen64 $IP6)"
  done
}

# Generate iptables rules
gen_iptables() {
  awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 "  -m state --state NEW -j ACCEPT"}' ${WORKDATA}
}

# Generate ifconfig commands
gen_ifconfig() {
  awk -F "/" '{print "ip -6 addr add " $5 "/64 dev eth0"}' ${WORKDATA}
}

# Generate 3proxy config
gen_3proxy() {
  cat <<EOF
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

users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA})

$(awk -F "/" '{print "auth strong\n" \
"allow " $1 "\n" \
"proxy -6 -n -a -p" $4 " -i" $3 " -e" $5 "\n" \
"flush\n"}' ${WORKDATA})
EOF
}

# Setup rc.local
setup_rclocal() {
  echo -e "${YELLOW}[+] Configuring startup...${NC}"
  cat > /etc/rc.local <<EOF
#!/bin/bash
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 10048
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
exit 0
EOF
  chmod +x /etc/rc.local
  systemctl enable rc-local > /dev/null 2>&1
}

# Main installation
main_install() {
  mkdir -p $WORKDIR
  cd $WORKDIR || exit 1

  echo -e "${YELLOW}Enter number of proxies to create (e.g. 500):${NC}"
  read COUNT
  FIRST_PORT=10000
  LAST_PORT=$((FIRST_PORT + COUNT))

  echo -e "${YELLOW}[+] Generating proxy data...${NC}"
  gen_data > $WORKDATA

  echo -e "${YELLOW}[+] Creating network config...${NC}"
  gen_iptables > $WORKDIR/boot_iptables.sh
  gen_ifconfig > $WORKDIR/boot_ifconfig.sh
  chmod +x $WORKDIR/boot_*.sh

  echo -e "${YELLOW}[+] Generating 3proxy config...${NC}"
  gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg

  setup_rclocal

  echo -e "${YELLOW}[+] Starting services...${NC}"
  bash /etc/rc.local

  # Generate proxy list
  awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' ${WORKDATA} > $WORKDIR/proxy.txt

  echo -e "${GREEN}[+] Installation completed!${NC}"
  echo -e "${GREEN}Proxy list: ${WORKDIR}/proxy.txt${NC}"
}

# Clean installation
clean_install() {
  echo -e "${YELLOW}[+] Cleaning previous installation...${NC}"
  rm -rf $WORKDIR
  rm -f /usr/local/etc/3proxy/3proxy.cfg
  systemctl stop 3proxy > /dev/null 2>&1
}

# Show menu
show_menu() {
  clear
  echo -e "${GREEN}=== PROXY MANAGEMENT MENU ==="
  echo "1. Install new proxy"
  echo "2. Restart proxy"
  echo "3. Stop proxy"
  echo "4. Show proxy list"
  echo "5. Clean installation"
  echo "0. Exit"
  echo -e "============================${NC}"
  read -p "Select option: " choice

  case $choice in
    1) clean_install; install_deps; install_3proxy; main_install ;;
    2) systemctl restart 3proxy ;;
    3) systemctl stop 3proxy ;;
    4) [ -f $WORKDIR/proxy.txt ] && cat $WORKDIR/proxy.txt || echo "No proxy found" ;;
    5) clean_install ;;
    0) exit 0 ;;
    *) echo "Invalid option" ;;
  esac
  read -p "Press Enter to continue..."
  show_menu
}

# Start script
if [ "$1" == "menu" ]; then
  show_menu
else
  clean_install
  install_deps
  install_3proxy
  main_install
  
  # Create alias
  echo "alias proxy-menu='bash $(realpath $0) menu'" >> ~/.bashrc
  source ~/.bashrc
  
  echo -e "${GREEN}Use 'proxy-menu' to access management menu${NC}"
fi
