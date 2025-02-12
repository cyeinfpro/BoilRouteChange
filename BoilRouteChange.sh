#!/usr/bin/env bash
#
# 适用系统：Debian/Ubuntu 系列 (apt)

set -e

#------------------[ 1. 前置检查与变量 ]------------------#
if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 权限执行此脚本。"
    exit 1
fi

if ! command -v apt &>/dev/null; then
    echo "当前系统非 Debian/Ubuntu 系列 (无 apt 命令)，脚本不适用。"
    exit 1
fi

INTERFACE="eth0"

#------------------[ 2. 检测 eth0 与主 IP ]------------------#
# 查看系统是否有 eth0 网卡
if ! ip link show "$INTERFACE" &>/dev/null; then
    echo "网卡 $INTERFACE 不存在，请先确认网卡名称或修改脚本的 INTERFACE 变量。"
    exit 1
fi

# 检测主 IP: 192.168.51.x0
primary_ip=$(ip -4 addr show "$INTERFACE" | grep -oP '(?<=inet\s)192\.168\.51\.\d+' | head -n1)
if [ -z "$primary_ip" ]; then
    echo "未在 $INTERFACE 上找到 192.168.51.x 格式的 IP。请先配置 192.168.51.x0 后再执行。"
    exit 1
fi
if [[ "$primary_ip" != *0 ]]; then
    echo "检测到的主 IP ($primary_ip) 不以 0 结尾 (示例要求：192.168.51.x0)。"
    exit 1
fi

base="${primary_ip%0}"

echo "检测到 $INTERFACE 的主 IP: $primary_ip"
echo "可选附加 IP："
echo "  1 = Telus"
echo "  2 = Hinet"
echo "  3 = HKT"
echo "  4 = Sony"

read -rp "请选择 (1/2/3/4): " choice
if [[ ! "$choice" =~ ^[1-4]$ ]]; then
    echo "无效选择，脚本退出。"
    exit 1
fi

additional_ip="${base}${choice}"
echo "将设置附加 IP: $additional_ip"

#------------------[ 3. 卸载其他网络管理工具 ]------------------#
echo "开始卸载 netplan.io、systemd-networkd、network-manager、旧版 ifupdown..."
# 无任何交互确认，直接卸载
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get purge -y netplan.io systemd-networkd network-manager ifupdown || true
apt-get autoremove -y

# 重新安装 ifupdown
DEBIAN_FRONTEND=noninteractive apt-get install -y ifupdown

# 若存在 /etc/netplan 目录，则备份后移除
if [ -d /etc/netplan ]; then
    mv /etc/netplan "/etc/netplan.bak.$(date +%s)" || true
fi

echo "其他网络管理工具已卸载，ifupdown 已安装。"

#------------------[ 4. 写入 /etc/network/interfaces ]------------------#
echo "生成 /etc/network/interfaces 配置..."

backup_file="/etc/network/interfaces.bak.$(date +%s)"
if [ -f /etc/network/interfaces ]; then
    cp /etc/network/interfaces "$backup_file"
    echo "已备份原 /etc/network/interfaces => $backup_file"
fi

cat > /etc/network/interfaces <<EOF

auto lo
iface lo inet loopback

auto $INTERFACE
iface $INTERFACE inet static
    address $primary_ip
    netmask 255.255.255.0
    # 不写 gateway
    dns-nameservers 8.8.8.8

    # 在 up 阶段添加附加 IP 并设置默认路由
    up ip addr add $additional_ip/24 dev $INTERFACE
    up ip route flush default
    up ip route add default via 192.168.51.1 dev $INTERFACE src $additional_ip metric 100

    # 在 down 阶段移除附加 IP
    down ip addr del $additional_ip/24 dev $INTERFACE || true
EOF

echo "已写入新的 /etc/network/interfaces"

#------------------[ 5. ifdown & ifup ]------------------#
echo "即将执行: ifdown $INTERFACE && ifup $INTERFACE"
echo "如果本机只有 eth0 提供 SSH，连接将会断开。"

ifdown "$INTERFACE" || true
ifup "$INTERFACE"

#------------------[ 6. 显示结果 ]------------------#
echo "网络已应用。当前 IP："
ip addr show dev "$INTERFACE"
