#!/bin/bash
# Script cài đặt và cấu hình 3proxy
# Yêu cầu: Chạy với quyền root

set -euo pipefail
IFS=$'\n\t'

# Hàm tạo chuỗi ngẫu nhiên gồm 5 ký tự chữ và số
random() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c5
    echo
}

# Định nghĩa mảng cho các ký tự hex
hex_array=(0 1 2 3 4 5 6 7 8 9 a b c d e f)

# Hàm tạo một đoạn IPv6 ngẫu nhiên
gen64() {
    printf "%s%s%s%s" "${hex_array[$((RANDOM % 16))]}" \
                        "${hex_array[$((RANDOM % 16))]}" \
                        "${hex_array[$((RANDOM % 16))]}" \
                        "${hex_array[$((RANDOM % 16))]}"
}

# Hàm spinner để hiển thị tiến trình
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while kill -0 "$pid" 2>/dev/null; do
        for char in $spinstr; do
            printf " [%c]  " "$char"
            sleep "$delay"
            printf "\b\b\b\b\b\b"
        done
    done
    wait "$pid" 2>/dev/null
    printf "    \b\b\b\b"
}

# Hàm cài đặt 3proxy
install_3proxy() {
    echo "Bắt đầu cài đặt 3proxy..."
    local URL="https://raw.githubusercontent.com/quayvlog/quayvlog/main/3proxy-3proxy-0.8.6.tar.gz"

    # Tải xuống và giải nén 3proxy
    wget -qO- "$URL" | bsdtar -xvf- &
    spinner $!

    # Kiểm tra xem thư mục 3proxy đã được giải nén chưa
    if [ ! -d "3proxy-3proxy-0.8.6" ]; then
        echo "Không thể giải nén 3proxy. Kiểm tra lại URL hoặc kết nối mạng."
        exit 1
    fi

    cd 3proxy-3proxy-0.8.6

    # Biên dịch 3proxy
    make -f Makefile.Linux &
    spinner $!

    # Tạo các thư mục cấu hình và sao chép binary
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cp scripts/rc.d/proxy.sh /etc/init.d/3proxy

    # Thiết lập quyền thực thi cho script khởi động
    chmod +x /etc/init.d/3proxy

    # Thêm dịch vụ vào các dịch vụ khởi động cùng hệ thống
    chkconfig --add 3proxy
    chkconfig 3proxy on

    # Quay lại thư mục làm việc chính
    cd "$WORKDIR"

    echo "Cài đặt 3proxy hoàn tất."
}

# Hàm tạo cấu hình cho 3proxy
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

users $(awk -F "/" 'BEGIN{ORS=" "} {print $1 ":CL:" $2}' "${WORKDATA}")

$(awk -F "/" '{
    print "auth strong\nallow " $1 "\nproxy -6 -n -a -p" $4 " -i" $3 " -e" $5 "\nflush"
}' "${WORKDATA}")
EOF
}

# Hàm tạo file proxy.txt cho người dùng
gen_proxy_file_for_user() {
    if [[ ! -f "${WORKDATA}" ]]; then
        echo "Không tìm thấy tệp dữ liệu: ${WORKDATA}. Vui lòng kiểm tra lại!"
        exit 1
    fi

    echo "Đang tạo file proxy.txt..."
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' "${WORKDATA}" > proxy.txt

    echo "Tạo file proxy hoàn tất tại proxy.txt."
}

# Hàm tạo dữ liệu proxy
gen_data() {
    for port in $(seq "$FIRST_PORT" "$LAST_PORT"); do
        echo "phuong$(random)/phuongphuong$(random)/$IP4/$port/$(gen64)"
    done
}

# Hàm tạo các quy tắc iptables
gen_iptables() {
    awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 " -m state --state NEW -j ACCEPT"}' "${WORKDATA}"
}

# Hàm tạo các lệnh cấu hình IPv6
gen_ifconfig() {
    awk -F "/" '{print "ifconfig eth0 inet6 del " $5 "/64 2>/dev/null; ifconfig eth0 inet6 add " $5 "/64"}' "${WORKDATA}"
}

# Hàm tạo cấu hình mới
create_new_config() {
    echo "Tạo thư mục làm việc tại /home/proxy-installer..."
    WORKDIR="/home/proxy-installer"
    WORKDATA="${WORKDIR}/data.txt"
    mkdir -p "$WORKDIR"
    cd "$WORKDIR"

    # Lấy địa chỉ IPv4 và subnet IPv6
    IP4=$(curl -4 -s icanhazip.com)
    IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

    echo "Địa chỉ IPv4: ${IP4}"
    echo "Subnet IPv6: ${IP6}"

    echo "Bạn muốn tạo bao nhiêu proxy? Ví dụ: 500"
    read -r COUNT

    FIRST_PORT=10000
    LAST_PORT=$((FIRST_PORT + COUNT - 1))

    # Xóa dữ liệu cũ và script nếu tồn tại
    echo "Kiểm tra và xóa dữ liệu cũ..."
    rm -f "$WORKDATA" "${WORKDIR}/boot_iptables.sh" "${WORKDIR}/boot_ifconfig.sh" || true

    # Tạo dữ liệu proxy mới
    echo "Đang tạo dữ liệu proxy..."
    gen_data > "$WORKDATA"
    echo "Tạo dữ liệu proxy hoàn tất."

    # Tạo script iptables
    echo "Đang tạo script iptables..."
    gen_iptables > "${WORKDIR}/boot_iptables.sh"
    echo "Script iptables đã được tạo."

    # Tạo script cấu hình IPv6
    echo "Đang tạo script cấu hình IPv6..."
    gen_ifconfig > "${WORKDIR}/boot_ifconfig.sh"
    echo "Script cấu hình IPv6 đã được tạo."

    chmod +x "${WORKDIR}/boot_"*.sh /etc/rc.local

    # Tạo file cấu hình 3proxy
    echo "Đang tạo file cấu hình 3proxy..."
    rm -f /usr/local/etc/3proxy/3proxy.cfg
    gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg
    echo "File cấu hình 3proxy đã được tạo."

    # Cập nhật /etc/rc.local để tự động khởi động proxy
    echo "Cập nhật /etc/rc.local để tự động khởi động proxy..."
    if ! grep -q "${WORKDIR}/boot_iptables.sh" /etc/rc.local; then
        cat <<EOF >> /etc/rc.local
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 10048
service 3proxy start
EOF
        echo "/etc/rc.local đã được cập nhật."
    else
        echo "Các lệnh đã tồn tại trong /etc/rc.local. Không cần cập nhật."
    fi

    # Áp dụng cấu hình ngay lập tức
    echo "Đang áp dụng cấu hình..."
    bash /etc/rc.local

    # Tạo file proxy.txt cho người dùng
    echo "Đang tạo file proxy cho người dùng..."
    gen_proxy_file_for_user
    echo "File proxy đã được tạo tại ${WORKDIR}/proxy.txt"

    echo "Quá trình hoàn tất. Bạn có thể xem file proxy.txt để biết thông tin proxy."
}

# Hàm cài đặt proxy
setup_proxy() {
    echo "Đang cập nhật VPS..."
    yum update -y & spinner $!
    echo "Cập nhật hệ thống hoàn tất."

    echo "Đang cài đặt các gói cần thiết..."
    yum install -y gcc net-tools bsdtar zip curl wget nano make gcc-c++ glibc glibc-devel >/dev/null & spinner $!
    echo "Cài đặt các gói cần thiết hoàn tất."

    echo "Đang cài đặt 3proxy..."
    install_3proxy

    create_new_config
}

# Hàm làm mới proxy
refresh_proxy() {
    echo "Đang làm mới proxy..."
    WORKDIR="/home/proxy-installer"
    WORKDATA="${WORKDIR}/data.txt"

    stop_proxy

    # Xóa các địa chỉ IPv6 đã gán
    if [[ -f "$WORKDATA" ]]; then
        awk -F "/" '{print $5}' "$WORKDATA" | while read -r ip6; do
            ifconfig eth0 inet6 del "${ip6}/64" 2>/dev/null || true
        done
    fi

    # Xóa dữ liệu và cấu hình cũ
    rm -rf "$WORKDIR"
    rm -f /usr/local/etc/3proxy/3proxy.cfg

    # Thiết lập cấu hình proxy mới và khởi động lại proxy
    create_new_config
}

# Hàm xem danh sách proxy
view_proxy_list() {
    if [[ -f proxy.txt ]]; then
        echo "Danh sách proxy:"
        cat proxy.txt
    else
        echo "Không tìm thấy file proxy.txt. Vui lòng tạo proxy trước."
    fi
}

# Hàm dừng dịch vụ 3proxy
stop_proxy() {
    echo "Đang tắt tất cả dịch vụ liên quan đến 3proxy..."

    # Dừng dịch vụ thông qua systemctl nếu có
    if systemctl is-active --quiet 3proxy; then
        systemctl stop 3proxy && echo "Dịch vụ 3proxy đã dừng thông qua systemctl." || echo "Không thể dừng dịch vụ 3proxy thông qua systemctl."
    fi

    # Dừng dịch vụ thông qua service nếu có
    if service --status-all 2>/dev/null | grep -q "3proxy"; then
        service 3proxy stop && echo "Dịch vụ 3proxy đã dừng thông qua lệnh service." || echo "Không thể dừng dịch vụ 3proxy thông qua lệnh service."
    fi

    # Kiểm tra và kết thúc tiến trình 3proxy đang chạy
    if pgrep 3proxy >/dev/null; then
        echo "Đang kết thúc các tiến trình 3proxy..."
        pkill -9 3proxy && echo "Tất cả tiến trình 3proxy đã dừng." || echo "Không thể kết thúc một số tiến trình 3proxy."
    else
        echo "Không tìm thấy tiến trình 3proxy đang chạy."
    fi

    echo "Đã hoàn tất việc dừng tất cả dịch vụ liên quan đến 3proxy."
}

# Hàm khởi động dịch vụ 3proxy
start_proxy() {
    echo "Đang khởi động proxy..."

    # Khởi động dịch vụ 3proxy bằng systemctl nếu có
    if systemctl list-units --type=service | grep -q "3proxy"; then
        systemctl start 3proxy && echo "Dịch vụ 3proxy đã được khởi động qua systemctl." || echo "Không thể khởi động dịch vụ 3proxy qua systemctl."
    else
        echo "Không tìm thấy dịch vụ 3proxy trong systemctl. Đang thử với service..."
    fi

    # Khởi động dịch vụ 3proxy bằng service nếu có
    if service --status-all 2>/dev/null | grep -q "3proxy"; then
        service 3proxy start && echo "Dịch vụ 3proxy đã được khởi động qua lệnh service." || echo "Không thể khởi động dịch vụ 3proxy qua lệnh service."
    else
        echo "Không tìm thấy dịch vụ 3proxy trong lệnh service. Đang kiểm tra tiến trình 3proxy..."
    fi

    # Kiểm tra tiến trình 3proxy có đang chạy hay không
    if pgrep 3proxy >/dev/null; then
        echo "3proxy đang chạy thành công."
    else
        echo "Không tìm thấy tiến trình 3proxy. Vui lòng kiểm tra cấu hình."
        exit 1
    fi

    echo "Quá trình khởi động proxy hoàn tất."
}

# Hàm menu cho người dùng tương tác
menu() {
    while true; do
        echo ""
        echo "======== MENU ========="
        echo "1. Xem danh sách proxy đã tạo"
        echo "2. Làm mới tất cả proxy"
        echo "3. Tắt proxy"
        echo "4. Khởi động proxy"
        echo "0. Thoát"
        echo "======================="
        echo -n "Chọn một tùy chọn: "
        read -r choice
        case "$choice" in
            1) view_proxy_list ;;
            2) refresh_proxy ;;
            3) stop_proxy ;;
            4) start_proxy ;;
            0) echo "Thoát menu."; break ;;
            *) echo "Lựa chọn không hợp lệ, vui lòng thử lại." ;;
        esac
        echo ""
        echo "Nhập 'menu' để trở về menu chính hoặc '0' để thoát."
        read -r next_action
        if [[ "$next_action" == "0" ]]; then
            break
        elif [[ "$next_action" == "menu" ]]; then
            continue
        else
            echo "Nhập không hợp lệ. Trở về menu chính."
        fi
    done
}

# Hàm chính của script
main() {
    if [[ "${1:-}" == "menu" || "${1:-}" == "star" ]]; then
        menu
    else
        setup_proxy

        # Định nghĩa đường dẫn script
        SCRIPT_SRC="/root/caidat.sh"
        SCRIPT_DEST="/usr/local/bin/caidat.sh"

        # Kiểm tra sự tồn tại của script nguồn
        if [[ ! -f "$SCRIPT_SRC" ]]; then
            echo "File 'caidat.sh' không tồn tại trong thư mục cài đặt."
            exit 1
        fi

        # Sao chép script đến vị trí cố định và thiết lập quyền thực thi
        install -m 755 "$SCRIPT_SRC" "$SCRIPT_DEST"

        # Thêm alias 'menu' vào ~/.bashrc nếu chưa tồn tại
        alias_line="alias menu='bash $SCRIPT_DEST menu'"
        if ! grep -qxF "$alias_line" "$HOME/.bashrc"; then
            echo "$alias_line" >> "$HOME/.bashrc"
            echo "Alias 'menu' đã được thêm vào ~/.bashrc. Vui lòng chạy 'source ~/.bashrc' hoặc mở terminal mới để sử dụng."
        fi

        menu
    fi
}

# Gọi hàm chính với tất cả các đối số truyền vào script
main "$@"
