#!/usr/bin/env bash
#
# 适用系统：Debian/Ubuntu 系列 (apt)

set -e

#------------------[ 1. 前置检查 ]------------------#
if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 权限执行此脚本。"
    exit 1
fi

if ! command -v apt &>/dev/null; then
    echo "当前系统非 Debian/Ubuntu 系列，脚本不适用。"
    exit 1
fi

INTERFACE="eth0"

#------------------[ 2. 检测网卡及 IP (仅检查最后一段是否以0结尾) ]------------------#
if ! ip link show "$INTERFACE" &>/dev/null; then
    echo "网卡 $INTERFACE 不存在，请先确认网卡名称或修改脚本里的 INTERFACE 变量。"
    exit 1
fi

# 用正则匹配第四段末尾 '0' 的 IPv4。例如 192.168.51.10, 10.0.5.40 等
primary_ip=$(ip -4 addr show "$INTERFACE" \
    | grep -oP '(?<=inet\s)(\d{1,3}\.){3}\d+0(?=/)' \
    | head -n1)

if [ -z "$primary_ip" ]; then
    echo "未在 $INTERFACE 上找到末段以 '0' 结尾的 IPv4 地址(如 192.168.51.10, 10.0.5.20...)。"
    exit 1
fi
echo "检测到的主 IP：$primary_ip"

# 去掉末段的 '0'，如 192.168.51.10 => 192.168.51.1
base="${primary_ip%0}"

#------------------[ 3. 彻底卸载 cloud-init ]------------------#
echo "检测并卸载 cloud-init 中..."
if dpkg -l | grep -qw cloud-init; then
    echo "检测到 cloud-init，开始卸载..."
    # 防止 cloud-init 服务仍在运行
    systemctl disable cloud-init.service --now || true
    systemctl stop cloud-init.service || true

    # 卸载
    apt-get purge -y cloud-init

    # 清理残留目录、文件
    rm -rf /etc/cloud
    rm -rf /var/lib/cloud
    rm -f /var/log/cloud-init.log
    rm -f /var/log/cloud-init-output.log

    echo "cloud-init 已彻底卸载并清理。"
else
    echo "系统中未检测到 cloud-init，跳过卸载。"
fi

#------------------[ 4. 跳过 Release 文件时间戳验证 ]------------------#
cat <<EOF >/etc/apt/apt.conf.d/99IgnoreTimestamp
Acquire::Check-Valid-Until "false";
Acquire::Check-Date "false";
EOF

#------------------[ 5. 初始自动备份 ]------------------#
ip_count=$(ip -4 addr show "$INTERFACE" | grep -c 'inet ')
if [ "$ip_count" -eq 1 ]; then
    if [ ! -f /etc/network/interfaces.HKBN ]; then
        echo "自动创建备份: /etc/network/interfaces.HKBN"
        cp /etc/network/interfaces /etc/network/interfaces.HKBN
    else
        echo "不再重复备份。"
    fi
else
    echo "不再重复备份。"
fi

#------------------[ 6. 让用户选择 ]------------------#
echo
echo "检测到 $INTERFACE 的主 IP: $primary_ip"
echo "可选附加出口："
echo "  0 = HKBN"
echo "  1 = Telus"
echo "  2 = Hinet"
echo "  3 = HKT"
echo "  4 = Sony"
echo "  5 = CMHK（未启用）"
echo "  6 = Starlink（未启用）"

read -rp "请选择 (0/1/2/3/4/5/6): " choice

#------------------[ 7. 若选 0, 从 HKBN 备份还原并退出 ]------------------#
if [[ "$choice" = "0" ]]; then
    if [ ! -f /etc/network/interfaces.HKBN ]; then
        echo "未发现 /etc/network/interfaces.HKBN，无法恢复 HKBN 配置！"
        exit 1
    fi
    echo "恢复HKBN配置..."
    cp /etc/network/interfaces.HKBN /etc/network/interfaces

    echo "执行 ifdown && ifup ..."
    ifdown "$INTERFACE" || true
    ifup "$INTERFACE"

    echo "出口已变更。当前 IP："
    ip addr show dev "$INTERFACE"
    exit 0
fi

#------------------[ 8. 若不是 0，也不是 1~6，则退出 ]------------------#
if [[ ! "$choice" =~ ^[1-6]$ ]]; then
    echo "无效选择，脚本退出。"
    exit 1
fi

# 将选项合并到 base 后得到附加 IP，如 base=192.168.51.1 + choice=5 => 192.168.51.15
additional_ip="${base}${choice}"

#------------------[ 9. 更新并卸载 netplan 等网络组件 ]------------------#
echo "开始执行 apt-get update "
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get purge -y netplan.io systemd-networkd network-manager ifupdown || true
apt-get autoremove -y

# 重新安装 ifupdown
DEBIAN_FRONTEND=noninteractive apt-get install -y ifupdown

# 若存在 /etc/netplan 目录，则备份后移除
if [ -d /etc/netplan ]; then
    mv /etc/netplan "/etc/netplan.bak.$(date +%s)" || true
fi

#------------------[ 10. 写入新的 /etc/network/interfaces ]------------------#
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

#------------------[ 11. ifdown & ifup ]------------------#
sleep 2
ifdown "$INTERFACE" || true
ifup "$INTERFACE"

#------------------[ 12. 显示结果 ]------------------#
echo "出口已变更。当前 IP："
ip addr show dev "$INTERFACE"
