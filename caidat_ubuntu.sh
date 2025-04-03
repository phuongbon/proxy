
#!/bin/bash

# Hàm tạo chuỗi ngẫu nhiên
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

# Hàm tạo IPv6
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# Hiệu ứng loading
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

# Cài đặt 3proxy
install_3proxy() {
    echo "Installing dependencies..."
    apt-get update > /dev/null 2>&1
    apt-get -y install gcc make git curl wget net-tools libarchive-tools > /dev/null 2>&1

    echo "Downloading 3proxy..."
    URL="https://github.com/z3APA3A/3proxy/archive/0.8.6.tar.gz"
    wget -qO- $URL | tar xz -C /tmp/ > /dev/null 2>&1
    cd /tmp/3proxy-0.8.6 || exit 1

    echo "Compiling 3proxy..."
    make -f Makefile.Linux > /dev/null 2>&1 & spinner $!

    echo "Installing 3proxy..."
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cp scripts/init.d/3proxy /etc/init.d/
    chmod +x /etc/init.d/3proxy
    update-rc.d 3proxy defaults > /dev/null 2>&1
    cd "$WORKDIR" || exit 1
}

# Tạo file cấu hình 3proxy
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

# Tạo file proxy cho người dùng
gen_proxy_file() {
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' "${WORKDATA}" > proxy.txt
    echo "Proxy list saved to: $(pwd)/proxy.txt"
}

# Tạo dữ liệu proxy
gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "user$(random)/pass$(random)/$IP4/$port/$(gen64 $IP6)"
    done
}

# Tạo iptables rules
gen_iptables() {
    awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 "  -m state --state NEW -j ACCEPT"}' ${WORKDATA}
}

# Tạo lệnh cấu hình IPv6
gen_ifconfig() {
    awk -F "/" '{print "ip -6 addr add " $5 "/64 dev eth0"}' ${WORKDATA}
}

# Khởi tạo cấu hình
init_config() {
    WORKDIR="/home/proxy-installer"
    WORKDATA="${WORKDIR}/data.txt"
    mkdir -p "$WORKDIR" && cd "$WORKDIR" || exit 1

    IP4=$(curl -4 -s icanhazip.com)
    IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

    echo "Nhập số lượng proxy (VD: 500):"
    read COUNT

    FIRST_PORT=10000
    LAST_PORT=$((FIRST_PORT + COUNT))

    # Xóa cấu hình cũ
    rm -f "$WORKDATA" 2>/dev/null
    gen_data > "$WORKDATA"
    
    # Tạo startup scripts
    gen_iptables > boot_iptables.sh
    gen_ifconfig > boot_ifconfig.sh
    chmod +x *.sh

    # Cấu hình 3proxy
    gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg

    # Thêm vào rc.local
    [[ ! -f /etc/rc.local ]] && echo "#!/bin/bash" > /etc/rc.local
    grep -q "boot_iptables.sh" /etc/rc.local || {
        echo "bash ${WORKDIR}/boot_iptables.sh" >> /etc/rc.local
        echo "bash ${WORKDIR}/boot_ifconfig.sh" >> /etc/rc.local
        echo "ulimit -n 10048" >> /etc/rc.local
        echo "/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg" >> /etc/rc.local
    }
    chmod +x /etc/rc.local
    systemctl enable rc-local > /dev/null 2>&1

    # Khởi động dịch vụ
    systemctl start rc-local
    gen_proxy_file
}

# Menu quản lý
menu() {
    while true; do
        clear
        echo "=== PROXY MANAGEMENT ==="
        echo "1. Hiển thị danh sách proxy"
        echo "2. Làm mới toàn bộ proxy"
        echo "3. Dừng dịch vụ proxy"
        echo "4. Khởi động lại proxy"
        echo "5. Xóa toàn bộ proxy"
        echo "0. Thoát"
        echo "========================"
        read -p "Chọn chức năng: " choice

        case $choice in
            1) [ -f proxy.txt ] && cat proxy.txt || echo "Chưa có proxy";;
            2) refresh_proxy;;
            3) systemctl stop rc-local;;
            4) systemctl start rc-local;;
            5) clean_proxy;;
            0) exit 0;;
            *) echo "Lựa chọn không hợp lệ!";;
        esac
        read -p "Nhấn Enter để tiếp tục..."
    done
}

# Xóa proxy
clean_proxy() {
    systemctl stop rc-local
    rm -rf /home/proxy-installer
    rm -f /usr/local/etc/3proxy/3proxy.cfg
    echo "Đã xóa toàn bộ proxy!"
}

# Làm mới proxy
refresh_proxy() {
    clean_proxy
    init_config
    systemctl start rc-local
    echo "Proxy đã được làm mới!"
}

# Main
if [ "$(id -u)" != "0" ]; then
    echo "Script cần chạy với quyền root!"
    exit 1
fi

if [ "$1" == "menu" ]; then
    menu
else
    install_3proxy
    init_config
    echo "Cài đặt hoàn tất! Gõ 'proxy-menu' để vào menu quản lý"
    
    # Tạo alias
    echo "alias proxy-menu='bash $(realpath $0) menu'" >> ~/.bashrc
    source ~/.bashrc
fi
