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

#------------------[ 2. 检测 eth0 与 192.168.51.x0 ]------------------#
if ! ip link show "$INTERFACE" &>/dev/null; then
    echo "网卡 $INTERFACE 不存在，请确认网卡名称或修改脚本。"
    exit 1
fi

# 仅匹配 192.168.51.x0 形式的 IP
primary_ip=$(ip -4 addr show "$INTERFACE" \
    | grep -oP '(?<=inet\s)192\.168\.51\.\d+0(?=/)' \
    | head -n1)
if [ -z "$primary_ip" ]; then
    echo "未在 $INTERFACE 上找到 192.168.51.x0 格式的 IP（如 192.168.51.10、192.168.51.20 等）"
    exit 1
fi
echo "检测到的主 IP：$primary_ip"

base="${primary_ip%0}"  # 去掉末尾的 0，用于后续拼接

#------------------[ 3. 初始自动备份 ]------------------#
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

#------------------[ 4. 让用户选择 ]------------------#
echo
echo "检测到 $INTERFACE 的主 IP: $primary_ip"
echo "可选附加 IP："
echo "  0 = HKBN"
echo "  1 = Telus"
echo "  2 = Hinet"
echo "  3 = HKT"
echo "  4 = Sony"

read -rp "请选择 (0/1/2/3/4): " choice

#------------------[ 5. 若选 0, 从 HKBN 备份还原并退出 ]------------------#
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

#------------------[ 6. 若不是 0，也不是 1~4，则退出 ]------------------#
if [[ ! "$choice" =~ ^[1-4]$ ]]; then
    echo "无效选择，脚本退出。"
    exit 1
fi

additional_ip="${base}${choice}"

#==============================================================
#     在这里插入时间同步逻辑，避免 apt-get update 报错
#==============================================================
echo "尝试启用系统时间同步，以避免 Release 文件时间戳错误..."

if command -v timedatectl &>/dev/null; then
    # 开启 NTP
    timedatectl set-ntp true || true
    
    # 重启 systemd-timesyncd 让其尽快进行对时
    if systemctl list-unit-files | grep -qw systemd-timesyncd.service; then
        systemctl restart systemd-timesyncd || true
    fi
    
    # 等待几秒，让 NTP 对时有机会完成初步同步
    sleep 5
else
    echo "系统中无 timedatectl 命令，请手动确保系统时间正确，或安装 chrony/ntp 服务。"
fi

#==============================================================
#    如仍担心因时间不同步导致失败，可临时忽略时间戳
#    （非必要，若上面对时成功，就能正常 apt-get update）
#==============================================================
# APT_OPTS="-o Acquire::Check-Valid-Until=false"
# 或者写死进命令里:
# DEBIAN_FRONTEND=noninteractive apt-get $APT_OPTS update -y
# 这里先默认不开启跳过校验
#==============================================================

#------------------[ 7. 更新并卸载 netplan 等 ]------------------#
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get purge -y netplan.io systemd-networkd network-manager ifupdown || true
apt-get autoremove -y

# 重新安装 ifupdown
DEBIAN_FRONTEND=noninteractive apt-get install -y ifupdown

# 若存在 /etc/netplan 目录，则备份后移除
if [ -d /etc/netplan ]; then
    mv /etc/netplan "/etc/netplan.bak.$(date +%s)" || true
fi

#------------------[ 8. 备份并写入 /etc/network/interfaces ]------------------#
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
    
    # 让系统在启动时给该网卡额外添加一个IP
    up ip addr add $additional_ip/24 dev $INTERFACE
    
    # 刷新默认路由，再设置新的默认路由
    up ip route flush default
    # 下方网关仍固定为 192.168.51.1，如需其他网关请自行修改
    up ip route add default via 192.168.51.1 dev $INTERFACE src $additional_ip metric 100
    
    # 脚本退出前，从网卡移除该临时IP，避免冲突
    down ip addr del $additional_ip/24 dev $INTERFACE || true
EOF

echo "已写入新的 /etc/network/interfaces"

#------------------[ 9. ifdown & ifup ]------------------#

sleep 2
ifdown "$INTERFACE" || true
ifup "$INTERFACE"

#------------------[ 10. 显示结果 ]------------------#
echo "出口已变更。当前 IP："
ip addr show dev "$INTERFACE"
