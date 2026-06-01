#!/bin/bash

# =========================================================
# Shadowsocks-Rust 管理脚本 (Alpine Linux )
# =========================================================

set -euo pipefail

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# ================== 基础变量 ==================
SS_DIR="/etc/ss-rust"
SS_CONFIG="${SS_DIR}/config.json"
SS_INIT_SCRIPT="/etc/init.d/ss-rust"
BINARY_PATH="/usr/local/bin/ssserver"
LOG_FILE="/var/log/ss-rust.log"
RUN_USER="ss-rust"
RUN_GROUP="ss-rust"
METHOD="2022-blake3-aes-256-gcm"
TMP_DIR=$(mktemp -d -t ss-rust.XXXXXX)

# ================== 工具函数 ==================
info() { echo -e "${GREEN}[信息] $*${RESET}"; }
error() { echo -e "${RED}[错误] $*${RESET}"; }
pause() { echo; echo -ne "${GREEN}按任意键返回菜单...${RESET}"; read -n 1 -s; echo; }

get_latest_version() {
    curl -fsSL "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | \
    grep '"tag_name":' | head -n 1 | sed -E 's/.*"v?([^"]+)".*/\1/'
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "x86_64-unknown-linux-musl" ;;
        aarch64) echo "aarch64-unknown-linux-musl" ;;
        *) error "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
}

get_vps_dns() {
    local dns_list=$(grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | paste -sd "," -)
    echo "${dns_list:-"1.1.1.1,8.8.8.8"}"
}

# 公网IP获取
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
    error "无法获取公网 IP 地址。" && return 1
}

# ================== 核心：写入配置 ==================
write_config_and_link() {
    local port=$1
    local pass=$2
    local dns_str=$3
    
    dns_str=$(echo "$dns_str" | tr -d ' ')
    local dns_json=$(echo "\"${dns_str//,/\",\"}\"")

    cat > "$SS_CONFIG" <<EOF
{
    "server": "::",
    "server_port": $port,
    "password": "$pass",
    "method": "$METHOD",
    "fast_open": true,
    "mode": "tcp_and_udp",
    "timeout": 300,
    "no_delay": true,
    "ipv6_first": false,
    "nameserver": [$dns_json]
}
EOF
    chown "${RUN_USER}:${RUN_GROUP}" "$SS_CONFIG"
    chmod 600 "$SS_CONFIG"

    local ip=$(get_public_ip)
    [[ "$ip" =~ : ]] && ip="[$ip]"
    local encoded=$(echo -n "${METHOD}:${pass}" | base64 | tr -d '\n')
    echo "ss://${encoded}@${ip}:${port}#$(hostname)-SS2022" > "${SS_DIR}/ss.txt"
    echo "${HOSTNAME}-SS2022 = ss, ${ip}, ${port}, encrypt-method=${METHOD}, password=${pass}, tfo=true, udp-relay=true, ecn=true" > "${SS_DIR}/Surge.txt"
}

show_node_info() {
    if [[ -f "${SS_CONFIG}" ]]; then
        local ip port pass

        ip=$(get_public_ip)
        port=$(grep -E '"server_port":' "$SS_CONFIG" | grep -oE '[0-9]+' | head -n1)
        pass=$(grep -E '"password":' "$SS_CONFIG" | cut -d '"' -f4 | head -n1)

        [[ "$ip" =~ : ]] && ip="[$ip]"

        echo -e "${GREEN}================================${RESET}"
        echo -e "${YELLOW}       Shadowsocks 节点信息      ${RESET}"
        echo -e "${GREEN}================================${RESET}"

        echo -e "${YELLOW} IP地址        : ${ip}${RESET}"
        echo -e "${YELLOW} 端口          : ${port}${RESET}"
        echo -e "${YELLOW} 密码          : ${pass}${RESET}"
        echo -e "${YELLOW} 加密          : ${METHOD}${RESET}"

        echo -e "${YELLOW}---------------------------------${RESET}"
        echo -e "${YELLOW}📄 V6 VPS 请替换为 IPv6 地址 ★${RESET}"

        echo
        echo -e "${GREEN}SS 链接:${RESET}"
        [[ -f "${SS_DIR}/ss.txt" ]] && echo -e "${YELLOW}$(cat "${SS_DIR}/ss.txt")${RESET}"

        echo
        echo -e "${YELLOW}[信息] Surge 配置：${RESET}"
        [[ -f "${SS_DIR}/Surge.txt" ]] && echo -e "${YELLOW}$(cat "${SS_DIR}/Surge.txt")${RESET}"

        echo -e "${GREEN}================================${RESET}"
    else
        error "配置不存在。"
    fi
}

# ================== 功能：安装 ==================
install_ss() {
    info "正在准备安装环境..."
    apk add curl wget tar xz openssl iproute2 coreutils >/dev/null 2>&1
    
    getent group "$RUN_GROUP" >/dev/null || addgroup -S "$RUN_GROUP"
    getent passwd "$RUN_USER" >/dev/null || adduser -S -D -H -G "$RUN_GROUP" -s /sbin/nologin "$RUN_USER"

    local ver=$(get_latest_version)
    local arch=$(detect_arch)
    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${ver}/shadowsocks-v${ver}.${arch}.tar.xz"

    info "正在下载 Shadowsocks-Rust v$ver..."
    cd "$TMP_DIR"
    wget -q --show-progress -O ss.tar.xz "$url"
    tar -xf ss.tar.xz
    install -m 755 ssserver "$BINARY_PATH"
    
    mkdir -p "$SS_DIR"
    echo "$ver" > "${SS_DIR}/version.txt"
    touch "$LOG_FILE"
    chown "${RUN_USER}:${RUN_GROUP}" "$LOG_FILE"

    local def_port=$((RANDOM % 40000 + 20000))
    local def_pass=$(openssl rand -base64 32 | tr -d '\n')
    local def_dns=$(get_vps_dns)

    echo -e "${YELLOW}--- 自定义配置 (回车使用随机默认值) ---${RESET}"
    read -rp "$(echo -e ${GREEN}"设置端口 [默认 $def_port]: "${RESET})" user_port
    user_port=${user_port:-$def_port}
    read -rp "$(echo -e ${GREEN}"设置密码 [默认随机生成]: "${RESET})" user_pass
    user_pass=${user_pass:-$def_pass}
    read -rp "$(echo -e ${GREEN}"设置 DNS (用逗号隔开) [默认 $def_dns]: "${RESET})" user_dns
    user_dns=${user_dns:-$def_dns}

    write_config_and_link "$user_port" "$user_pass" "$user_dns"

    cat > "$SS_INIT_SCRIPT" <<EOF
#!/sbin/openrc-run
name="ss-rust"
command="${BINARY_PATH}"
command_args="-c ${SS_CONFIG}"
command_user="${RUN_USER}:${RUN_GROUP}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"
depend() { need net; }
EOF
    chmod +x "$SS_INIT_SCRIPT"
    rc-update add ss-rust default
    rc-service ss-rust start
    info "安装完成！"
    show_node_info
}

# ================== 功能：更新 (无损替换) ==================
update_ss() {
    if [[ ! -f "$BINARY_PATH" ]]; then
        error "未发现已安装的服务，请先选择选项 1 安装。"
        return 1
    fi

    local current_ver=$(cat "${SS_DIR}/version.txt" 2>/dev/null || echo "未知")
    local latest_ver=$(get_latest_version)

    info "当前版本: $current_ver | 最新版本: v$latest_ver"

    if [[ "$current_ver" == "$latest_ver" ]]; then
        info "当前已是最新版本，无需更新。"
        return 0
    fi

    info "发现新版本，正在下载升级..."
    local arch=$(detect_arch)
    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${latest_ver}/shadowsocks-v${latest_ver}.${arch}.tar.xz"
    
    cd "$TMP_DIR"
    if wget -q --show-progress -O ss.tar.xz "$url"; then
        tar -xf ss.tar.xz
        rc-service ss-rust stop || true
        install -m 755 ssserver "$BINARY_PATH"
        echo "$latest_ver" > "${SS_DIR}/version.txt"
        rc-service ss-rust start
        info "更新成功！配置已保留。"
    else
        error "下载失败，请检查网络。"
    fi
}

# ================== 功能：修改配置 ==================
modify_ss() {
    if [[ ! -f "$SS_CONFIG" ]]; then
        error "未发现配置，请先安装"
        return 1
    fi

    local old_port=$(grep -E '"server_port":' "$SS_CONFIG" | head -n 1 | grep -oE '[0-9]+')
    local old_pass=$(grep -E '"password":' "$SS_CONFIG" | head -n 1 | cut -d '"' -f4)
    
    # 🛠 改进的 DNS 提取逻辑：直接匹配 nameserver 数组内的内容
    local old_dns=$(grep -A 5 '"nameserver":' "$SS_CONFIG" | grep -v '"nameserver":' | tr -d ' "[]\n\r\t' | sed 's/,$//' | grep -v '}')
    
    if [[ -z "$old_dns" || "$old_dns" == *"{"* ]]; then
        old_dns=$(get_vps_dns)
    fi

    echo -e "${YELLOW}--- 修改配置 (回车保持当前值) ---${RESET}"
    read -rp "$(echo -e ${GREEN}"新端口 [当前 $old_port]: "${RESET})" new_port
    new_port=${new_port:-$old_port}
    read -rp "$(echo -e ${GREEN}"新密码 [当前 $old_pass]: "${RESET})" new_pass
    new_pass=${new_pass:-$old_pass}
    read -rp "$(echo -e ${GREEN}"新 DNS (用逗号隔开) [当前 $old_dns]: "${RESET})" new_dns
    new_dns=${new_dns:-$old_dns}

    write_config_and_link "$new_port" "$new_pass" "$new_dns"
    rc-service ss-rust restart >/dev/null 2>&1 || true
    info "修改成功！"
    show_node_info
}

# ================== 菜单系统 ==================
while true; do
    if rc-service ss-rust status 2>/dev/null | grep -q "started"; then
        STATUS="${GREEN}● 运行中${RESET}"
    else
        STATUS="${RED}● 未运行${RESET}"
    fi

    VERSION_SHOW=$( [ -f "${SS_DIR}/version.txt" ] && echo "v$(cat ${SS_DIR}/version.txt)" || echo "未安装")
    PORT_SHOW=$( [ -f "$SS_CONFIG" ] && grep '"server_port"' "$SS_CONFIG" | head -n 1 | grep -oE '[0-9]+' || echo "-")

    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   Shadowsocks-Rust 管理面板    ${RESET}"
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

    read -rp "$(echo -e ${GREEN}"请输入选项: "${RESET})" choice
    case $choice in
        1) install_ss; pause ;;
        2) update_ss; pause ;;
        3) 
            rc-service ss-rust stop || true
            rc-update del ss-rust || true
            rm -f "$SS_INIT_SCRIPT" "$BINARY_PATH"
            rm -rf "$SS_DIR" "$LOG_FILE"
            info "已卸载"; pause ;;
        4) modify_ss; pause ;;
        5) rc-service ss-rust start; pause ;;
        6) rc-service ss-rust stop; pause ;;
        7) rc-service ss-rust restart; pause ;;
        8) 
            info "实时日志 (Ctrl+C 退出):"
            [[ -f "$LOG_FILE" ]] && tail -f "$LOG_FILE" || error "无日志文件"; pause ;;
        9) show_node_info; pause ;;
        0) exit 0 ;;
        *) sleep 0.5 ;;
    esac
done