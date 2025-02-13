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
    ip -4 addr show "$interface" | grep -oP '(?<=inet\s)(\d{1,3}\.){3}\d+0(?=/)' | head -n1
}

get_default_gateway() {
    ip route | grep default | awk '{print $3}'
}

validate_gateway() {
    local gateway="$1"
    [[ "$gateway" =~ ^192\.168\.(5[1-9]|[1-4][0-9])\.1$ ]]
}

validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

update_network_interface() {
    local additional_ip="$1"
    local gateway="$2"

    cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto $INTERFACE
iface $INTERFACE inet static
    address $primary_ip
    netmask 255.255.255.0
    dns-nameservers 8.8.8.8

    up ip addr add $additional_ip/24 dev $INTERFACE >/dev/null 2>&1
    up ip route flush default >/dev/null 2>&1
    up ip route add default via $gateway dev $INTERFACE src $additional_ip metric 100 >/dev/null 2>&1

    down ip addr del $additional_ip/24 dev $INTERFACE || true
EOF

echo "出口配置已更新，网络将暂时中断" 

}

reconfigure_network() {
    ifdown "$INTERFACE" > /dev/null 2>&1 || true  # 隐藏 ifdown 输出
    ifup "$INTERFACE" > /dev/null 2>&1  # 隐藏 ifup 输出
}

#------------------[ 主逻辑 ]------------------#
check_root
check_debian_system

INTERFACE="eth0"
check_interface "$INTERFACE"

primary_ip=$(get_primary_ip "$INTERFACE")
if [ -z "$primary_ip" ]; then
    echo "错误：不是HKBN All In One。"
    exit 1
fi
echo "检测到的主 IP：$primary_ip"

gateway=$(get_default_gateway)
echo "检测到的默认网关：$gateway"

if ! validate_gateway "$gateway"; then
    echo "错误：不是HKBN All In One。"
    exit 1
fi

base="${primary_ip%0}"

#------------------[ 让用户选择出口 ]------------------#
echo "可选附加出口："
echo "  0 = HKBN"
echo "  1 = Telus"
echo "  2 = Hinet"
echo "  3 = HKT"
echo "  4 = Sony"
echo "  5 = CMHK"
echo "  6 = Starlink（未启用）"
echo "  7 = SK Broadband"

read -rp "请选择 (0/1/2/3/4/5/6/7): " choice

if [[ "$choice" = "0" ]]; then
    echo "source /etc/network/interfaces.d/*" > /etc/network/interfaces
    reconfigure_network "$INTERFACE"
    echo "出口已变更。当前出口为 HKBN。"
    exit 0
fi

if [[ ! "$choice" =~ ^[1-7]$ ]]; then
    echo "无效选择，脚本退出。"
    exit 1
fi

additional_ip="${base}${choice}"

if ! validate_ip "$additional_ip"; then
    echo "错误：计算出的 IP 地址 $additional_ip 无效。"
    exit 1
fi

#------------------[ 更新接口配置 ]------------------#
update_network_interface "$additional_ip" "$gateway"

#------------------[ 重新启动网络服务 ]------------------#
reconfigure_network "$INTERFACE"

#------------------[ 展示当前出口 ]------------------#
declare -A export_map
export_map=(
    [0]="HKBN"
    [1]="Telus"
    [2]="Hinet"
    [3]="HKT"
    [4]="Sony"
    [5]="CMHK"
    [6]="Starlink（未启用）"
    [7]="SK Broadband"
)

echo "当前出口为 ${export_map[$choice]}"
