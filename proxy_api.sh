#!/bin/sh
# Đường dẫn cho các lệnh thực thi
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Cập nhật kho lưu trữ CentOS và tắt xác thực SSL
echo "Đang cập nhật kho lưu trữ CentOS..."
sed -i 's/mirror.centos.org/vault.centos.org/g' /etc/yum.repos.d/*.repo
sed -i 's/^#.*baseurl=http/baseurl=http/g' /etc/yum.repos.d/*.repo
sed -i 's/^mirrorlist=http/#mirrorlist=http/g' /etc/yum.repos.d/*.repo
echo "sslverify=false" >> /etc/yum.conf
echo "Đã cập nhật kho lưu trữ CentOS và tắt xác thực SSL"

# Tạo địa chỉ IPv6 ngẫu nhiên trong subnet
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# Cài đặt 3proxy
install_3proxy() {
    echo "Đang cài đặt 3proxy..."
    URL="https://github.com/z3APA3A/3proxy/archive/3proxy-0.8.6.tar.gz"
    wget -qO- $URL | bsdtar -xvf-
    cd 3proxy-3proxy-0.8.6
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cd $WORKDIR
    echo "Đã cài đặt 3proxy thành công"
}

# Tạo cấu hình 3proxy không yêu cầu xác thực
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
stacksize 6291456 
flush
auth none
allow *
proxy -6 -n -a -p$PROXY_PORT -i$IP4 -e$CURRENT_IP6
flush
EOF
}

# Tạo lệnh ifconfig cho địa chỉ IPv6 hiện tại
gen_ifconfig() {
    echo "ifconfig eth0 inet6 add $CURRENT_IP6/64"
}

# Cài đặt các gói cần thiết
echo "Đang cài đặt các ứng dụng cần thiết..."
yum -y install wget gcc net-tools bsdtar zip python3 >/dev/null

# Tạo file rc.local nếu chưa tồn tại
cat << EOF > /etc/rc.d/rc.local
#!/bin/bash
touch /var/lock/subsys/local
EOF
chmod +x /etc/rc.local

# Xóa bộ đệm đầu vào
stty sane
echo "" > /dev/tty

# Nhập thông tin cấu hình IPv6
echo "Nhập thông tin IPv6:"

# Nhập IPV6ADDR
while :; do
    read -p "Nhập IPV6ADDR (ví dụ: 2001:19f0:5401:2c7::2): " IPV6ADDR
    if [ -n "$IPV6ADDR" ]; then
        echo "IPV6ADDR đã nhập: $IPV6ADDR"
        break
    else
        echo "Vui lòng nhập một IPV6ADDR hợp lệ!"
    fi
done

# Nhập IPV6_DEFAULTGW
while :; do
    read -p "Nhập IPV6_DEFAULTGW (ví dụ: 2001:19f0:5401:2c7::1): " IPV6_DEFAULTGW
    if [ -n "$IPV6_DEFAULTGW" ]; then
        echo "IPV6_DEFAULTGW đã nhập: $IPV6_DEFAULTGW"
        break
    else
        echo "Vui lòng nhập một IPV6_DEFAULTGW hợp lệ!"
    fi
done

# Cấu hình IPv6
echo "Đang cấu hình IPv6..."
cat << EOF >> /etc/sysconfig/network-scripts/ifcfg-eth0
IPV6_FAILURE_FATAL=no
IPV6_ADDR_GEN_MODE=stable-privacy
IPV6ADDR=$IPV6ADDR
IPV6_DEFAULTGW=$IPV6_DEFAULTGW
EOF
echo "Đã ghi cấu hình IPv6 vào ifcfg-eth0"

# Khởi động lại mạng
echo "Đang khởi động lại mạng..."
service network restart
echo "Đã khởi động lại mạng, chờ 5 giây để ổn định..."
sleep 5

# Kiểm tra kết nối IPv6
echo "Đang kiểm tra kết nối IPv6..."
ping6 google.com.vn -c4
if [ $? -eq 0 ]; then
    echo "Kết nối IPv6 thành công!"
else
    echo "Kết nối IPv6 thất bại. Vui lòng kiểm tra cấu hình mạng."
    exit 1
fi

# Cài đặt 3proxy
install_3proxy

# Thiết lập thư mục làm việc
echo "Thư mục làm việc = /home/cloudfly"
WORKDIR="/home/cloudfly"
mkdir -p $WORKDIR && cd $_
echo "Đã tạo thư mục làm việc $WORKDIR"

# Lấy địa chỉ IP
IP4=$(curl -4 -s icanhazip.com)
IP6_PREFIX=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')
echo "IP nội bộ = ${IP4}. Tiền tố IPv6 bên ngoài = ${IP6_PREFIX}"

# Thiết lập cổng proxy
PROXY_PORT=21000
CURRENT_IP6=$(gen64 $IP6_PREFIX)
echo "IPv6 ban đầu cho proxy: $CURRENT_IP6"

# Tạo cấu hình ban đầu
gen_ifconfig > $WORKDIR/boot_ifconfig.sh
chmod +x $WORKDIR/boot_ifconfig.sh

# Áp dụng IPv6 ban đầu
bash $WORKDIR/boot_ifconfig.sh
echo "Đã áp dụng cấu hình IPv6 ban đầu"

# Tạo cấu hình 3proxy
gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg

# Thiết lập rc.local để khởi động 3proxy và API server
cat >> /etc/rc.local <<EOF
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 1000048
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
nohup python3 ${WORKDIR}/api_server.py &
EOF
chmod 0755 /etc/rc.local

# Khởi động 3proxy
bash /etc/rc.local
echo "Đã khởi động 3proxy"

# Tạo file API server
cat > $WORKDIR/api_server.py << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import subprocess
import json
import random
import os

# Cấu hình
WORKDIR = "/home/cloudfly"
PROXY_PORT = 21000
IP6_PREFIX = subprocess.check_output("curl -6 -s icanhazip.com | cut -f1-4 -d':'", shell=True).decode().strip()
IP4 = subprocess.check_output("curl -4 -s icanhazip.com", shell=True).decode().strip()

# File lưu trữ địa chỉ IPv6 hiện tại
CURRENT_IP6_FILE = f"{WORKDIR}/current_ip6.txt"

# Tạo địa chỉ IPv6 ngẫu nhiên
def gen_ip6(prefix):
    hex_chars = "0123456789abcdef"
    segments = [''.join(random.choice(hex_chars) for _ in range(4)) for _ in range(4)]
    return f"{prefix}:{':'.join(segments)}"

# Lấy địa chỉ IPv6 hiện tại từ file
def get_current_ip6():
    if os.path.exists(CURRENT_IP6_FILE):
        with open(CURRENT_IP6_FILE, "r") as f:
            return f.read().strip()
    return None

# Lưu địa chỉ IPv6 mới vào file
def save_current_ip6(ip6):
    with open(CURRENT_IP6_FILE, "w") as f:
        f.write(ip6)

# Cập nhật cấu hình 3proxy
def update_3proxy(ip6):
    with open("/usr/local/etc/3proxy/3proxy.cfg", "w") as f:
        f.write(f"""daemon
maxconn 2000
nserver 1.1.1.1
nserver 8.8.4.4
nserver 2001:4860:4860::8888
nserver 2001:4860:4860::8844
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6291456
flush
auth none
allow *
proxy -6 -n -a -p{PROXY_PORT} -i{IP4} -e{ip6}
flush
""")

# Cập nhật script ifconfig
def update_ifconfig(old_ip6, new_ip6):
    with open(f"{WORKDIR}/boot_ifconfig.sh", "w") as f:
        # Xóa địa chỉ IPv6 cũ nếu tồn tại
        if old_ip6:
            f.write(f"ip -6 addr del {old_ip6}/64 dev eth0\n")
        # Thêm địa chỉ IPv6 mới
        f.write(f"ip -6 addr add {new_ip6}/64 dev eth0\n")
    subprocess.run(["chmod", "+x", f"{WORKDIR}/boot_ifconfig.sh"])

# Khởi động lại 3proxy
def restart_3proxy():
    subprocess.run(["pkill", "3proxy"])
    subprocess.run(["bash", f"{WORKDIR}/boot_ifconfig.sh"])
    subprocess.run(["/usr/local/etc/3proxy/bin/3proxy", "/usr/local/etc/3proxy/3proxy.cfg"])

# Xử lý yêu cầu HTTP
class APIHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/rest":
            try:
                # Lấy địa chỉ IPv6 cũ
                old_ip6 = get_current_ip6()
                
                # Tạo địa chỉ IPv6 mới
                new_ip6 = gen_ip6(IP6_PREFIX)
                
                # Cập nhật cấu hình
                update_ifconfig(old_ip6, new_ip6)
                update_3proxy(new_ip6)
                
                # Lưu địa chỉ IPv6 mới
                save_current_ip6(new_ip6)
                
                # Khởi động lại proxy
                restart_3proxy()
                
                # Gửi phản hồi
                self.send_response(200)
                self.send_header("Content-type", "application/json")
                self.end_headers()
                response = {"status": "thành công", "new_ip6": new_ip6}
                self.wfile.write(json.dumps(response).encode())
            except Exception as e:
                self.send_response(500)
                self.send_header("Content-type", "application/json")
                self.end_headers()
                response = {"status": "lỗi", "message": str(e)}
                self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.end_headers()

# Khởi động server
PORT = 8080
with socketserver.TCPServer(("0.0.0.0", PORT), APIHandler) as httpd:
    print(f"Server API đang chạy trên cổng {PORT}")
    httpd.serve_forever()
EOF

# Cấp quyền thực thi cho API server
chmod +x $WORKDIR/api_server.py

# Khởi động API server ở chế độ nền
nohup python3 $WORKDIR/api_server.py &

echo "Thiết lập proxy hoàn tất!"
echo "Proxy đang chạy trên ${IP4}:${PROXY_PORT} với IPv6 ${CURRENT_IP6}"
echo "Server API đang chạy trên cổng 8080. Thay đổi IP bằng cách gọi: curl http://${IP4}:8080/rest"
