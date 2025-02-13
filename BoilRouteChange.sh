#!/usr/bin/env bash
#
# 适用系统：Debian/Ubuntu 系列 (apt)

set -e

#------------------[ 1. 前置检查 ]------------------#
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请以 root 权限执行此脚本。"
        exit 1
    fi
}

check_debian_system() {
    if ! command -v apt &>/dev/null; then
        echo "当前系统非 Debian/Ubuntu 系列，脚本不适用。"
        exit 1
    fi
}

check_interface() {
    local interface="$1"
    if ! ip link show "$interface" &>/dev/null; then
        echo "网卡 $interface 不存在，请先确认网卡名称或修改脚本里的 INTERFACE 变量。"
        exit 1
    fi
}

get_primary_ip() {
    local interface="$1"
    # 用正则匹配第四段末尾 '0' 的 IPv4
    ip -4 addr show "$interface" | grep -oP '(?<=inet\s)(\d{1,3}\.){3}\d+0(?=/)' | head -n1
}

get_default_gateway() {
    # 获取当前的默认网关
    ip route | grep default | awk '{print $3}'
}

validate_gateway() {
    local gateway="$1"
    # 检查网关是否在 192.168.51.1 到 192.168.59.1 范围内
    if [[ "$gateway" =~ ^192\.168\.(5[1-9]|[1-4][0-9])\.1$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_ip() {
    local ip="$1"
    # 检查 IP 格式是否有效
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

backup_network_interfaces() {
    if [ ! -f /etc/network/interfaces.HKBN ]; then
        echo "自动创建备份: /etc/network/interfaces.HKBN"
        cp /etc/network/interfaces /etc/network/interfaces.HKBN
    else
        return 0
    fi
}

download_hkbn_backup() {
    echo "正在尝试从 GitHub 下载..."
    curl -fsSL -o /etc/network/interfaces.HKBN "https://raw.githubusercontent.com/cyeinfpro/BoilRouteChange/refs/heads/main/interfaces.HKBN"
    if [ $? -eq 0 ]; then
        echo "成功下载 /etc/network/interfaces.HKBN 文件。"
    else
        echo "下载失败，请手动下载文件并放置在 /etc/network 目录下，URL: https://raw.githubusercontent.com/cyeinfpro/BoilRouteChange/refs/heads/main/interfaces.HKBN"
        exit 1
    fi
}

cleanup_old_backups() {
    local backup_dir="/etc/network"
    local backups
    backups=$(ls -t "${backup_dir}/interfaces.bak."* 2>/dev/null)  # 按时间排序备份文件

    local count
    count=$(echo "$backups" | wc -l)
    if [ "$count" -gt 3 ]; then
        local old_backups
        old_backups=$(echo "$backups" | tail -n +4)  # 获取超过三个的备份文件
        echo "$old_backups" | while read -r backup; do
            rm -f "$backup"
        done
    fi
}

update_network_interface() {
    local additional_ip="$1"
    local gateway="$2"
    backup_file="/etc/network/interfaces.bak.$(date +%s)"
    
    # 在更新前进行备份
    if [ -f /etc/network/interfaces ]; then
        cp /etc/network/interfaces "$backup_file"
    fi
    # 清理过期的备份文件
    cleanup_old_backups

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
    up ip route add default via $gateway dev $INTERFACE src $additional_ip metric 100

    down ip addr del $additional_ip/24 dev $INTERFACE || true
EOF

    echo "出口配置已更新"
}

reconfigure_network() {
    local interface="$1"
    ifdown "$interface" || true
    ifup "$interface"
}

#------------------[ 主逻辑 ]------------------#
check_root
check_debian_system

INTERFACE="eth0"
check_interface "$INTERFACE"

primary_ip=$(get_primary_ip "$INTERFACE")
if [ -z "$primary_ip" ]; then
    echo "未在 $INTERFACE 上找到末段以 '0' 结尾的 IPv4 地址(如 192.168.51.10, 10.0.5.20...)。"
    exit 1
fi
echo "检测到的主 IP：$primary_ip"

gateway=$(get_default_gateway)
echo "检测到的默认网关：$gateway"

# 检查默认网关是否在 192.168.51.1 到 192.168.59.1 范围内
if ! validate_gateway "$gateway"; then
    echo "错误：默认网关 $gateway 不在有效范围内。"
    exit 1
fi

base="${primary_ip%0}"

#------------------[ 初始自动备份 ]------------------#
backup_network_interfaces

#------------------[ 让用户选择出口 ]------------------#
echo "可选附加出口："
echo "  0 = HKBN"
echo "  1 = Telus"
echo "  2 = Hinet"
echo "  3 = HKT"
echo "  4 = Sony"
echo "  5 = CMHK"
echo "  6 = Starlink（未启用）"

read -rp "请选择 (0/1/2/3/4/5/6): " choice

if [[ "$choice" = "0" ]]; then
    if [ ! -f /etc/network/interfaces.HKBN ]; then
        download_hkbn_backup
    fi
    echo "恢复HKBN配置..."
    cp /etc/network/interfaces.HKBN /etc/network/interfaces
    reconfigure_network "$INTERFACE"
    echo "出口已变更。当前出口为 HKBN。"
    exit 0
fi

if [[ ! "$choice" =~ ^[1-6]$ ]]; then
    echo "无效选择，脚本退出。"
    exit 1
fi

# 计算附加 IP
additional_ip="${base}${choice}"

# 验证 IP 格式是否有效
if ! validate_ip "$additional_ip"; then
    echo "错误：计算出的 IP 地址 $additional_ip 无效。"
    exit 1
fi

#------------------[ 更新接口配置 ]------------------#
update_network_interface "$additional_ip" "$gateway"

#------------------[ 重新启动网络服务 ]------------------#
reconfigure_network "$INTERFACE"

#------------------[ 展示当前出口 ]------------------#
case "$choice" in
    0)
        echo "当前出口为 HKBN。"
        ;;
    1)
        echo "当前出口为 Telus。"
        ;;
    2)
        echo "当前出口为 Hinet。"
        ;;
    3)
        echo "当前出口为 HKT。"
        ;;
    4)
        echo "当前出口为 Sony。"
        ;;
    5)
        echo "当前出口为 CMHK。"
        ;;
    6)
        echo "当前出口为 Starlink（未启用）。"
        ;;
    *)
        echo "未知出口配置。"
        ;;
esac
