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
    echo "当前系统非 Debian/Ubuntu 系列，脚本不适用。"
    exit 1
fi

INTERFACE="eth0"

#------------------[ 2. 检测 eth0 与主 IP ]------------------#
if ! ip link show "$INTERFACE" &>/dev/null; then
    echo "网卡 $INTERFACE 不存在，请先确认网卡名称或修改脚本的 INTERFACE 变量。"
    exit 1
fi

# 仅提取首个 IPv4 地址，不再限制必须是 192.168.51.x
primary_ip=$(ip -4 addr show "$INTERFACE" | grep -oP '(?<=inet\s)(\d{1,3}\.){3}\d{1,3}' | head -n1)
if [ -z "$primary_ip" ]; then
    echo "未在 $INTERFACE 上找到 IPv4 地址。"
    exit 1
fi

# 检查 IP 的最后一段是否为 0
last_octet=$(echo "$primary_ip" | awk -F '.' '{print $4}')
if [ "$last_octet" != "0" ]; then
    echo "检测到的主 IP ($primary_ip) 不以 0 结尾。"
    exit 1
fi

# 将 base 部分提取为前三段 + “.”
base="${primary_ip%.*}."

#------------------[ 初始自动备份 ]------------------#
ip_count=$(ip -4 addr show "$INTERFACE" | grep -c 'inet ')
if [ "$ip_count" -eq 1 ]; then
    if [ ! -f /etc/network/interfaces.HKBN ]; then
        echo "自动创建备份..."
        cp /etc/network/interfaces /etc/network/interfaces.HKBN
    else
        echo "不再重复备份。"
    fi
else
    echo "不再重复备份。"
fi

#------------------[ 3. 让用户选择 ]------------------#
echo
echo "检测到 $INTERFACE 的主 IP: $primary_ip"
echo "可选附加 IP："
echo "  0 = HKBN"
echo "  1 = Telus"
echo "  2 = Hinet"
echo "  3 = HKT"
echo "  4 = Sony"

read -rp "请选择 (0/1/2/3/4): " choice

#------------------[ 4. 若选 0, 从 HKBN 备份还原并退出 ]------------------#
if [[ "$choice" = "0" ]]; then
    if [ ! -f /etc/network/interfaces.HKBN ]; then
        echo "未发现 /etc/network/interfaces.HKBN，无法恢复 HKBN 配置！"
        exit 1
    fi
    echo "恢复HKBN"
    cp /etc/network/interfaces.HKBN /etc/network/interfaces

    echo "执行 ifdown && ifup ..."
    ifdown "$INTERFACE" || true
    ifup "$INTERFACE"

    echo "出口已变更。当前 IP："
    ip addr show dev "$INTERFACE"
    exit 0
fi

#------------------[ 5. 若不是 0，也不是 1~4，则退出 ]------------------#
if [[ ! "$choice" =~ ^[1-4]$ ]]; then
    echo "无效选择，脚本退出。"
    exit 1
fi

#------------------[ 6. 继续执行原脚本逻辑：卸载 netplan 等... ]------------------#
additional_ip="${base}${choice}"
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get purge -y netplan.io systemd-networkd network-manager ifupdown || true
apt-get autoremove -y

# 重新安装 ifupdown
DEBIAN_FRONTEND=noninteractive apt-get install -y ifupdown

# 若存在 /etc/netplan 目录，则备份后移除
if [ -d /etc/netplan ]; then
    mv /etc/netplan "/etc/netplan.bak.$(date +%s)" || true
fi

#------------------[ 7. 备份并写入 /etc/network/interfaces ]------------------#
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
    dns-nameservers 8.8.8.8
    up ip addr add $additional_ip/24 dev $INTERFACE
    up ip route flush default
    # 这里的网关仍固定为 192.168.51.1，如有需要可自行改成别的网关
    up ip route add default via 192.168.51.1 dev $INTERFACE src $additional_ip metric 100
    down ip addr del $additional_ip/24 dev $INTERFACE || true
EOF

echo "已写入新的 /etc/network/interfaces"

#------------------[ 8. ifdown & ifup ]------------------#

sleep 2
ifdown "$INTERFACE" || true
ifup "$INTERFACE"

#------------------[ 9. 显示结果 ]------------------#
echo "出口已变更。当前 IP："
ip addr show dev "$INTERFACE"
