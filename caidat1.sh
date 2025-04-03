#!/bin/sh

# Improved 3proxy installer script for AlmaLinux 8
# Fixes compilation issues and adds better error handling

random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

spinner() {
    local pid=$1
    local delay=0.1
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

install_dependencies() {
    echo "Installing required dependencies..."
    
    # Install basic tools
    dnf install -y wget bsdtar make gcc gcc-c++ glibc-devel openssl-devel || {
        echo "Failed to install dependencies!"
        exit 1
    }
    
    # Check if gcc is now available
    if ! command -v gcc >/dev/null; then
        echo "GCC still not available after installation!"
        exit 1
    fi
}

install_3proxy() {
    echo "Starting 3proxy installation..."
    
    # Check if already installed
    if [ -f "/usr/local/etc/3proxy/bin/3proxy" ]; then
        echo "3proxy is already installed. Skipping installation."
        return 0
    fi

    URL="https://raw.githubusercontent.com/phuongbon/proxy/main/3proxy-3proxy-0.8.6.tar.gz"
    echo "Downloading 3proxy..."
    (wget -qO- $URL | bsdtar -xvf-) & spinner $!
    if [ $? -ne 0 ]; then
        echo "Download or extraction failed!"
        exit 1
    fi

    cd 3proxy-3proxy-0.8.6 || {
        echo "Failed to enter 3proxy directory!"
        exit 1
    }

    echo "Compiling 3proxy..."
    (make -f Makefile.Linux) & spinner $!
    if [ $? -ne 0 ]; then
        echo "Compilation failed!"
        exit 1
    fi

    echo "Installing 3proxy..."
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/ || {
        echo "Failed to copy 3proxy binary!"
        exit 1
    }
    cp ./scripts/rc.d/proxy.sh /etc/init.d/3proxy || {
        echo "Failed to copy init script!"
        exit 1
    }

    chmod +x /etc/init.d/3proxy
    chkconfig 3proxy on
    cd "$WORKDIR" || {
        echo "Failed to return to working directory!"
        exit 1
    }

    echo "3proxy installation completed."
}

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

users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA})

$(awk -F "/" '{print "auth strong\n" \
"allow " $1 "\n" \
"proxy -6 -n -a -p" $4 " -i" $3 " -e" $5 "\n" \
"flush\n"}' ${WORKDATA})
EOF
}

gen_proxy_file_for_user() {
    if [ ! -f "${WORKDATA}" ]; then
        echo "Data file not found: ${WORKDATA}"
        exit 1
    fi

    echo "Generating proxy.txt..."
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' "${WORKDATA}" > proxy.txt

    if [ -f "proxy.txt" ]; then
        echo "Proxy list created at proxy.txt"
    else
        echo "Failed to create proxy.txt"
        exit 1
    fi
}

gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "user$(random)/pass$(random)/$IP4/$port/$(gen64 $IP6)"
    done
}

gen_iptables() {
    cat <<EOF
$(awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 "  -m state --state NEW -j ACCEPT"}' ${WORKDATA})
EOF
}

gen_ifconfig() {
    cat <<EOF
$(awk -F "/" '{print "ifconfig eth0 inet6 del " $5 "/64 2>/dev/null; ifconfig eth0 inet6 add " $5 "/64"}' ${WORKDATA})
EOF
}

create_new_config() {
    echo "Setting up working directory..."
    WORKDIR="/home/proxy-installer"
    WORKDATA="${WORKDIR}/data.txt"
    mkdir -p "$WORKDIR" && cd "$WORKDIR" || {
        echo "Failed to setup working directory!"
        exit 1
    }

    IP4=$(curl -4 -s icanhazip.com)
    IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

    echo "Internal IP4: ${IP4}"
    echo "Internal IP6 subnet: ${IP6}"

    echo "How many proxies to generate? (e.g. 500)"
    read COUNT

    FIRST_PORT=10000
    LAST_PORT=$(($FIRST_PORT + $COUNT))

    echo "Cleaning old data..."
    [ -f "$WORKDATA" ] && rm -f "$WORKDATA"
    [ -f "${WORKDIR}/boot_iptables.sh" ] && rm -f "${WORKDIR}/boot_iptables.sh"
    [ -f "${WORKDIR}/boot_ifconfig.sh" ] && rm -f "${WORKDIR}/boot_ifconfig.sh"

    echo "Generating proxy data..."
    gen_data >"$WORKDATA"
    
    echo "Generating iptables script..."
    gen_iptables >"${WORKDIR}/boot_iptables.sh"
    
    echo "Generating ifconfig script..."
    gen_ifconfig >"${WORKDIR}/boot_ifconfig.sh"

    chmod +x ${WORKDIR}/boot_*.sh /etc/rc.local

    echo "Generating 3proxy config..."
    [ -f "/usr/local/etc/3proxy/3proxy.cfg" ] && rm -f "/usr/local/etc/3proxy/3proxy.cfg"
    gen_3proxy >/usr/local/etc/3proxy/3proxy.cfg

    echo "Updating rc.local..."
    if ! grep -q "${WORKDIR}/boot_iptables.sh" /etc/rc.local; then
        cat >>/etc/rc.local <<EOF
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 10048
service 3proxy start
EOF
    fi

    echo "Starting services..."
    bash /etc/rc.local

    echo "Generating user proxy file..."
    gen_proxy_file_for_user

    echo "Proxy setup completed. See proxy.txt for details."
}

setup_proxy() {
    install_dependencies
    install_3proxy
    create_new_config
}

refresh_proxy() {
    echo "Refreshing proxies..."
    WORKDIR="/home/proxy-installer"
    WORKDATA="${WORKDIR}/data.txt"

    stop_proxy

    if [ -f "$WORKDATA" ]; then
        awk -F "/" '{print $5}' "$WORKDATA" | while read ip6; do
            ifconfig eth0 inet6 del "$ip6/64" 2>/dev/null
        done
    fi

    rm -rf "$WORKDIR"
    rm -f /usr/local/etc/3proxy/3proxy.cfg

    create_new_config
}

view_proxy_list() { 
    local proxy_file="/home/proxy-installer/proxy.txt"
    if [ -f "$proxy_file" ]; then
        echo "Proxy list:"
        cat "$proxy_file"
    else
        echo "No proxy file found. Please create proxies first."
    fi
}

stop_proxy() {
    echo "Stopping proxy services..."
    
    # Try systemctl first
    if systemctl list-units --type=service | grep -q "3proxy"; then
        systemctl stop 3proxy
    fi
    
    # Try service command
    if service --status-all 2>/dev/null | grep -q "3proxy"; then
        service 3proxy stop
    fi
    
    # Kill any remaining processes
    pkill -9 3proxy 2>/dev/null
    
    echo "Proxy services stopped."
}

start_proxy() {
    echo "Starting proxy services..."
    
    if systemctl list-units --type=service | grep -q "3proxy"; then
        systemctl start 3proxy
    elif service --status-all 2>/dev/null | grep -q "3proxy"; then
        service 3proxy start
    else
        /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
    fi
    
    if pgrep 3proxy >/dev/null; then
        echo "Proxy started successfully."
    else
        echo "Failed to start proxy!"
        exit 1
    fi
}

menu() {
    while true; do
        echo ""
        echo "======== MENU ========="
        echo "1. View proxy list"
        echo "2. Refresh all proxies"
        echo "3. Stop proxy"
        echo "4. Start proxy"
        echo "0. Exit"
        echo "======================="
        echo -n "Select an option: "
        read choice
        
        case $choice in
            1) view_proxy_list ;;
            2) refresh_proxy ;;
            3) stop_proxy ;;
            4) start_proxy ;;
            0) echo "Exiting."; break ;;
            *) echo "Invalid option, please try again." ;;
        esac
        
        echo ""
        echo "Press Enter to continue or 0 to exit."
        read next_action
        [ "$next_action" = "0" ] && break
    done
}

# Main execution
if [ "$1" = "menu" ] || [ "$1" = "start" ]; then
    menu
else
    setup_proxy
    
    # Install script to /usr/local/bin
    SCRIPT_SRC=$(realpath "$0")
    SCRIPT_DEST="/usr/local/bin/proxy-setup"
    
    if [ ! -f "$SCRIPT_SRC" ]; then
        echo "Script file not found!"
        exit 1
    fi
    
    install -m 755 "$SCRIPT_SRC" "$SCRIPT_DEST"
    
    # Add alias to bashrc
    alias_line="alias proxy='bash $SCRIPT_DEST menu'"
    if ! grep -qxF "$alias_line" "$HOME/.bashrc"; then
        echo "$alias_line" >> "$HOME/.bashrc"
        echo "Alias added. Run 'source ~/.bashrc' or open new terminal to use 'proxy' command."
    fi
    
    menu
fi
