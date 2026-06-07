#!/bin/bash

# 全局高优先环境变量配置
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 颜色控制 - 统一调整为绿色系列
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
LIGHT_GREEN='\033[1;32m'
NC='\033[0m'

CONFIG_FILE="/etc/snapshot_config.conf"
SERVICE_NAME="system-snapshot"
LOG_FILE="/var/log/snapshot_info.log"

# 完全固定本地路径与脚本名称
ADMIN_SCRIPT="/usr/bin/snapshot.sh"

if [ "$EUID" -ne 0 ]; then 
    echo -e "${GREEN}错误: 请使用 root 权限运行此脚本。${NC}"
    exit 1
fi

# ==============================================================================
# Alpine 专属：绝对首次运行下载逻辑
# ==============================================================================
if [ -f "$ADMIN_SCRIPT" ]; then
    if [ "$(readlink -f "$0" 2>/dev/null)" != "$ADMIN_SCRIPT" ]; then
        exec "$ADMIN_SCRIPT" "$@"
    fi
else
    # 针对 Alpine 优化，首次运行时强制先安装最基础的 curl 确保能拉取脚本
    if ! command -v curl &>/dev/null; then
        apk update && apk add curl &>/dev/null
    fi
    curl -sL https://raw.githubusercontent.com/iu683/uu/main/oo.sh > "$ADMIN_SCRIPT"
    if [ $? -eq 0 ] && [ -s "$ADMIN_SCRIPT" ]; then
        chmod +x "$ADMIN_SCRIPT"
        hash -r
        exec "$ADMIN_SCRIPT" "$@"
    else
        echo -e "${GREEN}警告: 自动下载失败，请检查网络是否能正常访问 GitHub。...${NC}"
    fi
fi

# TG 消息 Markdown 专用转义函数
escape_markdown() {
    echo -ne "$1" | sed 's/\([\._\*\[\]()~`#>+\-=|{}!]\)/\\\1/g'
}

# 发送美化版 Telegram 通知的核心公共函数
send_tg_notification() {
    local token="$1" local chat="$2" local md_text="$3"
    if [ -n "$token" ] && [ -n "$chat" ]; then
        curl -s -X POST "https://api.telegram.org/bot$token/sendMessage" \
            -d chat_id="$chat" \
            -d text="$md_text" \
            -d parse_mode="MarkdownV2" &>/dev/null
    fi
}

# ==============================================================================
# 模块一：后端静默备份与远程传输逻辑
# ==============================================================================
run_backend_backup() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "错误: 配置文件不存在，请先运行脚本进行安装与配置。"
        exit 1
    fi
    source "$CONFIG_FILE"
    
    # 建立前端运行与后台静默的展示区分
    local is_interactive=0
    if [ "$2" == "--interactive" ]; then is_interactive=1; fi

    TIMESTAMP=$(date +"%Y%m%d%H%M%S")
    mkdir -p "$BACKUP_DIR"
    SNAPSHOT_FILE="$BACKUP_DIR/system_snapshot_${TIMESTAMP}.tar.gz"
    FULL_REMOTE_PATH="$TARGET_BASE_DIR/$REMOTE_DIR_NAME"

    touch "$LOG_FILE"
    log_info() { echo "$(date '+%F %T') [INFO] $1" >> "$LOG_FILE"; }
    log_error() { echo "$(date '+%F %T') [ERROR] $1" >> "$LOG_FILE"; }

    log_info "========== 开始执行系统快照备份任务 =========="
    
    # 转义通知
    local t_name=$(escape_markdown "${REMOTE_DIR_NAME:-未配置}")
    local t_path=$(escape_markdown "${FULL_REMOTE_PATH:-未配置}")
    local t_time=$(escape_markdown "$(date '+%Y-%m-%d %H:%M:%S')")
    
    local start_msg="🚀 *系统快照备份任务启动*

🖥️ *本机名称*: \`$t_name\`  
🌐 *远程路径*: \`$t_path\`
⏱️ *开始时间*: \`$t_time\`"
    send_tg_notification "$BOT_TOKEN" "$CHAT_ID" "$start_msg"

    if [ $is_interactive -eq 1 ]; then
        echo -e "${GREEN}正在打包本地核心系统文件，请稍候...${NC}"
    fi

    # 系统核心打包 (使用 GNU tar 屏蔽无关动态目录及快照自身)
    tar -czf "$SNAPSHOT_FILE" \
      --exclude="/dev/*" --exclude="/proc/*" --exclude="/sys/*" --exclude="/tmp/*" --exclude="/run/*" \
      --exclude="/mnt/*" --exclude="/media/*" --exclude="/lost+found" --exclude="/var/cache/*" \
      --exclude="/var/tmp/*" --exclude="/var/log/*" \
      --exclude="${BACKUP_DIR}/*" \
      /boot /etc /usr /var /root /home /opt /bin /sbin /lib /lib64 > /dev/null 2>&1

    if [ $? -eq 0 ] || [ -s "$SNAPSHOT_FILE" ]; then
        SNAPSHOT_SIZE=$(du -h "$SNAPSHOT_FILE" | cut -f1)
        log_info "本地快照创建成功，大小: $SNAPSHOT_SIZE"
        
        log_info "正在通过 SSH 自动创建远程多级备份目录结构..."
        ssh -p "$SSH_PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$TARGET_USER@$TARGET_IP" "mkdir -p \"$FULL_REMOTE_PATH/system_snapshots\"" &>/dev/null
        
        log_info "正在通过 rsync 安全传输快照至远程服务器..."
        
        if [ $is_interactive -eq 1 ]; then
            echo -e "${GREEN}正在同步快照至远程服务器（展示实时进度）：${NC}"
            rsync -avz --progress --inplace --rsync-path="mkdir -p $FULL_REMOTE_PATH/system_snapshots && rsync" -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=no" "$SNAPSHOT_FILE" "$TARGET_USER@$TARGET_IP:$FULL_REMOTE_PATH/system_snapshots/"
            local sync_res=$?
        else
            rsync -avz --inplace --rsync-path="mkdir -p $FULL_REMOTE_PATH/system_snapshots && rsync" -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=no" "$SNAPSHOT_FILE" "$TARGET_USER@$TARGET_IP:$FULL_REMOTE_PATH/system_snapshots/" &>/dev/null
            local sync_res=$?
        fi
        
        if [ $sync_res -eq 0 ]; then
            log_info "远程同步成功！文件已安全留存远端。"
            ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no "$TARGET_USER@$TARGET_IP" "find \"$FULL_REMOTE_PATH/system_snapshots\" -type f -name '*.tar.gz' -mtime +$REMOTE_SNAPSHOT_DAYS -delete" &>/dev/null
            
            # 定时清理本地过期快照 (使用 GNU findutils 确保 maxdepth 兼容)
            find "$BACKUP_DIR" -maxdepth 1 -type f -name "system_snapshot_*.tar.gz" | sort -r | tail -n +$((LOCAL_SNAPSHOT_KEEP+1)) | xargs -r rm -f
            log_info "过期快照轮转清理完毕。"

            local local_count=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "system_snapshot_*.tar.gz" | wc -l)
            
            # 组装成功的美化 TG 消息
            local e_size=$(escape_markdown "$SNAPSHOT_SIZE")
            local e_count=$(escape_markdown "$local_count")
            local e_days=$(escape_markdown "$REMOTE_SNAPSHOT_DAYS")
            local e_ldir=$(escape_markdown "$BACKUP_DIR")
            local e_endtime=$(escape_markdown "$(date '+%Y-%m-%d %H:%M:%S')")

            local success_msg="✅ *系统快照备份任务已圆满完成*

🖥️ *本机名称*: \`$t_name\`
💾 *快照大小*: \`$e_size\`
⏱️ *完成时间*: \`$e_endtime\`
📂 *本地快照*: \`$e_count个\`
☁️ *远程保留*: \`$e_days天\`
💾 *本地路径*: \`$e_ldir\`
📁 *远程路径*: \`$t_path\`"
            send_tg_notification "$BOT_TOKEN" "$CHAT_ID" "$success_msg"
            log_info "========== 快照备份任务顺利结束 =========="
        else
            log_error "远程传输失败！原因：无法连接或没有免密授权"
            local fail_msg="❌ *系统快照远程传输失败*

🖥️ *本机名称*: \`$t_name\`
⏱️ *发生时间*: \`$t_time\`
⚠️ *错误原因*: 远程同步网络中断或 SSH 密钥授信失效，快照仅暂存于本地落盘目录。"
            send_tg_notification "$BOT_TOKEN" "$CHAT_ID" "$fail_msg"
        fi
    else
        log_error "快照打包失败！"
    fi
    if [ $is_interactive -eq 0 ]; then exit 0; fi
}

# 检测由 OpenRC/Cron 后端运行触发
if [ "$1" == "--backend-run" ]; then
    run_backend_backup "$@"
fi

# ==============================================================================
# 模块二：前端交互式菜单与控制台逻辑
# ==============================================================================
read_with_default() {
    local prompt="$1" local default_value="$2" local var_name="$3" local input_value
    if [ -n "$default_value" ]; then
        read -p "$(echo -e "${prompt} [当前值/默认: ${GREEN}${default_value}${NC}]: ")" input_value
        if [ -z "$input_value" ]; then eval "$var_name=\"\$default_value\""; else eval "$var_name=\"\$input_value\""; fi
    else
        read -p "$(echo -e "${prompt}: ")" input_value
        if [ -z "$input_value" ] && [ "$var_name" == "NEW_TARGET_USER" ]; then
            eval "$var_name=\"root\""
        else
            while [ -z "$input_value" ]; do
                echo -e "${GREEN}该项不能为空，请输入有效值${NC}"
                read -p "$(echo -e "${prompt}: ")" input_value
            done
            eval "$var_name=\"\$input_value\""
        fi
    fi
}

load_config() { if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; fi; }

draw_header() {
    clear
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN}         系统快照备份工具         ${NC}"
    echo -e "${GREEN}=================================${NC}"
}

show_status_and_info() {
    load_config
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${GREEN}当前工具状态:${NC} ${YELLOW}[未安装]${NC}"
        echo -e "${GREEN}=================================${NC}"
        return 1
    fi
    
    # 【修复】关键匹配词对齐，在 crontabs 中精准匹配实际脚本名称 snapshot.sh
    local cron_active="未激活"
    if [ -f "/etc/periodic/daily/system-snapshot" ] || grep -q "snapshot.sh" /etc/crontabs/root 2>/dev/null; then
        if rc-service crond status &>/dev/null || rc-service dcron status &>/dev/null; then
            cron_active="运行中 (Cron)"
        else
            cron_active="已配置 (Cron服务未启动)"
        fi
    fi
    
    local last_run="无记录" local next_run="按周期自动触发"
    if [ -f "$LOG_FILE" ]; then
        local log_time=$(grep "快照备份任务顺利结束" "$LOG_FILE" | tail -n 1 | awk '{print $1,$2}')
        if [ -n "$log_time" ]; then
            last_run="$log_time"
            # 【终极修复】采用秒级时间戳加减，100% 解决 Alpine 极简 BusyBox 环境下 date 的日期加减灵异 Bug
            next_run=$(date -d "@$(($(date -d "$log_time" +"%s" 2>/dev/null || gdate -d "$log_time" +"%s") + ${BACKUP_INTERVAL_DAYS:-5} * 86400))" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
        fi
    fi
    
    local local_usage="0 MB" local local_count=0
    if [ -d "$BACKUP_DIR" ]; then
        local_count=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "system_snapshot_*.tar.gz" | wc -l)
        local_usage=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
    fi
    echo -e "${YELLOW}[ 自动化运行状态 ]${NC}"
    echo -e "${GREEN} 定时任务状态:${NC} ${YELLOW}${cron_active}${NC}"
    echo -e "${GREEN} 上次执行时间:${NC} ${YELLOW}${last_run}${NC}"
    echo -e "${GREEN} 下次预计执行:${NC} ${YELLOW}${next_run}${NC}"
    echo -e "${GREEN} 备份间隔天数:${NC} 每 ${YELLOW}${BACKUP_INTERVAL_DAYS:-'5'}${NC} 天自动触发一次"
    echo -e "${GREEN}=================================${NC}"
    echo -e "${YELLOW}[ 核心配置与数据信息 ]${NC}"
    echo -e "${GREEN} 本机标识名称:${NC} ${YELLOW}${REMOTE_DIR_NAME:-'未配置'}${NC}"
    echo -e "${GREEN} 远程存储目标:${NC} ${YELLOW}${TARGET_USER:-'N/A'}@${TARGET_IP:-'N/A'}:${SSH_PORT:-'22'}${NC}"
    echo -e "${GREEN} 远程基础路径:${NC} ${YELLOW}${TARGET_BASE_DIR:-'未配置'}${NC}"
    echo -e "${GREEN} 本地备份目录:${NC} ${YELLOW}${BACKUP_DIR:-'/backups'} ${NC}(共 ${YELLOW}${local_count}${NC} 个快照, 占用 ${YELLOW}${local_usage}${NC})"
    echo -e "${GREEN} 轮转策略留存:${NC} 本地 ${YELLOW}${LOCAL_SNAPSHOT_KEEP:-'2'}${NC} 个 | 远程 ${YELLOW}${REMOTE_SNAPSHOT_DAYS:-'15'}${NC} 天"
    echo -e "${GREEN}=================================${NC}"
    return 0
}

# Alpine 专属环境依赖补齐
check_requirements() {
    local missing_pkgs=""
    for pkg in curl openssh-client rsync tar gawk coreutils findutils; do
        if ! apk info -e $pkg &>/dev/null; then
            missing_pkgs="$missing_pkgs $pkg"
        fi
    done
    
    if [ -n "$missing_pkgs" ]; then
        echo -e "${GREEN}正在为 Alpine 补齐完整 GNU 核心工具链环境...${NC}"
        apk update && apk add $missing_pkgs &>/dev/null
    fi
}

auto_copy_ssh_key() {
    local ip="$1" local user="$2" local port="$3"
    local LOCAL_KEY="/root/.ssh/id_rsa.pub"

    if [ ! -f "$LOCAL_KEY" ]; then
        echo -e "${GREEN}未检测到本地公钥，正在生成新的 SSH 密钥对...${NC}"
        mkdir -p /root/.ssh && chmod 700 /root/.ssh
        ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" -q
        if [ $? -ne 0 ]; then
            echo -e "${GREEN}❌ 密钥生成失败，请检查 ssh-keygen 是否可用${NC}"
            return 1
        fi
        echo -e "${GREEN}✅ SSH 密钥生成完成: $LOCAL_KEY${NC}"
    else
        echo -e "${GREEN}✅ 已检测到本地公钥: $LOCAL_KEY${NC}"
    fi

    local PUBKEY_CONTENT=$(cat "$LOCAL_KEY")
    echo -e "${GREEN}⚠️ 第一次连接需要手动输入远程服务器密码进行鉴权操作${NC}"

    ssh -p "$port" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$user@$ip" "bash -s" <<EOF
        mkdir -p ~/.ssh
        chmod 700 ~/.ssh
        touch ~/.ssh/authorized_keys
        cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak
        if ! grep -Fxq "$PUBKEY_CONTENT" ~/.ssh/authorized_keys.bak; then
            echo "$PUBKEY_CONTENT" >> ~/.ssh/authorized_keys.bak
        fi
        awk '!seen[\$0]++' ~/.ssh/authorized_keys.bak > ~/.ssh/authorized_keys
        rm -f ~/.ssh/authorized_keys.bak
        chmod 600 ~/.ssh/authorized_keys
        chown \$(whoami):\$(id -gn) ~/.ssh ~/.ssh/authorized_keys
EOF

    if [ $? -ne 0 ]; then
        echo -e "${GREEN}❌ 远程操作失败，请检查网络连接、密码或端口是否正确。${NC}"
        return 1
    fi

    echo -e "\n${GREEN}📂 正在验证远程免密读取通道状态...${NC}"
    local verify_check=$(ssh -p "$port" -o ConnectTimeout=5 -o PasswordAuthentication=no -o StrictHostKeyChecking=no "$user@$ip" "cat ~/.ssh/authorized_keys" 2>/dev/null)
    
    if [ -n "$verify_check" ]; then
        echo -e "${GREEN}✅ 密钥同步结果最终验证通过！免密安全互信已成功建立。${NC}"
        return 0
    else
        echo -e "${GREEN}❌ 强校验错误: 密钥虽已传输，但当前机器仍无法进行免密登录。${NC}"
        return 1
    fi
}

# Alpine 专属：使用 OpenRC 服务守护以及标准的 Crontab 触发器
setup_alpine_cron() {
    # 1. 编写 OpenRC 行程服务 (供手动或临时管理接口调用)
    cat > "/etc/init.d/system-snapshot" << 'EOFSERVICE'
#!/sbin/openrc-run
description="System Snapshot Backup Service"
command="/usr/bin/snapshot.sh"
command_args="--backend-run"

depend() {
    need net
}
EOFSERVICE
    chmod +x /etc/init.d/system-snapshot

    # 2. 注入系统的 Crontab 定时器结构中
    # 清理历史可能存在的同名旧配置
    sed -i "/$SERVICE_NAME/d" /etc/crontabs/root 2>/dev/null
    sed -i "/snapshot.sh/d" /etc/crontabs/root 2>/dev/null
    
    # 生成随机执行小时数（0-4点）和分钟数（0-59），模拟原 Systemd 的 RandomizedDelaySec 削峰机制
    local rand_min=$((RANDOM % 60))
    local rand_hour=$((RANDOM % 5))
    
    # 写入 Alpine 的 crontabs 主配置 (每 X 天运行一次)
    echo "$rand_min $rand_hour */${NEW_BACKUP_INTERVAL_DAYS} * * $ADMIN_SCRIPT --backend-run >/dev/null 2>&1" >> /etc/crontabs/root
    
    # 重启并启动 Alpine 的 crond 调度服务
    rc-update add crond default &>/dev/null
    rc-service crond restart &>/dev/null
}

configure_project() {
    load_config
    check_requirements
    if [ -f "$CONFIG_FILE" ]; then echo -e "${GREEN}进入修改配置模式。回车直接保留原当前值：${NC}\n"
    else echo -e "${GREEN}进入首次安装配置向导。请输入以下参数：${NC}\n"; fi

    read_with_default "请输入 Telegram Bot Token" "$BOT_TOKEN" NEW_BOT_TOKEN
    read_with_default "请输入 Telegram Chat ID" "$CHAT_ID" NEW_CHAT_ID
    echo
    read_with_default "请输入远程服务器 IP 地址" "$TARGET_IP" NEW_TARGET_IP
    read_with_default "请输入远程服务器用户名 (默认: root)" "${TARGET_USER:-root}" NEW_TARGET_USER
    read_with_default "请输入 SSH 连接端口" "${SSH_PORT:-22}" NEW_SSH_PORT
    echo
    
    auto_copy_ssh_key "$NEW_TARGET_IP" "$NEW_TARGET_USER" "$NEW_SSH_PORT"
    if [ $? -ne 0 ]; then
        echo -e "\n${GREEN}由于免密授权未真正生效，配置流程已强行中断，未写入任何更改。${NC}"
        read -p "按任意键返回主菜单..." -n 1
        return 1
    fi
    echo
    
    read_with_default "请输入远程基础备份目录" "${TARGET_BASE_DIR:-/root/remote_backup}" NEW_TARGET_BASE_DIR
    local current_hostname=$(hostname)
    read_with_default "请输入本机在远程的子目录名" "${REMOTE_DIR_NAME:-$current_hostname}" NEW_REMOTE_DIR_NAME
    echo
    read_with_default "请输入本地快照落盘目录" "${BACKUP_DIR:-/backups}" NEW_BACKUP_DIR
    echo
    read_with_default "请输入本地最大保留快照数量(个)" "${LOCAL_SNAPSHOT_KEEP:-2}" NEW_LOCAL_SNAPSHOT_KEEP
    read_with_default "请输入远程快照过期删除时间(天)" "${REMOTE_SNAPSHOT_DAYS:-15}" NEW_REMOTE_SNAPSHOT_DAYS
    echo
    read_with_default "请输入备份执行间隔天数(1-30天)" "${BACKUP_INTERVAL_DAYS:-5}" NEW_BACKUP_INTERVAL_DAYS
    
    mkdir -p "$NEW_BACKUP_DIR"
    cat > "$CONFIG_FILE" << EOF
#!/bin/bash
BOT_TOKEN="$NEW_BOT_TOKEN"
CHAT_ID="$NEW_CHAT_ID"
TARGET_IP="$NEW_TARGET_IP"
TARGET_USER="$NEW_TARGET_USER"
SSH_PORT="$NEW_SSH_PORT"
TARGET_BASE_DIR="$NEW_TARGET_BASE_DIR"
REMOTE_DIR_NAME="$NEW_REMOTE_DIR_NAME"
BACKUP_DIR="$NEW_BACKUP_DIR"
LOCAL_SNAPSHOT_KEEP=$NEW_LOCAL_SNAPSHOT_KEEP
REMOTE_SNAPSHOT_DAYS=$NEW_REMOTE_SNAPSHOT_DAYS
BACKUP_INTERVAL_DAYS=$NEW_BACKUP_INTERVAL_DAYS
EOF
    chmod 600 "$CONFIG_FILE"
    
    setup_alpine_cron
    
    echo -e "\n${GREEN}✓ 全新配置和 Alpine Cron 自动化定时任务已同步刷新并生效！${NC}"
    read -p "按任意键返回主菜单..." -n 1
}

action_manual_backup() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${GREEN}错误: 请先进行配置再执行此操作。${NC}"; else
        echo -e "\n${GREEN}正在手动同步触发核心流程...${NC}"
        $ADMIN_SCRIPT --backend-run --interactive
        echo -e "${GREEN}✓ 手动打包传输完整。${NC}"
    fi
    read -p "按任意键返回主菜单..." -n 1
}

test_telegram() {
    if [ ! -f "$CONFIG_FILE" ]; then 
        echo -e "${GREEN}错误: 请先进行配置后再执行测试。${NC}"
        read -p "按任意键返回主菜单..." -n 1
        return 1
    fi
    source "$CONFIG_FILE"
    echo -e "\n${GREEN}正在发送 Telegram 控制台连通性测试消息...${NC}"
    
    local FULL_REMOTE_PATH="$TARGET_BASE_DIR/$REMOTE_DIR_NAME"
    
    local t_name=$(escape_markdown "${REMOTE_DIR_NAME:-未配置}")
    local t_path=$(escape_markdown "${FULL_REMOTE_PATH:-未配置}")
    local t_days=$(escape_markdown "${BACKUP_INTERVAL_DAYS:-5}")
    local t_time=$(escape_markdown "$(date '+%Y-%m-%d %H:%M:%S')")

    local test_msg="🚀 *系统快照备份工具 Alpine 安装测试*

📱 如果您看到此消息，说明Telegram配置成功！
🖥️ *本机名称*: \`$t_name\`  
🌐 *远程路径*: \`$t_path\`
⏰ *执行频率*: 每${t_days}天一次
⏱️ *时间*: \`$t_time\`"

    local response=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d text="$test_msg" \
        -d parse_mode="MarkdownV2")
        
    if [[ $response == *"\"ok\":true"* ]]; then
        echo -e "${GREEN}✓ Telegram 通知测试联通成功！请检查您的手机电报频道。${NC}\n"
    else
        echo -e "${GREEN}❌ 电报消息投递失败，请检查 Token / Chat ID 或者是机器出海网络代理。${NC}\n"
    fi
    read -p "按任意键返回主菜单..." -n 1
}

action_view_logs() {
    if [ -f "$LOG_FILE" ]; then 
        echo -e "\n${GREEN}正在加载最近的 15 条备份流日志：${NC}"
        tail -n 15 "$LOG_FILE"
    else echo -e "${GREEN}暂无备份任务的日志流产生。${NC}"; fi
    read -p "按任意键返回主菜单..." -n 1
}

uninstall_project() {
    sed -i "/$SERVICE_NAME/d" /etc/crontabs/root 2>/dev/null
    sed -i "/snapshot.sh/d" /etc/crontabs/root 2>/dev/null
    rc-service crond restart &>/dev/null
    rm -f /etc/init.d/system-snapshot
    rm -f "$CONFIG_FILE" "$ADMIN_SCRIPT"
    echo -e "${GREEN}✓ 快照工具及 Alpine 定时任务已从本机完全干净卸载。${NC}"
    exit 0
}

menu_loop() {
    while true; do
        draw_header
        show_status_and_info
        echo -e "${GREEN}  [1] 安装/修改配置${NC}"
        echo -e "${GREEN}  [2] 手动执行系统快照${NC}"
        echo -e "${GREEN}  [3] 测试Telegram连通性${NC}"
        echo -e "${GREEN}  [4] 查看系统备份日志${NC}"
        echo -e "${GREEN}  [5] 卸载备份工具${NC}"
        echo -e "${GREEN}  [0] 退出${NC}"
        echo -e "${GREEN}=================================${NC}"

        read -p $'\033[32m请选择操作编号: \033[0m' choice
        case $choice in
            1) configure_project ;;
            2) action_manual_backup ;;
            3) test_telegram ;;
            4) action_view_logs ;;
            5) uninstall_project ;;
            0) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

# 启动菜单主循环
menu_loop
