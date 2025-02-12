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
# 查看系统是否有 $INTERFACE 网卡
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

#------------------[ 2.1 如只检测到 1 个 IP 且没 HKBN 备份，就自动备份 ]------------------#
# 检测 $INTERFACE 上的 IPv4 个数
ip_count=$(ip -4 addr show "$INTERFACE" | grep -c 'inet ')
if [ "$ip_count" -eq 1 ]; then
    # 只有 1 个 IP，且还没有 HKBN 备份文件时，就进行一次备份
    if [ ! -f /etc/network/interfaces.HKBN ]; then
        echo "当前网卡 $INTERFACE 上仅有 1 个 IP，且未发现 /etc/network/interfaces.HKBN，自动创建 HKBN 备份..."
        cp /etc/network/interfaces /etc/network/interfaces.HKBN
    else
        echo "当前仅有 1 个 IP，但已有 HKBN 备份文件 /etc/network/interfaces.HKBN，不再重复备份。"
    fi
else
    echo "检测到多个 IP 或已绑定附加 IP，不进行 HKBN 备份（或已存在备份）。"
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
    echo "已选择 0=HKBN，准备恢复 /etc/network/interfaces.HKBN ..."
    cp /etc/network/interfaces.HKBN /etc/network/interfaces

    echo "执行 ifdown && ifup ..."
    ifdown "$INTERFACE" || true
    ifup "$INTERFACE"

    echo "恢复完成。当前 IP："
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
    up ip route add default via 192.168.51.1 dev $INTERFACE src $additional_ip metric 100
    down ip addr del $additional_ip/24 dev $INTERFACE || true
EOF

echo "已写入新的 /etc/network/interfaces"

#------------------[ 8. ifdown & ifup ]------------------#

sleep 2

ifdown "$INTERFACE" || true
ifup "$INTERFACE"

#------------------[ 9. 显示结果 ]------------------#
echo "网络已应用。当前 IP："
ip addr show dev "$INTERFACE"

