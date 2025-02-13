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

remove_cloud_init() {
    echo "检测并卸载 cloud-init 中..."
    if dpkg -l | grep -qw cloud-init; then
        echo "检测到 cloud-init，开始卸载..."
        systemctl disable cloud-init.service --now || true
        systemctl stop cloud-init.service || true
        apt-get purge -y cloud-init
        rm -rf /etc/cloud /var/lib/cloud /var/log/cloud-init.log /var/log/cloud-init-output.log
        echo "cloud-init 已彻底卸载并清理。"
    else
        echo "系统中未检测到 cloud-init，跳过卸载。"
    fi
}

backup_network_interfaces() {
    local ip_count
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
    backup_dir="/etc/network"
    backups=$(ls -t ${backup_dir}/interfaces.bak.* 2>/dev/null)  # 按时间排序备份文件

    # 保留最新的三个备份文件，删除多余的
    count=$(echo "$backups" | wc -l)
    if [ "$count" -gt 3 ]; then
        old_backups=$(echo "$backups" | tail -n +4)  # 获取超过三个的备份文件
        echo "$old_backups" | while read -r backup; do
            echo "删除过期备份文件：$backup"
            rm -f "$backup"
        done
    fi
}

update_network_interface() {
    local additional_ip="$1"
    echo "生成 /etc/network/interfaces 配置..."
    backup_file="/etc/network/interfaces.bak.$(date +%s)"
    
    # 在更新前进行备份
    if [ -f /etc/network/interfaces ]; then
        cp /etc/network/interfaces "$backup_file"
        echo "已备份原 /etc/network/interfaces => $backup_file"
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
    up ip route add default via 192.168.51.1 dev $INTERFACE src $additional_ip metric 100

    down ip addr del $additional_ip/24 dev $INTERFACE || true
EOF

    echo "已写入新的 /etc/network/interfaces"
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

base="${primary_ip%0}"

#------------------[ 卸载 cloud-init ]------------------#
remove_cloud_init

#------------------[ 跳过 Release 文件时间戳验证 ]------------------#
cat <<EOF >/etc/apt/apt.conf.d/99IgnoreTimestamp
Acquire::Check-Valid-Until "false";
Acquire::Check-Date "false";
EOF

#------------------[ 初始自动备份 ]------------------#
backup_network_interfaces

#------------------[ 让用户选择出口 ]------------------#
echo
echo "检测到 $INTERFACE 的主 IP: $primary_ip"
echo "可选附加出口："
echo "  0 = HKBN"
echo "  1 = Telus"
echo "  2 = Hinet"
echo "  3 = HKT"
echo "  4 = Sony"
echo "  5 = CMHK"
echo "  6 = Starlink"

read -rp "请选择 (0/1/2/3/4/5/6): " choice

if [[ "$choice" = "0" ]]; then
    if [ ! -f /etc/network/interfaces.HKBN ]; then
        download_hkbn_backup
    fi
    echo "恢复HKBN配置..."
    cp /etc/network/interfaces.HKBN /etc/network/interfaces
    reconfigure_network "$INTERFACE"
    echo "出口已变更。当前 IP："
    ip addr show dev "$INTERFACE"
    exit 0
fi

if [[ ! "$choice" =~ ^[1-6]$ ]]; then
    echo "无效选择，脚本退出。"
    exit 1
fi

# 计算附加 IP
additional_ip="${base}${choice}"

#------------------[ 更新网络组件并卸载不必要的组件 ]------------------#
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

#------------------[ 更新接口配置 ]------------------#
update_network_interface "$additional_ip"

#------------------[ 重新启动网络服务 ]------------------#
reconfigure_network "$INTERFACE"
