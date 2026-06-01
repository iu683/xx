#!/bin/bash
set -euo pipefail

# =========================================================
# Shadowsocks-Rust + Shadow-TLS 管理脚本 
# SS加密方式: 2022-blake3-aes-256-gcm
# =========================================================

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"
Info="${GREEN}[信息]${RESET}"
Error="${RED}[错误]${RESET}"

# ================== 基础变量 ==================
SS_DIR="/etc/stls-integrated-sss"
SS_Conf="${SS_DIR}/config.json"
SS_File="/usr/local/bin/stls-integrated-ssservers"

STLS_Env="${SS_DIR}/shadow-tlss.env"
STLS_File="/usr/local/bin/stls-integrated-shadow-tlss"

LOG_FILE="/var/log/stls-integrated-managers.log"
METHOD="2022-blake3-aes-256-gcm"
KEY_BYTES=32

TMP_DIR=$(mktemp -d -t ss-rusts.XXXXXX)

# ================== cleanup ==================
cleanup() {
    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

# ================== 日志与暂停 ==================
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null || true
}

pause() {
    echo -n "按任意键返回菜单..."
    read -n 1 -s -r || true
    echo
}

# ================== 智能获取公网双栈 IP ==================
get_public_ip() {
    local ip
    ip=$(curl -4fsSL --max-time 3 https://api.ipify.org 2>/dev/null || echo "")
    if [[ -z "$ip" ]]; then
        ip=$(curl -6fsSL --max-time 3 https://api64.ipify.org 2>/dev/null || echo "")
        [[ -n "$ip" ]] && echo "[$ip]" && return
    fi
    [[ -z "$ip" ]] && ip="你的服务器IP"
    echo "$ip"
}

# ================== 检查依赖 ==================
check_deps() {
    echo -e "${GREEN}[信息] 检查系统依赖...${RESET}"
    install_pkg() {
        if command -v apt >/dev/null 2>&1; then
            apt update -y && apt install -y "$@"
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "$@"
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "$@"
        fi
    }
    command -v curl >/dev/null 2>&1 || install_pkg curl
    command -v wget >/dev/null 2>&1 || install_pkg wget
    command -v tar  >/dev/null 2>&1 || install_pkg tar
    if ! command -v xz >/dev/null 2>&1; then
        if command -v apt >/dev/null 2>&1; then install_pkg xz-utils; else install_pkg xz; fi
    fi
    command -v ss >/dev/null 2>&1 || {
        if command -v apt >/dev/null 2>&1; then install_pkg iproute2; else install_pkg iproute; fi
    }
    command -v openssl >/dev/null 2>&1 || install_pkg openssl
    echo -e "${GREEN}[完成] 依赖检查完成${RESET}"
}

# ================== 检查端口 ==================
check_port() {
    if ss -tulnH "( sport = :$1 )" 2>/dev/null | grep -q .; then
        echo -e "${RED}端口 $1 已被占用${RESET}"
        return 1
    fi
    return 0
}

# ================== 辅助生成器与校验  ==================

random_key() {
    # 先生成一个纯字母数字的 32 位字符串，然后直接用 base64 编码，确保解密后绝对是精准的 32 字节
    local pure_str
    pure_str=$(openssl rand -hex 16 2>/dev/null | tr -d '\n')
    # 补齐到 32 个纯字符
    pure_str="${pure_str}abcde12345"
    pure_str=$(echo -n "$pure_str" | head -c 32)
    echo -n "$pure_str" | base64 | tr -d '\n'
}

random_port() { shuf -i 2000-65000 -n 1; }
get_system_dns() { grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd "," - || echo "1.1.1.1"; }

validate_password() {
    local password="$1"
    if ! echo "$password" | base64 -d >/dev/null 2>&1; then
        echo -e "${RED}密码不是合法 Base64${RESET}"
        return 1
    fi
    
    local decoded_len
    decoded_len=$(echo "$password" | base64 -d 2>/dev/null | wc -c || echo "0")
    if [[ "$decoded_len" -ne "$KEY_BYTES" ]]; then
        echo -e "${RED}密码必须为 ${KEY_BYTES} 字节 (当前解密后为 ${decoded_len} 字节)${RESET}"
        return 1
    fi
    return 0
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "x86_64-unknown-linux-gnu" ;;
        aarch64) echo "aarch64-unknown-linux-gnu" ;;
        *) echo -e "${RED}不支持架构: $(uname -m)${RESET}" && exit 1 ;;
    esac
}

detect_stls_arch() {
    case "$(uname -m)" in
        x86_64)  echo "x86_64-unknown-linux-musl" ;;
        aarch64) echo "aarch64-unknown-linux-musl" ;;
        *) echo -e "${RED}不支持架构: $(uname -m)${RESET}" && exit 1 ;;
    esac
}

get_latest_version() {
    curl -fsSL --max-time 5 "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" 2>/dev/null | grep tag_name | cut -d '"' -f4 | sed 's/v//' || echo "1.18.4"
}

get_latest_stls_version() {
    curl -fsSL --max-time 5 "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" 2>/dev/null | grep tag_name | cut -d '"' -f4 || echo "v0.2.25"
}

# ================== 安全的数据提取引擎 ==================
load_existing_config() {
    OLD_STLS_PORT="8443"
    OLD_SS_PORT=""
    OLD_SS_PWD=""
    OLD_STLS_PWD=""
    OLD_STLS_SNI="captive.apple.com"
    OLD_DNS=""

    if [[ -f "$SS_Conf" ]]; then
        OLD_SS_PORT=$(awk -F: '/server_port/{print $2}' "$SS_Conf" 2>/dev/null | tr -d ' ,"\t\n' || echo "")
        OLD_SS_PWD=$(awk -F'"' '/password/{print $4}' "$SS_Conf" 2>/dev/null | tr -d '\n' || echo "")
        OLD_DNS=$(awk '/nameserver/{flag=1;next} /]/{flag=0} flag' "$SS_Conf" 2>/dev/null | grep -oE '[0-9.]+' | paste -sd "," - || echo "")
    fi

    if [[ -f "$STLS_Env" ]]; then
        OLD_STLS_PORT=$(awk -F'=' '/^STLS_LISTEN=/{print $2}' "$STLS_Env" 2>/dev/null | awk -F':' '{print $NF}' | tr -d '\r\n' || echo "8443")
        OLD_STLS_PWD=$(awk -F'=' '/^STLS_PASSWORD=/{print $2}' "$STLS_Env" 2>/dev/null | tr -d '\r\n' || echo "")
        
        local raw_tls
        raw_tls=$(awk -F'=' '/^STLS_TLS=/{print $2}' "$STLS_Env" 2>/dev/null | tr -d '\r\n' || echo "")
        if [[ -n "$raw_tls" ]]; then
            OLD_STLS_SNI=${raw_tls%:[0-9]*}
        fi
        [[ -z "$OLD_STLS_SNI" ]] && OLD_STLS_SNI="captive.apple.com"
    fi
    return 0
}

# ================== 写配置核心引擎 ==================
write_config() {
    local ss_port="$1"
    local password="$2"
    local dns="$3"
    local stls_port="$4"
    local stls_sni="$5"
    local stls_pwd="$6"

    mkdir -p "$SS_DIR"

    local dns_json=""
    IFS=',' read -r -a dns_arr <<< "$dns"
    for item in "${dns_arr[@]}"; do
        item=$(echo "$item" | xargs)
        if [[ -n "$dns_json" ]]; then dns_json+=", "; fi
        dns_json+="\"$item\""
    done

    cat > "$SS_Conf" <<EOF
{
    "server": "127.0.0.1",
    "server_port": $ss_port,
    "password": "$password",
    "method": "$METHOD",
    "fast_open": true,
    "mode": "tcp_and_udp",
    "timeout": 300,
    "no_delay": true,
    "ipv6_first": false,
    "nameserver": [
        $dns_json
    ]
}
EOF
    chmod 600 "$SS_Conf"

    cat > "$STLS_Env" <<EOF
STLS_LISTEN=[::]:$stls_port
STLS_SERVER=127.0.0.1:$ss_port
STLS_TLS=$stls_sni:443
STLS_PASSWORD=$stls_pwd
EOF
    chmod 600 "$STLS_Env"
}

# ================== 生成并保存链接 ==================
generate_links() {
    local ss_port="$1"
    local password="$2"
    local stls_port="$3"
    local stls_sni="$4"
    local stls_pwd="$5"

    IP=$(get_public_ip)
    HOSTNAME=$(hostname -s 2>/dev/null | sed 's/ /_/g' || echo "server")
    
    SS_BASE=$(echo -n "${METHOD}:${password}" | base64 -w 0)
    SHADOWTLS_JSON="{\"version\":\"3\",\"password\":\"${stls_pwd}\",\"host\":\"${stls_sni}\"}"
    SHADOWTLS_BASE=$(echo -n "$SHADOWTLS_JSON" | base64 -w 0)

    cat > "${SS_DIR}/ss.txt" <<EOF
ss://${SS_BASE}@${IP}:${stls_port}?shadow-tls=${SHADOWTLS_BASE}#$HOSTNAME-Shadowsocks+ShadowTLS
EOF

    cat > "${SS_DIR}/surge.txt" <<EOF
$HOSTNAME-Shadowsocks+ShadowTLS = ss, $IP, $stls_port, encrypt-method=$METHOD, password=$password, shadow-tls-password=$stls_pwd, shadow-tls-sni=$stls_sni, shadow-tls-version=3, tfo=true, udp-relay=true, ecn=true
EOF
}

# ================== 构建系统自启动服务 ==================
service() {
    cat > /etc/systemd/system/ss-rusts.service <<EOF
[Unit]
Description=Shadowsocks Rust Service (Custom s)
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Group=root
LimitNOFILE=51200
Restart=on-failure
RestartSec=5s
ExecStart=${SS_File} -c ${SS_Conf}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now ss-rusts || true
}

service_stls() {
    cat > /etc/systemd/system/shadowtlss.service <<-EOF
[Unit]
Description=Shadow TLS Service (Custom s)
After=network-online.target ss-rusts.service
Wants=network-online.target systemd-networkd-wait-online.service ss-rusts.service

[Service]
Type=simple
User=root
Group=root
LimitNOFILE=51200
Restart=on-failure
RestartSec=5s
Environment=MONOIO_FORCE_LEGACY_DRIVER=1
EnvironmentFile=${STLS_Env}
ExecStart=${STLS_File} --v3 server --listen \$STLS_LISTEN --server \$STLS_SERVER --tls \$STLS_TLS --password \$STLS_PASSWORD

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now shadowtlss || true
    echo -e "${Info} 服务部署自启配置完成！"
}

# ================== 打印配置详情 ==================
print_node_info() {
    IP=$(get_public_ip)
    if [[ ! -f "$STLS_Env" ]] || [[ ! -f "$SS_Conf" ]]; then
        echo -e "${RED}配置文件不存在，请先选择选项【1】进行安装初始化。${RESET}" && return
    fi
    
    local ss_port=$(awk -F: '/server_port/{print $2}' "$SS_Conf" 2>/dev/null | tr -d ' ,"\t\n' || echo "未知")
    local password=$(awk -F'"' '/password/{print $4}' "$SS_Conf" 2>/dev/null | tr -d '\n' || echo "未知")
    
    local show_listen_port=$(awk -F'=' '/^STLS_LISTEN=/{print $2}' "$STLS_Env" 2>/dev/null | awk -F':' '{print $NF}' | tr -d '\r\n' || echo "未知")
    local stls_pwd=$(awk -F'=' '/^STLS_PASSWORD=/{print $2}' "$STLS_Env" 2>/dev/null | tr -d '\r\n' || echo "未知")
    
    local raw_tls b_sni="未知"
    raw_tls=$(awk -F'=' '/^STLS_TLS=/{print $2}' "$STLS_Env" 2>/dev/null | tr -d '\r\n' || echo "")
    if [[ -n "$raw_tls" ]]; then
        b_sni=${raw_tls%:[0-9]*}
    fi

    echo -e "${GREEN}====== Shadowsocks + Shadow-TLS 配置 ======${RESET}"
    echo -e "${YELLOW} 公网 IP 地址   : ${IP}${RESET}"
    echo -e "${YELLOW} 外网公网端口   : ${show_listen_port}${RESET}"
    echo -e "${YELLOW} Shadow-TLS 密码 : ${stls_pwd}${RESET}"
    echo -e "${YELLOW} SNI 伪装域名    : ${b_sni}${RESET}"
    echo -e "${YELLOW} SS内部隔离端口  : ${ss_port} ${RESET}"
    echo -e "${YELLOW} SS 密码        : ${password}${RESET}"
    echo -e "${YELLOW} 加密方式        : ${METHOD}${RESET}"
    echo -e "${YELLOW}-------------------------------------------------${RESET}"
    echo -e "${GREEN}[信息] SS 链接：${RESET}"
    if [[ -f "${SS_DIR}/ss.txt" ]]; then
        echo -e "${YELLOW}$(cat "${SS_DIR}/ss.txt")${RESET}"
    else
        echo "未生成链接"
    fi
    echo -e ""
    echo -e "${GREEN}[信息] Surge配置:${RESET}"
    if [[ -f "${SS_DIR}/surge.txt" ]]; then
        echo -e "${YELLOW}$(cat "${SS_DIR}/surge.txt")${RESET}"
    else
        echo "未生成配置"
    fi
    echo -e "${YELLOW}-------------------------------------------------${RESET}"
}

# ================== 动态配置交互流 ==================
execute_configuration_flow() {
    local is_modify_mode="$1"
    
    load_existing_config || true
    
    local ss_port password dns stls_port stls_sni stls_pwd
    local input_stls_port input_ss_port input_password input_stls_pwd input_sni input_dns

    while true; do
        if [ "$is_modify_mode" = true ]; then
            printf "请输入Shadow-TLS公网端口 (当前: %s, 回车保持不修改): " "${OLD_STLS_PORT:-8443}"
        else
            printf "请输入Shadow-TLS公网端口 (默认: %s, 回车直接采纳): " "${OLD_STLS_PORT:-8443}"
        fi
        read -r input_stls_port || input_stls_port=""
        stls_port=${input_stls_port:-${OLD_STLS_PORT:-8443}}

        if [[ "$stls_port" =~ ^[0-9]+$ ]] && [ "$stls_port" -ge 1 ] && [ "$stls_port" -le 65535 ]; then
            if [ "$stls_port" != "$OLD_STLS_PORT" ]; then
                check_port "$stls_port" || continue
            fi
            break
        else
            echo -e "${RED}端口格式不正确，必须在 1-65535 之间。${RESET}"
        fi
    done

    while true; do
        local default_ss_port=""
        default_ss_port=${OLD_SS_PORT:-$(random_port || echo "49152")}
        
        if [ "$is_modify_mode" = true ]; then
            printf "请输入内部SS端口 (当前: %s, 回车保持不修改): " "$default_ss_port"
        else
            printf "请输入内部SS端口 (随机推荐: %s, 回车直接采纳): " "$default_ss_port"
        fi
        read -r input_ss_port || input_ss_port=""
        ss_port=${input_ss_port:-$default_ss_port}

        if [[ "$ss_port" =~ ^[0-9]+$ ]] && [ "$ss_port" -ge 1 ] && [ "$ss_port" -le 65535 ]; then
            if [ "$ss_port" -eq "$stls_port" ]; then
                echo -e "${RED}内部SS端口绝不能与外网公网端口相同！${RESET}"
                continue
            fi
            if [ "$ss_port" != "$OLD_SS_PORT" ]; then
                check_port "$ss_port" || continue
            fi
            break
        else
            echo -e "${RED}端口格式不正确，必须在 1-65535 之间。${RESET}"
        fi
    done

    while true; do
        local default_ss_pwd=""
        default_ss_pwd=${OLD_SS_PWD:-$(random_key || echo "")}

        if [ "$is_modify_mode" = true ]; then
            printf "请输入SS密码 (当前: %s, 回车保持不修改):\n> " "$default_ss_pwd"
        else
            printf "请输入SS密码 (默认随机生成: %s, 回车直接采纳):\n> " "$default_ss_pwd"
        fi
        read -r input_password || input_password=""
        password=${input_password:-$default_ss_pwd}

        if validate_password "$password"; then
            break
        fi
    done

    while true; do
        local default_stls_pwd=""
        # 核心修改：Shadow-TLS 默认随机密码改为 16 位纯数字与十六进制字母组合，绝无符号
        default_stls_pwd=${OLD_STLS_PWD:-$(openssl rand -hex 8 2>/dev/null || echo "StlsPurePwd123456")}
        
        if [ "$is_modify_mode" = true ]; then
            printf "请输入Shadow-TLS密码 (当前: %s, 回车保持不修改): " "$default_stls_pwd"
        else
            printf "请输入Shadow-TLS密码 (默认随机生成: %s, 回车直接采纳): " "$default_stls_pwd"
        fi
        read -r input_stls_pwd || input_stls_pwd=""
        stls_pwd=${input_stls_pwd:-$default_stls_pwd}
        if [[ -n "$stls_pwd" ]]; then
            break
        else
            echo -e "${RED}密码不能为空！${RESET}"
        fi
    done

    while true; do
        local default_sni=${OLD_STLS_SNI:-"captive.apple.com"}
        if [ "$is_modify_mode" = true ]; then
            printf "请输入Shadow-TLS SNI伪装域名 (当前: %s, 回车保持不修改): " "$default_sni"
        else
            printf "请输入Shadow-TLS SNI伪装域名 (默认: %s, 回车直接采纳): " "$default_sni"
        fi
        read -r input_sni || input_sni=""
        stls_sni=${input_sni:-$default_sni}
        if [[ "$stls_sni" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        else
            echo -e "${RED}伪装域名格式不正确，请输入合法的域名 (如 gateway.icloud.com)${RESET}"
        fi
    done

    while true; do
        local sys_dns=""
        sys_dns=$(get_system_dns || echo "1.1.1.1")
        local default_dns=${OLD_DNS:-$sys_dns}
        
        if [ "$is_modify_mode" = true ]; then
            printf "请输入SS内部自定义DNS (当前: %s, 回车保持不修改): " "$default_dns"
        else
            printf "请输入SS内部自定义DNS (默认采纳系统: %s, 回车直接采纳): " "$default_dns"
        fi
        read -r input_dns || input_dns=""
        dns=${input_dns:-$default_dns}
        if [[ -n "$dns" ]]; then
            break
        else
            echo -e "${RED}DNS 不能为空！${RESET}"
        fi
    done

    write_config "$ss_port" "$password" "$dns" "$stls_port" "$stls_sni" "$stls_pwd" || true
    generate_links "$ss_port" "$password" "$stls_port" "$stls_sni" "$stls_pwd" || true
}

# ================== 安装入口 ==================
install_ss() {
    echo -e "${GREEN}[信息] 开始全新安装 Shadowsocks-Rust & Shadow-TLS 核心组件...${RESET}"
    check_deps
    mkdir -p "$SS_DIR"
    cd "$TMP_DIR"

    VERSION=$(get_latest_version)
    ARCH=$(detect_arch)
    echo -e "${GREEN}[信息] 正在下载 Shadowsocks-Rust v${VERSION}...${RESET}"
    wget -O ss.tar.xz "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${VERSION}/shadowsocks-v${VERSION}.${ARCH}.tar.xz"
    tar -xf ss.tar.xz && install -m 755 ssserver "$SS_File"
    echo "$VERSION" > "${SS_DIR}/version.txt"

    STLS_VERSION=$(get_latest_stls_version)
    STLS_ARCH=$(detect_stls_arch)
    echo -e "${GREEN}[信息] 正在下载 Shadow-TLS ${STLS_VERSION}...${RESET}"
    wget -O shadow-tls "https://github.com/ihciah/shadow-tls/releases/download/${STLS_VERSION}/shadow-tls-${STLS_ARCH}"
    install -m 755 shadow-tls "$STLS_File"
    echo "$STLS_VERSION" > "${SS_DIR}/stls_version.txt"

    execute_configuration_flow false
    service
    service_stls

    echo -e "${GREEN}[完成] 服务安装部署成功，节点已启动运行！${RESET}"
    log "全新安装并初始化成功"
    print_node_info
}

# ================== 修改现有配置 ==================
modify_ss() {
    echo -e "${GREEN}[信息] 进入修改配置模块...${RESET}"
    if [[ ! -f "$SS_Conf" ]] || [[ ! -f "$STLS_Env" ]]; then
        echo -e "${RED}错误：未检测到环境配置文件，请先选择选项【1】进行完整安装！${RESET}"
        return
    fi
    
    execute_configuration_flow true
    
    echo -e "${GREEN}[管理] 正在安全平滑重启底层内核服务...${RESET}"
    systemctl restart ss-rusts || true
    service_stls
    systemctl restart shadowtlss || true
    
    echo -e "${GREEN}[完成] 核心配置已被覆写，服务重启完毕！${RESET}"
    print_node_info
    log "配置已被修改并安全应用"
}

# ================== 日志查看菜单 ==================
show_log_menu() {
    while true; do
        clear
        echo -e "${GREEN}===========================================${RESET}"
        echo -e "${GREEN}             日志查看分类菜单              ${RESET}"
        echo -e "${GREEN}===========================================${RESET}"
        echo -e "${YELLOW}1. 查看 Shadow-TLS 运行日志 (最新50条)${RESET}"
        echo -e "${YELLOW}2. 实时追踪 Shadow-TLS 日志 (Ctrl+C 退出)${RESET}"
        echo -e "${YELLOW}3. 查看 Shadowsocks-Rust 运行日志 (最新50条)${RESET}"
        echo -e "${YELLOW}4. 实时追踪 Shadowsocks-Rust 日志 (Ctrl+C 退出)${RESET}"
        echo -e "${YELLOW}0. 返回主菜单${RESET}"
        echo -e "${GREEN}===========================================${RESET}"
        
        local sub_choice
        read -r -p $'\033[32m请输入选项: \033[0m' sub_choice || true
        case $sub_choice in
            1) journalctl -u shadowtlss -n 50 --no-pager || true; pause ;;
            2) journalctl -u shadowtlss -f || true ;;
            3) journalctl -u ss-rusts -n 50 --no-pager || true; pause ;;
            4) journalctl -u ss-rusts -f || true ;;
            0) break ;;
            *) echo -e "${RED}无效输入${RESET}"; sleep 1 ;;
        esac
    done
}

# ================== 更新 ==================
update_ss() {
    echo -e "${GREEN}[信息] 开始更新二进制组件...${RESET}"
    cd "$TMP_DIR"
    
    if [[ -f "$SS_Conf" ]]; then
        VERSION=$(get_latest_version)
        ARCH=$(detect_arch)
        wget -O ss.tar.xz "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${VERSION}/shadowsocks-v${VERSION}.${ARCH}.tar.xz"
        tar -xf ss.tar.xz && install -m 755 ssserver "$SS_File"
        echo "$VERSION" > "${SS_DIR}/version.txt"
    fi

    if [[ -f "$STLS_Env" ]]; then
        STLS_VERSION=$(get_latest_stls_version)
        STLS_ARCH=$(detect_stls_arch)
        wget -O shadow-tls "https://github.com/ihciah/shadow-tls/releases/download/${STLS_VERSION}/shadow-tls-${STLS_ARCH}"
        install -m 755 shadow-tls "$STLS_File"
        echo "$STLS_VERSION" > "${SS_DIR}/stls_version.txt"
    fi

    service_stls
    systemctl restart ss-rusts shadowtlss || true
    echo -e "${GREEN}[完成] 更新执行完毕，服务已安全重启${RESET}"
    log "更新组件成功"
}

# ================== 卸载 ==================
uninstall_ss() {
    echo -e "${RED}[警告] 正在卸载独立一体化服务...${RESET}"
    systemctl stop shadowtlss ss-rusts || true
    systemctl disable shadowtlss ss-rusts || true
    rm -f /etc/systemd/system/ss-rusts.service /etc/systemd/system/shadowtlss.service
    rm -rf "$SS_DIR"
    rm -f "$SS_File" "$STLS_File"
    systemctl daemon-reload
    echo -e "${GREEN}[完成] 卸载清理完毕${RESET}"
    log "安全卸载成功"
}

# ================== 主菜单面板 ==================
show_menu() {
    clear
    local status_ss="${RED}● SS未运行${RESET}"
    local status_stls="${RED}● TLS未运行${RESET}"
    systemctl is-active --quiet ss-rusts && status_ss="${GREEN}● SS运行中${RESET}"
    systemctl is-active --quiet shadowtlss && status_stls="${GREEN}● TLS运行中${RESET}"

    local v_ss="未安装" && [[ -f "${SS_DIR}/version.txt" ]] && v_ss="v$(cat "${SS_DIR}/version.txt")"
    local v_stls="未安装" && [[ -f "${SS_DIR}/stls_version.txt" ]] && v_stls="$(cat "${SS_DIR}/stls_version.txt")"
    # 动态抓取双端口，并在主菜单进行合并显化展示
    local p_stls="-"
    if [[ -f "$STLS_Env" ]]; then 
        p_stls=$(awk -F'=' '/^STLS_LISTEN=/{print $2}' "$STLS_Env" 2>/dev/null | awk -F':' '{print $NF}' | tr -d '\r\n' || echo "-")
    fi
    local p_ss="-"
    if [[ -f "$SS_Conf" ]]; then
        p_ss=$(awk -F: '/server_port/{print $2}' "$SS_Conf" 2>/dev/null | tr -d ' ,"\t\n' || echo "-")
    fi

    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}    Shadowsocks + Shadow-TLS 管理面板     ${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}服务状态 :${RESET} ${status_ss} | ${status_stls}"
    echo -e "${GREEN}组件版本 :${RESET} ${YELLOW}SS: ${v_ss}${RESET} | ${YELLOW}Shadow-TLS: ${v_stls}${RESET}"
    echo -e "${GREEN}运行端口 :${RESET} ${YELLOW}外网(TLS): ${p_stls}${RESET} | ${YELLOW}内部(SS): ${p_ss}${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
    echo -e "${GREEN}1. 安装 Shadowsocks + Shadow-TLS ${RESET}"
    echo -e "${GREEN}2. 更新 Shadowsocks + Shadow-TLS ${RESET}"
    echo -e "${GREEN}3. 卸载 Shadowsocks + Shadow-TLS ${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 Shadowsocks + Shadow-TLS ${RESET}"
    echo -e "${GREEN}6. 停止 Shadowsocks + Shadow-TLS ${RESET}"
    echo -e "${GREEN}7. 重启 Shadowsocks + Shadow-TLS ${RESET}"
    echo -e "${GREEN}8. 查看运行日志${RESET}"
    echo -e "${GREEN}9. 查看节点配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}===========================================${RESET}"
}

# ================== 主循环 ==================
while true; do
    show_menu
    read -r -p $'\033[32m请输入选项: \033[0m' choice || true
    case $choice in
        1) install_ss; pause ;;
        2) update_ss; pause ;;
        3) uninstall_ss; pause ;;
        4) modify_ss; pause ;;
        5) systemctl start ss-rusts shadowtlss || true; echo -e "${GREEN}[完成] 服务已启动${RESET}"; pause ;;
        6) systemctl stop shadowtlss ss-rusts || true; echo -e "${GREEN}[完成] 服务已停止${RESET}"; pause ;;
        7) systemctl restart ss-rusts shadowtlss || true; echo -e "${GREEN}[完成] 服务已重启${RESET}"; pause ;;
        8) show_log_menu ;;
        9) print_node_info; pause ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${RESET}" ; pause ;;
    esac
done
