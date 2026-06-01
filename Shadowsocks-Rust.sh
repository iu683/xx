#!/bin/bash
set -euo pipefail

# =========================================================
# Shadowsocks-Rust 管理脚本
# 加密方式: 2022-blake3-aes-256-gcm
# =========================================================

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# ================== 基础变量 ==================

SS_DIR="/etc/ss-rust"
SS_CONFIG="${SS_DIR}/config.json"

SS_SERVICE="/etc/systemd/system/ss-rust.service"

BINARY_PATH="/usr/local/bin/ssserver"

LOG_FILE="/var/log/ss-rust-manager.log"

RUN_USER="ss-rust"

METHOD="2022-blake3-aes-256-gcm"

KEY_BYTES=32

TMP_DIR=$(mktemp -d -t ss-rust.XXXXXX)


# ================== cleanup ==================
cleanup() {
    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}

trap cleanup EXIT INT TERM

# ================== 日志 ==================
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

pause() {
    read -n 1 -s -r -p "按任意键返回菜单..."
    echo
}

# ================== 创建用户 ==================
create_user() {
    id -u "$RUN_USER" &>/dev/null || \
        useradd -r -s /usr/sbin/nologin "$RUN_USER"
}

# ================== 获取公网IP ==================
get_public_ip() {

    local ip

    for cmd in \
        "curl -4fsSL --max-time 5" \
        "wget -4qO- --timeout=5"; do

        for url in \
            "https://api.ipify.org" \
            "https://ip.sb" \
            "https://checkip.amazonaws.com"; do

            ip=$($cmd "$url" 2>/dev/null) && \
            [[ -n "$ip" ]] && \
            echo "$ip" && return
        done
    done

    for cmd in \
        "curl -6fsSL --max-time 5" \
        "wget -6qO- --timeout=5"; do

        for url in \
            "https://api64.ipify.org" \
            "https://ipv6.ip.sb"; do

            ip=$($cmd "$url" 2>/dev/null) && \
            [[ -n "$ip" ]] && \
            echo "[$ip]" && return
        done
    done

    echo "无法获取公网IP"
}


# ================== 检查依赖 ==================
check_deps() {

    echo -e "${GREEN}[信息] 检查系统依赖...${RESET}"

    install_pkg() {
        if command -v apt >/dev/null 2>&1; then
            apt update -y
            apt install -y "$@"
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "$@"
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "$@"
        fi
    }

    command -v curl >/dev/null 2>&1 || install_pkg curl
    command -v wget >/dev/null 2>&1 || install_pkg wget
    command -v tar  >/dev/null 2>&1 || install_pkg tar

    # xz 解压支持
    if ! command -v xz >/dev/null 2>&1; then
        if command -v apt >/dev/null 2>&1; then
            install_pkg xz-utils
        else
            install_pkg xz
        fi
    fi

    # ss 命令 (check_port 用)
    command -v ss >/dev/null 2>&1 || {
        if command -v apt >/dev/null 2>&1; then
            install_pkg iproute2
        else
            install_pkg iproute
        fi
    }

    # openssl (随机密码)
    command -v openssl >/dev/null 2>&1 || install_pkg openssl

    echo -e "${GREEN}[完成] 依赖检查完成${RESET}"
}
# ================== 检查端口 ==================
check_port() {

    if ss -tulnH "( sport = :$1 )" | grep -q .; then
        echo -e "${RED}端口 $1 已被占用${RESET}"
        return 1
    fi
}

# ================== 随机密码 ==================
random_key() {
    openssl rand -base64 "$KEY_BYTES" | tr -d '\n'
}

# ================== 随机端口 ==================
random_port() {
    shuf -i 2000-65000 -n 1
}

# ================== 获取系统DNS ==================
get_system_dns() {

    grep -E '^nameserver' /etc/resolv.conf \
        | awk '{print $2}' \
        | paste -sd "," -
}

# ================== 验证密码 ==================
validate_password() {

    local password="$1"

    if ! echo "$password" | base64 -d >/dev/null 2>&1; then
        echo -e "${RED}密码不是合法 Base64${RESET}"
        return 1
    fi

    local decoded_len

    decoded_len=$(echo "$password" | base64 -d 2>/dev/null | wc -c)

    if [[ "$decoded_len" -ne "$KEY_BYTES" ]]; then
        echo -e "${RED}密码必须为 ${KEY_BYTES} 字节${RESET}"
        return 1
    fi
}

# ================== 检测架构 ==================
detect_arch() {

    case "$(uname -m)" in

        x86_64)
            echo "x86_64-unknown-linux-gnu"
            ;;

        aarch64)
            echo "aarch64-unknown-linux-gnu"
            ;;

        armv7l)
            echo "armv7-unknown-linux-gnueabihf"
            ;;

        *)
            echo -e "${RED}不支持架构: $(uname -m)${RESET}"
            exit 1
            ;;
    esac
}

# ================== 获取最新版本 ==================
get_latest_version() {

    curl -fsSL \
        "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" \
        | grep tag_name \
        | cut -d '"' -f4 \
        | sed 's/v//'
}

# ================== 写配置 ==================
write_config() {

    local port="$1"
    local password="$2"
    local dns="$3"

    mkdir -p "$SS_DIR"

    DNS_JSON=$(echo "$dns" | awk -F',' '{
        for(i=1;i<=NF;i++){
            gsub(/^[ \t]+|[ \t]+$/, "", $i)
            printf "%s\"%s\"", (i>1?",":""), $i
        }
    }')

    cat > "$SS_CONFIG" <<EOF
{
    "server": "::",
    "server_port": $port,
    "password": "$password",
    "method": "$METHOD",
    "fast_open": true,
    "mode": "tcp_and_udp",
    "timeout": 300,
    "no_delay": true,
    "ipv6_first": false,
    "nameserver": [
        $DNS_JSON
    ]
}
EOF

    chmod 600 "$SS_CONFIG"
    chown -R ${RUN_USER}:${RUN_USER} "$SS_DIR"
}

# ================== 生成链接 ==================
generate_links() {

    local port="$1"
    local password="$2"

    IP=$(get_public_ip)

    HOSTNAME=$(hostname -s | sed 's/ /_/g')

    ENCODED=$(echo -n "${METHOD}:${password}" | base64 -w 0)

    # ===== SS Link =====
    cat > "${SS_DIR}/ss.txt" <<EOF
ss://${ENCODED}@${IP}:${port}#${HOSTNAME}-SS2022
EOF

    # ===== Surge =====
    cat > "${SS_DIR}/surge.txt" <<EOF
${HOSTNAME}-SS2022 = ss, ${IP}, ${port}, encrypt-method=${METHOD}, password=${password}, tfo=true, udp-relay=true, ecn=true
EOF
}

# ================== 安装配置 ==================
configure_ss() {

    echo -e "${GREEN}[信息]开始配置 Shadowsocks-Rust...${RESET}"

    # ===== 端口 =====
    while true; do

        read -p "请输入端口 (默认:随机生成): " input_port

        if [[ -z "$input_port" ]]; then
            port=$(random_port)
        else
            port="$input_port"
        fi

        if [[ "$port" =~ ^[0-9]+$ ]] \
            && [[ "$port" -ge 1 ]] \
            && [[ "$port" -le 65535 ]]; then

            check_port "$port" || continue
            break
        else
            echo -e "${RED}端口无效${RESET}"
        fi
    done

    # ===== 密码 =====
    read -p "请输入密码 (默认:随机生成): " input_password

    if [[ -z "$input_password" ]]; then

        password=$(random_key)

    else

        validate_password "$input_password" || return

        password="$input_password"
    fi

    # ===== DNS =====
    default_dns=$(get_system_dns)
    [[ -z "$default_dns" ]] && \
    default_dns="1.1.1.1,8.8.8.8"

    read -p "请输入 DNS (默认:$default_dns): " dns
    dns=${dns:-$default_dns}

    write_config "$port" "$password" "$dns"
    generate_links "$port" "$password"

    IP=$(get_public_ip)

    echo -e "${GREEN}[完成] 配置已保存${RESET}"

    echo -e "${GREEN}====== Shadowsocks 配置 ======${RESET}"

    echo -e "${YELLOW} IP地址        : ${IP}${RESET}"

    echo -e "${YELLOW} 端口          : ${port}${RESET}"

    echo -e "${YELLOW} 密码          : ${password}${RESET}"

    echo -e "${YELLOW} 加密          : ${METHOD}${RESET}"
    echo -e "${YELLOW} DNS           : ${dns}${RESET}"

    echo -e "${YELLOW}---------------------------------${RESET}"
    echo -e "${YELLOW}📄 V6VPS 替换IP地址为V6 ★${RESET}"

    echo -e "${YELLOW}[信息] SS链接：${RESET}"

    cat "${SS_DIR}/ss.txt"

    echo

    echo -e "${YELLOW}[信息] Surge 配置：${RESET}"

    cat "${SS_DIR}/surge.txt"

    echo -e "${YELLOW}---------------------------------${RESET}"
}

# ================== 修改配置 ==================
modify_ss() {

    echo -e "${GREEN}[信息]开始修改 Shadowsocks 配置...${RESET}"

    if [[ ! -f "$SS_CONFIG" ]]; then
        echo -e "${RED}配置文件不存在${RESET}"
        return
    fi

    old_port=$(grep server_port "$SS_CONFIG" | grep -o '[0-9]\+')

    old_password=$(grep password "$SS_CONFIG" \
        | cut -d '"' -f4)
    
    old_dns=$(awk '
    /"nameserver"/ {flag=1; next}
    flag && /\]/ {flag=0}
    flag {
        gsub(/[",[:space:]]/, "")
        if(length) print
    }' "$SS_CONFIG" | paste -sd "," -)

    echo -e "${YELLOW}当前端口 : ${old_port}${RESET}"

    echo -e "${YELLOW}当前密码 : ${old_password}${RESET}"

    echo

    # ===== 新端口 =====
    while true; do

        read -p "请输入新端口 [当前:${old_port}]: " input_port

        port=${input_port:-$old_port}

        if [[ "$port" =~ ^[0-9]+$ ]] \
            && [[ "$port" -ge 1 ]] \
            && [[ "$port" -le 65535 ]]; then

            if [[ "$port" != "$old_port" ]]; then
                check_port "$port" || continue
            fi

            break
        else
            echo -e "${RED}端口无效${RESET}"
        fi
    done

    # ===== 密码 =====
    echo
    echo "1. 保持当前密码"
    echo "2. 手动输入密码"
    echo "3. 自动生成密码"

    read -p "请选择 [默认:1]: " pwd_mode

    case $pwd_mode in

        2)

            while true; do

                read -p "请输入 Base64 密码: " input_password

                validate_password "$input_password" && break
            done

            password="$input_password"
            ;;

        3)

            password=$(random_key)

            echo -e "${GREEN}已生成新密码${RESET}"
            ;;

        *)

            password="$old_password"
            ;;
    esac

    # ===== DNS =====
    default_dns=$(get_system_dns)
    [[ -z "$default_dns" ]] && \
    default_dns="1.1.1.1,8.8.8.8"

    default_dns=${old_dns:-$default_dns}

    echo
    read -p "请输入 DNS [当前:$default_dns]: " dns
    dns=${dns:-$default_dns}

    cp "$SS_CONFIG" \
        "${SS_CONFIG}.bak.$(date +%s)"

    write_config "$port" "$password" "$dns"

    generate_links "$port" "$password"

    systemctl restart ss-rust

    IP=$(get_public_ip)

    echo -e "${GREEN}[完成] 配置修改成功${RESET}"

    echo

    echo -e "${GREEN}====== Shadowsocks 配置 ======${RESET}"

    echo -e "${YELLOW} IP地址        : ${IP}${RESET}"

    echo -e "${YELLOW} 端口          : ${port}${RESET}"

    echo -e "${YELLOW} 密码          : ${password}${RESET}"

    echo -e "${YELLOW} 加密          : ${METHOD}${RESET}"
    echo -e "${YELLOW} DNS           : ${dns}${RESET}"

    echo
    echo -e "${YELLOW}📄 V6VPS 替换IP地址为V6 ★${RESET}"

    echo -e "${YELLOW}[信息] SS链接：${RESET}"

    cat "${SS_DIR}/ss.txt"

    echo

    echo -e "${YELLOW}[信息] Surge 配置：${RESET}"

    cat "${SS_DIR}/surge.txt"

    echo

    log "Shadowsocks 配置已修改"
}

# ================== 安装 ==================
install_ss() {

    echo -e "${GREEN}[信息] 开始安装 Shadowsocks-Rust...${RESET}"
    
    check_deps

    create_user

    mkdir -p "$SS_DIR"

    cd "$TMP_DIR"

    VERSION=$(get_latest_version)

    ARCH=$(detect_arch)

    URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${VERSION}/shadowsocks-v${VERSION}.${ARCH}.tar.xz"

    wget -O ss.tar.xz "$URL"

    tar -xf ss.tar.xz

    install -m 755 ssserver "$BINARY_PATH"

    echo "$VERSION" > "${SS_DIR}/version.txt"

    configure_ss

    # ===== systemd =====
    cat > "$SS_SERVICE" <<EOF
[Unit]
Description=Shadowsocks Rust Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

User=${RUN_USER}
Group=${RUN_USER}

ExecStart=${BINARY_PATH} -c ${SS_CONFIG}

Restart=on-failure
RestartSec=3

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

NoNewPrivileges=true

PrivateTmp=true

ProtectSystem=strict
ProtectHome=true

ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    systemctl enable ss-rust

    systemctl restart ss-rust

    echo -e "${GREEN}[完成] Shadowsocks-Rust 已安装并启动${RESET}"

    log "Shadowsocks-Rust 已安装"
}

# ================== 更新 ==================
update_ss() {

    echo -e "${GREEN}[信息] 更新 Shadowsocks-Rust...${RESET}"

    if [[ ! -f "$SS_CONFIG" ]]; then
        echo -e "${RED}未找到配置文件${RESET}"
        return
    fi

    systemctl stop ss-rust || true

    cd "$TMP_DIR"

    VERSION=$(get_latest_version)

    ARCH=$(detect_arch)

    URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${VERSION}/shadowsocks-v${VERSION}.${ARCH}.tar.xz"

    wget -O ss.tar.xz "$URL"

    tar -xf ss.tar.xz

    install -m 755 ssserver "$BINARY_PATH"

    echo "$VERSION" > "${SS_DIR}/version.txt"

    systemctl restart ss-rust

    echo -e "${GREEN}[完成] Shadowsocks-Rust 已更新${RESET}"

    log "Shadowsocks-Rust 已更新"
}

# ================== 卸载 ==================
uninstall_ss() {

    echo -e "${RED}[警告] 卸载 Shadowsocks-Rust...${RESET}"

    systemctl stop ss-rust || true

    systemctl disable ss-rust || true

    rm -f "$SS_SERVICE"

    rm -rf "$SS_DIR"

    rm -f "$BINARY_PATH"

    systemctl daemon-reload

    echo -e "${GREEN}[完成] Shadowsocks-Rust 已卸载${RESET}"

    log "Shadowsocks-Rust 已卸载"
}

# ================== 菜单 ==================
show_menu() {

    clear

    if systemctl is-active --quiet ss-rust; then
        STATUS="${GREEN}● 运行中${RESET}"
    else
        STATUS="${RED}● 未运行${RESET}"
    fi

    VERSION_SHOW="未安装"

    if [[ -f "${SS_DIR}/version.txt" ]]; then
        VERSION_SHOW="v$(cat "${SS_DIR}/version.txt")"
    fi

    PORT_SHOW="-"

    if [[ -f "$SS_CONFIG" ]]; then
        PORT_SHOW=$(grep server_port "$SS_CONFIG" \
            | grep -o '[0-9]\+')
    fi

    echo -e "${GREEN}================================${RESET}"

    echo -e "${GREEN}   Shadowsocks-Rust 管理面板        ${RESET}"

    echo -e "${GREEN}================================${RESET}"

    echo -e "${GREEN}状态   :${RESET} $STATUS"

    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${VERSION_SHOW}${RESET}"

    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${PORT_SHOW}${RESET}"

    echo -e "${GREEN}================================${RESET}"

    echo -e "${GREEN}1. 安装 Shadowsocks-Rust${RESET}"

    echo -e "${GREEN}2. 更新 Shadowsocks-Rust${RESET}"

    echo -e "${GREEN}3. 卸载 Shadowsocks-Rust${RESET}"

    echo -e "${GREEN}4. 修改配置${RESET}"

    echo -e "${GREEN}5. 启动 Shadowsocks-Rust${RESET}"

    echo -e "${GREEN}6. 停止 Shadowsocks-Rust${RESET}"

    echo -e "${GREEN}7. 重启 Shadowsocks-Rust${RESET}"

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

        1)
            install_ss
            pause
            ;;

        2)
            update_ss
            pause
            ;;

        3)
            uninstall_ss
            pause
            ;;

        4)
            modify_ss
            pause
            ;;

        5)
            systemctl start ss-rust
            echo -e "${GREEN}[完成] Shadowsocks 已启动${RESET}"
            log "Shadowsocks 启动"
            pause
            ;;

        6)
            systemctl stop ss-rust
            echo -e "${GREEN}[完成] Shadowsocks 已停止${RESET}"
            log "Shadowsocks 停止"
            pause
            ;;

        7)
            systemctl restart ss-rust
            echo -e "${GREEN}[完成] Shadowsocks 已重启${RESET}"
            log "Shadowsocks 重启"
            pause
            ;;

        8)
            journalctl -u ss-rust -e --no-pager
            pause
            ;;

        9)

            if [[ -f "$SS_CONFIG" ]]; then

                echo -e "${GREEN}====== 当前配置 ======${RESET}"

                cat "$SS_CONFIG"

                echo

                echo -e "${GREEN}====== SS链接 ======${RESET}"

                cat "${SS_DIR}/ss.txt"

                echo

                echo -e "${GREEN}====== Surge 配置 ======${RESET}"

                cat "${SS_DIR}/surge.txt"

            else

                echo -e "${RED}配置文件不存在${RESET}"

            fi

            pause
            ;;

        0)
            exit 0
            ;;

        *)
            echo -e "${RED}无效输入${RESET}"
            pause
            ;;
    esac
done