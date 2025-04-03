#!/bin/bash

# Define constants and variables
WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
LOGFILE="${WORKDIR}/proxy_install.log"
PROXY_CFG="/usr/local/etc/3proxy/3proxy.cfg"
IP4=$(curl -4 -s icanhazip.com 2>/dev/null)
IP6=$(curl -6 -s icanhazip.com 2>/dev/null | cut -f1-4 -d':')

# Ensure script runs as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root. Use sudo or switch to root user."
    exit 1
fi

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

# Random string generator
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

# IPv6 address segment generator
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$((RANDOM % 16))]}${array[$((RANDOM % 16))]}${array[$((RANDOM % 16))]}${array[$((RANDOM % 16))]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# Spinner for visual feedback
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while ps -p "$pid" >/dev/null 2>&1; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep "$delay"
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Install 3proxy
install_3proxy() {
    log "Starting 3proxy installation..."
    local URL="https://raw.githubusercontent.com/phuongbon/proxy/main/3proxy-3proxy-0.8.6.tar.gz"
    mkdir -p /tmp/3proxy_install && cd /tmp/3proxy_install || { log "Failed to create temp directory"; exit 1; }
    (wget -qO- "$URL" | tar -xzf -) & spinner $!
    if [ $? -ne 0 ]; then
        log "Failed to download or extract 3proxy!"
        exit 1
    fi
    cd 3proxy-3proxy-0.8.6 || { log "3proxy directory not found!"; exit 1; }
    (make -f Makefile.Linux) & spinner $!
    if [ $? -ne 0 ]; then
        log "3proxy compilation failed!"
        exit 1
    fi
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat} || { log "Failed to create 3proxy directories!"; exit 1; }
    cp src/3proxy /usr/local/etc/3proxy/bin/ || { log "Failed to copy 3proxy binary!"; exit 1; }
    cp scripts/rc.d/proxy.sh /etc/init.d/3proxy || { log "Failed to copy 3proxy init script!"; exit 1; }
    chmod +x /etc/init.d/3proxy
    chkconfig --add 3proxy 2>/dev/null || systemctl enable 3proxy.service 2>/dev/null
    cd "$WORKDIR" || { log "Failed to return to working directory!"; exit 1; }
    log "3proxy installation completed."
}

# Generate 3proxy configuration
gen_3proxy() {
    cat <<EOF
daemon
maxconn 2000
nserver 1.1.1.1
nserver 8.8.4.4
nserver 2001:4860:4860::8888
nserver 2001:4860:4860::8844
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
}

# Generate proxy file for user
gen_proxy_file_for_user() {
    [ ! -f "${WORKDATA}" ] && { log "Data file ${WORKDATA} not found!"; exit 1; }
    log "Generating proxy.txt..."
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' "${WORKDATA}" > "${WORKDIR}/proxy.txt"
    [ -f "${WORKDIR}/proxy.txt" ] && log "Proxy file generated at ${WORKDIR}/proxy.txt" || { log "Failed to generate proxy.txt!"; exit 1; }
}

# Generate proxy data
gen_data() {
    seq "$FIRST_PORT" "$LAST_PORT" | while read port; do
        echo "phuong$(random)/phuongphuong$(random)/$IP4/$port/$(gen64 "$IP6")"
    done
}

# Generate iptables rules
gen_iptables() {
    awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 " -m state --state NEW -j ACCEPT"}' "${WORKDATA}"
}

# Generate ifconfig commands for IPv6
gen_ifconfig() {
    awk -F "/" '{print "ifconfig eth0 inet6 del " $5 "/64 2>/dev/null; ifconfig eth0 inet6 add " $5 "/64"}' "${WORKDATA}"
}

# Create new proxy configuration
create_new_config() {
    log "Creating working directory at $WORKDIR"
    mkdir -p "$WORKDIR" && cd "$WORKDIR" || { log "Failed to create or access $WORKDIR!"; exit 1; }

    log "Internal IPv4: ${IP4}"
    log "IPv6 subnet: ${IP6}"

    echo "How many proxies do you want to create? (e.g., 500)"
    read -r COUNT
    FIRST_PORT=10000
    LAST_PORT=$((FIRST_PORT + COUNT))

    # Clean up old data
    for file in "$WORKDATA" "${WORKDIR}/boot_iptables.sh" "${WORKDIR}/boot_ifconfig.sh"; do
        [ -f "$file" ] && rm -f "$file" && log "Removed old $file" || log "No old $file to remove"
    done

    log "Generating proxy data..."
    gen_data > "$WORKDATA" || { log "Failed to generate proxy data!"; exit 1; }
    log "Proxy data generation completed."

    log "Generating iptables script..."
    gen_iptables > "${WORKDIR}/boot_iptables.sh" || { log "Failed to generate iptables script!"; exit 1; }
    log "Generating IPv6 config script..."
    gen_ifconfig > "${WORKDIR}/boot_ifconfig.sh" || { log "Failed to generate ifconfig script!"; exit 1; }
    chmod +x "${WORKDIR}/boot_*.sh" || { log "Failed to set executable permissions!"; exit 1; }

    log "Generating 3proxy configuration..."
    [ -f "$PROXY_CFG" ] && rm -f "$PROXY_CFG"
    gen_3proxy > "$PROXY_CFG" || { log "Failed to generate 3proxy config!"; exit 1; }

    log "Updating /etc/rc.local..."
    if ! grep -q "${WORKDIR}/boot_iptables.sh" /etc/rc.local 2>/dev/null; then
        echo -e "bash ${WORKDIR}/boot_iptables.sh\nbash ${WORKDIR}/boot_ifconfig.sh\nulimit -n 10048\nservice 3proxy start" >> /etc/rc.local
        chmod +x /etc/rc.local
        log "Updated /etc/rc.local."
    else
        log "/etc/rc.local already configured."
    fi

    log "Applying configuration..."
    bash /etc/rc.local || { log "Failed to apply configuration!"; exit 1; }
    gen_proxy_file_for_user
    log "Configuration completed. Check ${WORKDIR}/proxy.txt for proxy details."
}

# Setup proxy environment
setup_proxy() {
    log "Updating system..."
    (yum update -y) & spinner $!
    log "System update completed."

    log "Installing required packages..."
    (yum -y install gcc net-tools tar zip curl wget nano make gcc-c++ glibc glibc-devel iptables-services) & spinner $!
    log "Package installation completed."

    install_3proxy
    create_new_config
}

# Refresh proxy configuration
refresh_proxy() {
    log "Refreshing proxy configuration..."
    stop_proxy
    [ -f "$WORKDATA" ] && awk -F "/" '{print $5}' "$WORKDATA" | while read ip6; do
        ifconfig eth0 inet6 del "$ip6/64" 2>/dev/null
    done
    rm -rf "$WORKDIR" "$PROXY_CFG"
    create_new_config
    log "Proxy refresh completed."
}

# View proxy list
view_proxy_list() {
    local proxy_file="${WORKDIR}/proxy.txt"
    if [ -f "$proxy_file" ]; then
        log "Displaying proxy list:"
        cat "$proxy_file"
    else
        log "No proxy file found at $proxy_file. Please create proxies first."
    fi
}

# Stop proxy services
stop_proxy() {
    log "Stopping all 3proxy-related services..."
    systemctl stop 3proxy.service 2>/dev/null && log "Stopped 3proxy via systemctl" || log "No 3proxy systemctl service found"
    service 3proxy stop 2>/dev/null && log "Stopped 3proxy via service" || log "No 3proxy service found"
    pkill -9 3proxy 2>/dev/null && log "Killed all 3proxy processes" || log "No 3proxy processes running"
    log "3proxy services stopped."
}

# Start proxy services
start_proxy() {
    log "Starting proxy..."
    systemctl start 3proxy.service 2>/dev/null && log "Started 3proxy via systemctl" || service 3proxy start 2>/dev/null && log "Started 3proxy via service"
    pgrep 3proxy >/dev/null && log "3proxy is running successfully" || { log "Failed to start 3proxy!"; exit 1; }
    log "Proxy startup completed."
}

# Menu interface
menu() {
    while true; do
        echo -e "\n======== MENU ========="
        echo "1. View created proxy list"
        echo "2. Refresh all proxies"
        echo "3. Stop proxy"
        echo "4. Start proxy"
        echo "0. Exit"
        echo "======================="
        read -p "Choose an option: " choice
        case $choice in
            1) view_proxy_list ;;
            2) refresh_proxy ;;
            3) stop_proxy ;;
            4) start_proxy ;;
            0) log "Exiting menu."; break ;;
            *) echo "Invalid option, please try again." ;;
        esac
        read -p "Enter 'proxy' to return to menu or '0' to exit: " next_action
        [ "$next_action" = "0" ] && break
    done
}

# Main execution
if [ "$1" = "menu" ] || [ "$1" = "start" ]; then
    menu
else
    setup_proxy
    SCRIPT_SRC="$(realpath "$0")"
    SCRIPT_DEST="/usr/local/bin/proxy_setup.sh"
    install -m 755 "$SCRIPT_SRC" "$SCRIPT_DEST"
    alias_line="alias menu='bash $SCRIPT_DEST menu'"
    if ! grep -qxF "$alias_line" "$HOME/.bashrc"; then
        echo "$alias_line" >> "$HOME/.bashrc"
        log "Added 'menu' alias to ~/.bashrc. Run 'source ~/.bashrc' to apply."
    fi
    menu
fi
