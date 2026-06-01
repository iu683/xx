#!/bin/bash
set -e

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# ================== 变量 ==================
SNELL_DIR="/etc/snell"
SNELL_CONFIG="$SNELL_DIR/snell-server.conf"
SNELL_SERVICE="/etc/systemd/system/snell.service"
LOG_FILE="/var/log/snell_manager.log"

# ================== 工具函数 ==================
create_user() {
    id -u snell &>/dev/null || useradd -r -s /usr/sbin/nologin snell
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP 地址。" && return
}

check_port() {
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

random_key() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 16
}

random_port() {
    shuf -i 2000-65000 -n 1
}

get_system_dns() {
    grep -E "^nameserver" /etc/resolv.conf | awk '{print $2}' | paste -sd "," -
}

pause() {
    read -n 1 -s -r -p "按任意键返回菜单..."
}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# 动态获取官方最新 Snell v5 版本
get_latest_snell_version() {
    local latest_version
    # 模拟常见浏览器 User-Agent，防止被拦截
    latest_version=$(curl -sL -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
        "https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell" | \
        grep -oE 'v5\.[0-9]+\.[0-9]+' | head -n 1 2>/dev/null || echo "")
        
    # 兜底：如果抓取失败，使用目前的 v5.0.1 保证脚本可用
    if [[ -z "$latest_version" ]]; then
        latest_version="v5.0.1"
    fi
    echo "$latest_version"
}

# ================== 配置 Snell ==================
configure_snell() {
    echo -e "${GREEN}[信息]开始配置 Snell...${RESET}"

    # ===== 端口自定义 / 随机 =====
    read -p "请输入端口 (默认:随机生成): " input_port
    if [[ -z "$input_port" ]]; then
        port=$(shuf -i 20-65535 -n1)
    else
        port=$input_port
    fi
    check_port "$port" || return

    read -p "请输入Snell密钥 (默认:随机生成): " key
    key=${key:-$(random_key)}

    echo -e "${YELLOW}配置 OBFS：[注意] 无特殊作用不建议启用${RESET}"
    echo "1. TLS   2. HTTP   3. 关闭"
    read -p "(默认: 3): " obfs
    case $obfs in
        1) obfs="tls" ;;
        2) obfs="http" ;;
        *) obfs="off" ;;
    esac

    echo -e "${YELLOW}是否开启 IPv6 解析？${RESET}"
    echo "1. 开启   2. 关闭"
    read -p "(默认: 2): " ipv6
    ipv6=${ipv6:-2}
    ipv6=$([ "$ipv6" = "1" ] && echo true || echo false)

    echo -e "${YELLOW}是否开启 TCP Fast Open？${RESET}"
    echo "1. 开启   2. 关闭"
    read -p "(默认: 1): " tfo
    tfo=${tfo:-1}
    tfo=$([ "$tfo" = "1" ] && echo true || echo false)

    default_dns=$(get_system_dns)
    [[ -z "$default_dns" ]] && default_dns="1.1.1.1,8.8.8.8"
    read -p "请输入 DNS (默认: $default_dns): " dns
    dns=${dns:-$default_dns}

    if [[ "$ipv6" == "true" ]]; then
        LISTEN="::0:$port"
    else
        LISTEN="0.0.0.0:$port"
    fi
    cat > $SNELL_CONFIG <<EOF
[snell-server]
listen = $LISTEN
psk = $key
obfs = $obfs
ipv6 = $ipv6
tfo = $tfo
dns = $dns
EOF

    # 获取公网 IP
    IP=$(get_public_ip)
    HOSTNAME=$(hostname -s | sed 's/ /_/g')

    # 写 Surge 示例
    cat <<EOF > $SNELL_DIR/config.txt
$HOSTNAME-Snell = snell, $IP, $port, psk=$key, version=5, tfo=$tfo, reuse=true, ecn=true
EOF

    echo -e "${GREEN}[完成] 配置已写入 $SNELL_CONFIG${RESET}"
    echo -e "${GREEN}====== Snell Server 配置信息 ======${RESET}"
    echo -e "${YELLOW} IPv4 地址      : $IP${RESET}"
    echo -e "${YELLOW} 端口           : $port${RESET}"
    echo -e "${YELLOW} 密钥           : $key${RESET}"
    echo -e "${YELLOW} OBFS           : $obfs${RESET}"
    echo -e "${YELLOW} IPv6           : $ipv6${RESET}"
    echo -e "${YELLOW} TFO            : $tfo${RESET}"
    echo -e "${YELLOW} DNS            : $dns${RESET}"
    echo -e "${YELLOW}---------------------------------${RESET}"
    echo -e "${YELLOW}📄 V6VPS 替换IP地址为V6 ★${RESET}"
    echo -e "${YELLOW}[信息] Surge 配置：${RESET}"
    cat $SNELL_DIR/config.txt
    echo -e "${YELLOW}---------------------------------\n${RESET}"
}

# ================== 修改配置 Snell ==================
configures_snell() {
    echo -e "${GREEN}[信息]开始修改配置 Snell...${RESET}"

    # ===== 读取旧配置 =====
    if [[ -f "$SNELL_CONFIG" ]]; then
        old_listen=$(grep '^listen' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
        old_port=$(echo "$old_listen" | awk -F: '{print $NF}')
        old_key=$(grep '^psk' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
        old_obfs=$(grep '^obfs' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
        old_ipv6=$(grep '^ipv6' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
        old_tfo=$(grep '^tfo' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
        old_dns=$(grep '^dns' "$SNELL_CONFIG" | awk -F'= ' '{print $2}')
    fi

    # ===== 默认值 =====
    default_port=${old_port:-$(random_port)}
    default_key=${old_key:-$(random_key)}
    default_obfs=${old_obfs:-off}
    default_ipv6=${old_ipv6:-false}
    default_tfo=${old_tfo:-true}

    default_dns=$(get_system_dns)
    [[ -z "$default_dns" ]] && default_dns="1.1.1.1,8.8.8.8"
    default_dns=${old_dns:-$default_dns}

    # ===== 端口 =====
    read -p "请输入端口 [当前:$default_port]: " input_port
    port=${input_port:-$default_port}

    if [[ "$port" != "$old_port" ]]; then
        check_port "$port" || return
    fi

    # ===== 密钥 =====
    read -p "请输入Snell密钥 [当前:$default_key]: " key
    key=${key:-$default_key}

    # ===== OBFS =====
    echo -e "${YELLOW}配置 OBFS：[注意] 无特殊作用不建议启用${RESET}"
    echo "1. TLS   2. HTTP   3. 关闭"
    echo -e "${YELLOW}当前: $default_obfs${RESET}"
    read -p "(默认保留当前): " obfs_choice

    case $obfs_choice in
        1) obfs="tls" ;;
        2) obfs="http" ;;
        3) obfs="off" ;;
        *) obfs="$default_obfs" ;;
    esac

    # ===== IPv6 =====
    echo -e "${YELLOW}是否开启 IPv6 解析？${RESET}"
    echo "1. 开启   2. 关闭"
    echo -e "${YELLOW}当前: $default_ipv6${RESET}"
    read -p "(默认保留当前): " ipv6_choice
    case $ipv6_choice in
        1) ipv6=true ;;
        2) ipv6=false ;;
        *) ipv6=$default_ipv6 ;;
    esac

    # ===== TFO =====
    echo -e "${YELLOW}是否开启 TCP Fast Open？${RESET}"
    echo "1. 开启   2. 关闭"
    echo -e "${YELLOW}当前: $default_tfo${RESET}"
    read -p "(默认保留当前): " tfo_choice
    case $tfo_choice in
        1) tfo=true ;;
        2) tfo=false ;;
        *) tfo=$default_tfo ;;
    esac

    # ===== DNS =====
    read -p "请输入 DNS [当前:$default_dns]: " dns
    dns=${dns:-$default_dns}

    # ===== listen =====
    if [[ "$ipv6" == "true" ]]; then
        LISTEN="::0:$port"
    else
        LISTEN="0.0.0.0:$port"
    fi

    # ===== 写配置 =====
    cat > "$SNELL_CONFIG" <<EOF
[snell-server]
listen = $LISTEN
psk = $key
obfs = $obfs
ipv6 = $ipv6
tfo = $tfo
dns = $dns
EOF

    # ===== 获取公网IP =====
    IP=$(get_public_ip)
    HOSTNAME=$(hostname -s | sed 's/ /_/g')

    cat > "$SNELL_DIR/config.txt" <<EOF
$HOSTNAME-Snell = snell, $IP, $port, psk=$key, version=5, tfo=$tfo, reuse=true, ecn=true
EOF

    echo -e "${GREEN}[完成] 配置已保存${RESET}"
    echo -e "${GREEN}====== Snell Server 配置信息 ======${RESET}"
    echo -e "${YELLOW} IPv4 地址      : $IP${RESET}"
    echo -e "${YELLOW} 端口           : $port${RESET}"
    echo -e "${YELLOW} 密钥           : $key${RESET}"
    echo -e "${YELLOW} OBFS           : $obfs${RESET}"
    echo -e "${YELLOW} IPv6           : $ipv6${RESET}"
    echo -e "${YELLOW} TFO            : $tfo${RESET}"
    echo -e "${YELLOW} DNS            : $dns${RESET}"
    echo -e "${YELLOW}---------------------------------${RESET}"
    echo -e "${YELLOW}📄 V6VPS 替换IP地址为V6 ★${RESET}"
    echo -e "${YELLOW}[信息] Surge 配置：${RESET}"
    cat "$SNELL_DIR/config.txt"
    echo -e "${YELLOW}---------------------------------\n${RESET}"
}

# ================== 安装 Snell ==================
install_snell() {
    echo -e "${GREEN}[信息] 正在获取官方最新版本号...${RESET}"
    local VERSION
    VERSION=$(get_latest_snell_version)
    echo -e "${GREEN}[信息] 检测到官方最新版本为: ${VERSION}${RESET}"

    echo -e "${GREEN}[信息] 开始安装 Snell...${RESET}"
    create_user
    mkdir -p $SNELL_DIR
    cd $SNELL_DIR

    ARCH=$(uname -m)
    if [[ "$ARCH" == "aarch64" ]]; then
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-aarch64.zip"
    else
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-amd64.zip"
    fi

    wget -O snell.zip "$SNELL_URL"
    unzip -o snell.zip -d $SNELL_DIR
    rm -f snell.zip
    chmod +x $SNELL_DIR/snell-server

    configure_snell

    # systemd 文件
    cat > $SNELL_SERVICE <<EOF
[Unit]
Description=Snell Server
After=network.target

[Service]
ExecStart=$SNELL_DIR/snell-server -c $SNELL_CONFIG
Restart=on-failure
User=snell
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable snell
    systemctl start snell
    echo -e "${GREEN}[完成] Snell 已安装并启动${RESET}"
    log "Snell 已安装并启动 (${VERSION})"
}

# ================== 更新 Snell ==================
update_snell() {
    if [ ! -f "$SNELL_CONFIG" ]; then
        echo -e "${RED}未找到配置文件，无法更新${RESET}"
        return
    fi

    echo -e "${GREEN}[信息] 正在获取官方最新版本号...${RESET}"
    local VERSION
    VERSION=$(get_latest_snell_version)
    echo -e "${GREEN}[信息] 检测到官方最新版本为: ${VERSION}${RESET}"

    systemctl stop snell || true
    cd $SNELL_DIR

    ARCH=$(uname -m)
    if [[ "$ARCH" == "aarch64" ]]; then
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-aarch64.zip"
    else
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-amd64.zip"
    fi

    wget -O snell.zip "$SNELL_URL"
    unzip -o snell.zip -d $SNELL_DIR
    rm -f snell.zip
    chmod +x $SNELL_DIR/snell-server

    systemctl restart snell

    echo -e "${GREEN}[完成] Snell 已更新至 ${VERSION}${RESET}"
    log "Snell 已更新 (${VERSION})"
}

# ================== 卸载 Snell ==================
uninstall_snell() {
    echo -e "${RED}[警告] 卸载 Snell...${RESET}"
    systemctl stop snell || true
    systemctl disable snell || true
    rm -f $SNELL_SERVICE
    rm -rf $SNELL_DIR
    systemctl daemon-reload
    echo -e "${GREEN}[完成] Snell 已卸载${RESET}"
    log "Snell 已卸载"
}

# ================== 菜单 ==================
show_menu() {
    clear

    # ===== 运行状态 =====
    if systemctl is-active --quiet snell; then
        STATUS="${GREEN}● 运行中${RESET}"
    else
        STATUS="${RED}● 未运行${RESET}"
    fi

    # ===== 版本 =====
    VERSION_SHOW="未安装"

    if [ -x "$SNELL_DIR/snell-server" ]; then
        # 尝试读取 Snell 版本
        VERSION_SHOW=$("$SNELL_DIR/snell-server" -v 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')

        # 如果没读到，再尝试 --version
        [ -z "$VERSION_SHOW" ] && \
        VERSION_SHOW=$("$SNELL_DIR/snell-server" --version 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
  
        # 最后兜底
        [ -z "$VERSION_SHOW" ] && VERSION_SHOW="未知版本"
    fi

    # ===== 端口 =====
    PORT_SHOW="-"
    if [ -f "$SNELL_CONFIG" ]; then
        PORT_SHOW=$(grep '^listen' "$SNELL_CONFIG" | awk -F: '{print $NF}')
    fi

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}         Snell 管理面板         ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $STATUS"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}$VERSION_SHOW${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}$PORT_SHOW${RESET}"
    echo -e "${GREEN}================================${RESET}"

    echo -e "${GREEN}1. 安装 Snell${RESET}"
    echo -e "${GREEN}2. 更新 Snell${RESET}"
    echo -e "${GREEN}3. 卸载 Snell${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 Snell${RESET}"
    echo -e "${GREEN}6. 停止 Snell${RESET}"
    echo -e "${GREEN}7. 重启 Snell${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"

    echo -e "${GREEN}================================${RESET}"
}

# ================== 主循环 ==================
while true; do
    show_menu
    read -r -p $'\033[32m请输入选项: \033[0m' choice
    case $choice in
        1) install_snell; pause ;;
        2) update_snell; pause ;;
        3) uninstall_snell; pause ;;
        4) configures_snell; systemctl restart snell; pause ;;
        5) systemctl start snell; echo -e "${GREEN}[完成] Snell 已启动${RESET}"; log "Snell 启动"; pause ;;
        6) systemctl stop snell; echo -e "${GREEN}[完成] Snell 已停止${RESET}"; log "Snell 停止"; pause ;;
        7) systemctl restart snell; echo -e "${GREEN}[完成] Snell 已重启${RESET}"; log "Snell 重启"; pause ;;
        8) journalctl -u snell -e --no-pager; pause ;;
        9)
            if [ -f "$SNELL_CONFIG" ]; then
                echo -e "${GREEN}====== 当前 Snell 配置 ======${RESET}"
                cat "$SNELL_CONFIG"
                echo -e "${GREEN}====== Surge 配置 ======${RESET}"
                cat "$SNELL_DIR/config.txt"
            else
                echo -e "${RED}配置文件不存在${RESET}"
            fi
            pause
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${RESET}"; pause ;;
    esac
done