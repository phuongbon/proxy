#!/bin/sh
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

install_3proxy() {
    echo "Bắt đầu cài đặt 3proxy..."
    URL="https://raw.githubusercontent.com/quayvlog/quayvlog/main/3proxy-3proxy-0.8.6.tar.gz"
    wget -qO- $URL | bsdtar -xvf- || { echo "Tải về hoặc giải nén 3proxy thất bại!"; exit 1; }
    cd 3proxy-3proxy-0.8.6 || { echo "Không tìm thấy thư mục 3proxy sau giải nén!"; exit 1; }
    make -f Makefile.Linux || { echo "Biên dịch 3proxy thất bại!"; exit 1; }
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/ || { echo "Sao chép 3proxy thất bại!"; exit 1; }
    cp ./scripts/rc.d/proxy.sh /etc/init.d/3proxy || { echo "Sao chép script khởi động thất bại!"; exit 1; }
    chmod +x /etc/init.d/3proxy
    chkconfig 3proxy on
    cd "$WORKDIR" || { echo "Không thể chuyển về thư mục làm việc chính!"; exit 1; }
    echo "Cài đặt 3proxy hoàn tất."
}

gen_3proxy() {
    cat <<EOF
daemon
maxconn 1000
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
    cat >proxy.txt <<EOF
$(awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA})
EOF
}

gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "phuong$(random)/phuongphuong$(random)/$IP4/$port/$(gen64 $IP6)"
    done
}

gen_iptables() {
    cat <<EOF
$(awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 "  -m state --state NEW -j ACCEPT"}' ${WORKDATA}) 
EOF
}

gen_ifconfig() {
    cat <<EOF
$(awk -F "/" '{print "ifconfig eth0 inet6 add " $5 "/64"}' ${WORKDATA})
EOF
}

echo "Bắt đầu cài đặt các gói cần thiết..."
yum -y install gcc net-tools bsdtar zip curl wget nano make gcc-c++ glibc glibc-devel >/dev/null
echo "Cài đặt các gói cần thiết hoàn tất."

echo "installing 3proxy"
install_3proxy

echo "Tạo thư mục làm việc tại /home/proxy-installer"
WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p "$WORKDIR" && cd "$WORKDIR" || { echo "Không thể tạo hoặc chuyển đến thư mục làm việc!"; exit 1; }

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

echo "Địa chỉ IP4 nội bộ: ${IP4}"
echo "Địa chỉ subnet IP6: ${IP6}"

echo "Bạn muốn tạo bao nhiêu proxy? Ví dụ: 500"
read COUNT

FIRST_PORT=10000
LAST_PORT=$(($FIRST_PORT + $COUNT))

echo "Đang tạo dữ liệu proxy..."
gen_data >"$WORKDIR/data.txt"
echo "Tạo dữ liệu proxy hoàn tất."

echo "Tạo script iptables..."
gen_iptables >"$WORKDIR/boot_iptables.sh"
echo "Tạo script iptables hoàn tất."

echo "Tạo script cấu hình mạng IPv6..."
gen_ifconfig >"$WORKDIR/boot_ifconfig.sh"
echo "Tạo script cấu hình IPv6 hoàn tất."

chmod +x ${WORKDIR}/boot_*.sh /etc/rc.local

echo "Tạo file cấu hình 3proxy..."
gen_3proxy >/usr/local/etc/3proxy/3proxy.cfg
echo "Tạo file cấu hình 3proxy hoàn tất."

echo "Cập nhật /etc/rc.local để tự động khởi động proxy..."
cat >>/etc/rc.local <<EOF
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 10048
service 3proxy start
EOF

echo "Khởi chạy /etc/rc.local để áp dụng cấu hình ngay..."
bash /etc/rc.local

echo "Tạo file proxy cho người dùng..."
gen_proxy_file_for_user
echo "Tạo file proxy hoàn tất tại proxy.txt"

echo "Quá trình hoàn tất. Bạn có thể xem file proxy.txt để biết thông tin proxy."
