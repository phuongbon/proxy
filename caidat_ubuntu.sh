#!/bin/bash

# ==============================================
# 3PROXY UBUNTU INSTALLER - COMPLETE EDITION
# ==============================================

# Check root
[ "$(id -u)" != "0" ] && { echo -e "\033[0;31mError: This script must be run as root\033[0m"; exit 1; }

# Global Configuration
WORKDIR="/home/proxy-installer"
mkdir -p "$WORKDIR"
LOG_FILE="${WORKDIR}/install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# System Variables
IP4=$(curl -4 -s icanhazip.com || echo "0.0.0.0")
IP6=$(curl -6 -s icanhazip.com 2>/dev/null | cut -f1-4 -d':' || echo "fd00::1")
PROXY_PORTS="10000-11000"

# Cleanup Function
cleanup() {
    echo -e "${YELLOW}[+] Cleaning previous installation...${NC}"
    systemctl stop 3proxy 2>/dev/null
    rm -rf /usr/local/etc/3proxy /tmp/3proxy-* "$WORKDIR"/{data.txt,boot_*.sh}
    update-rc.d -f 3proxy remove 2>/dev/null
}

# Install Dependencies
install_deps() {
    echo -e "${YELLOW}[+] Updating system packages...${NC}"
    apt-get update || { echo -e "${RED}Failed to update packages!${NC}"; exit 1; }

    echo -e "${YELLOW}[+] Installing required dependencies...${NC}"
    apt-get install -y \
        build-essential \
        wget \
        tar \
        libssl-dev \
        net-tools \
        curl \
        automake \
        libtool \
        iptables-persistent \
        iproute2 || { echo -e "${RED}Dependency installation failed!${NC}"; exit 1; }
}

# Download and Compile 3proxy
install_3proxy() {
    echo -e "${YELLOW}[+] Downloading 3proxy source code...${NC}"
    cd /tmp/ || exit 1
    wget -q "https://github.com/3proxy/3proxy/archive/refs/tags/0.8.13.tar.gz" -O 3proxy.tar.gz || { echo -e "${RED}Download failed!${NC}"; exit 1; }

    echo -e "${YELLOW}[+] Extracting source files...${NC}"
    tar xzf 3proxy.tar.gz || { echo -e "${RED}Extraction failed!${NC}"; exit 1; }
    cd 3proxy-*/ || { echo -e "${RED}Source directory not found!${NC}"; exit 1; }

    echo -e "${YELLOW}[+] Compiling 3proxy...${NC}"
    make -f Makefile.Linux || { echo -e "${RED}Compilation failed!${NC}"; exit 1; }

    echo -e "${YELLOW}[+] Installing binaries...${NC}"
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cp scripts/init.d/3proxy /etc/init.d/
    chmod +x /etc/init.d/3proxy
    update-rc.d 3proxy defaults
}

# Generate Random Credentials
generate_credentials() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c"${1:-8}"
    echo
}

# Generate IPv6 Address
generate_ipv6() {
    local prefix=$1
    printf "%s:%04x:%04x:%04x:%04x" \
        "$prefix" \
        $((RANDOM % 65536)) \
        $((RANDOM % 65536)) \
        $((RANDOM % 65536)) \
        $((RANDOM % 65536))
}

# Create Proxy Configurations
create_proxy_config() {
    echo -e "${YELLOW}[+] Creating proxy configurations...${NC}"
    
    # Get user input
    read -p "Enter number of proxies to create: " PROXY_COUNT
    [ -z "$PROXY_COUNT" ] && PROXY_COUNT=100
    FIRST_PORT=10000
    LAST_PORT=$((FIRST_PORT + PROXY_COUNT - 1))

    # Generate data file
    echo -e "${YELLOW}[+] Generating proxy data...${NC}"
    for port in $(seq "$FIRST_PORT" "$LAST_PORT"); do
        echo "user$(generate_credentials)/pass$(generate_credentials)/$IP4/$port/$(generate_ipv6 "$IP6")"
    done > "$WORKDIR/data.txt"

    # Generate 3proxy config
    echo -e "${YELLOW}[+] Creating 3proxy.cfg...${NC}"
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

users $(awk -F/ '{print $1":CL:"$2}' "$WORKDIR/data.txt" | tr '\n' ' ')

$(awk -F/ '{print "allow " $1 "\n" \
"proxy -6 -n -a -p" $4 " -i" $3 " -e" $5 "\n" \
"flush\n"}' "$WORKDIR/data.txt")
EOF

    # Generate network config
    echo -e "${YELLOW}[+] Creating network scripts...${NC}"
    cat > "$WORKDIR/boot_iptables.sh" <<EOF
#!/bin/bash
iptables -F
iptables -X
$(awk -F/ '{print "iptables -I INPUT -p tcp --dport " $4 " -j ACCEPT"}' "$WORKDIR/data.txt")
iptables-save > /etc/iptables/rules.v4
EOF

    cat > "$WORKDIR/boot_ifconfig.sh" <<EOF
#!/bin/bash
$(awk -F/ '{print "ip -6 addr add " $5 "/64 dev eth0"}' "$WORKDIR/data.txt")
EOF

    chmod +x "$WORKDIR"/boot_*.sh

    # Generate proxy list
    awk -F/ '{print $3":"$4":"$1":"$2}' "$WORKDIR/data.txt" > "$WORKDIR/proxy.txt"
}

# Setup Auto-start
setup_autostart() {
    echo -e "${YELLOW}[+] Configuring auto-start...${NC}"
    cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
ExecStop=/bin/killall 3proxy
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable 3proxy

    # Add to rc.local if needed
    [ ! -f /etc/rc.local ] && echo "#!/bin/bash" > /etc/rc.local
    chmod +x /etc/rc.local
    grep -q "boot_iptables.sh" /etc/rc.local || {
        echo "bash $WORKDIR/boot_iptables.sh" >> /etc/rc.local
        echo "bash $WORKDIR/boot_ifconfig.sh" >> /etc/rc.local
    }
}

# Start Services
start_services() {
    echo -e "${YELLOW}[+] Starting services...${NC}"
    bash "$WORKDIR/boot_iptables.sh"
    bash "$WORKDIR/boot_ifconfig.sh"
    systemctl start 3proxy
}

# Main Installation
main_install() {
    cleanup
    install_deps
    install_3proxy
    create_proxy_config
    setup_autostart
    start_services

    echo -e "${GREEN}[+] Installation completed successfully!${NC}"
    echo -e "${GREEN}• Proxy list: $WORKDIR/proxy.txt${NC}"
    echo -e "${GREEN}• Config file: /usr/local/etc/3proxy/3proxy.cfg${NC}"
    echo -e "${GREEN}• Log file: $LOG_FILE${NC}"
    echo -e "\n${YELLOW}To manage proxy: systemctl [start|stop|restart] 3proxy${NC}"
}

# Management Menu
show_menu() {
    while true; do
        clear
        echo -e "${GREEN}=== 3PROXY MANAGEMENT MENU ==="
        echo "1. Show proxy list"
        echo "2. Restart proxy"
        echo "3. Stop proxy"
        echo "4. Check status"
        echo "5. Update iptables"
        echo "6. Reinstall proxy"
        echo "0. Exit"
        echo -e "==============================${NC}"
        read -rp "Select option: " choice

        case $choice in
            1) [ -f "$WORKDIR/proxy.txt" ] && cat "$WORKDIR/proxy.txt" || echo "No proxy found";;
            2) systemctl restart 3proxy;;
            3) systemctl stop 3proxy;;
            4) systemctl status 3proxy;;
            5) bash "$WORKDIR/boot_iptables.sh";;
            6) { systemctl stop 3proxy; main_install; };;
            0) exit 0;;
            *) echo -e "${RED}Invalid option!${NC}";;
        esac
        read -rp "Press Enter to continue..."
    done
}

# Execute
if [ "$1" = "menu" ]; then
    show_menu
else
    main_install
    echo -e "\n${GREEN}Run '$(basename "$0") menu' for management options${NC}"
fi
