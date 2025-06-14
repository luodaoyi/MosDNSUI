#!/bin/bash

# MosDNS 独立监控面板 - 一键部署、更新、恢复脚本
# 作者：ChatGPT & JimmyDADA & Phil Horse
# 版本：9.0 (双版本管理最终版)
# 特点：
# - [重大] 支持同时部署和管理 "正式版" 与 "Beta测试版"，二者互不干扰。
# - [动态] 所有操作 (部署/卸载/更新/恢复) 都会根据用户选择的版本进行。
# - 保持了 Python 直启、外部下载、视觉美化等所有优点。

# --- 定义颜色和样式 ---
C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'; C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'; C_PURPLE='\033[0;35m'; C_BOLD='\033[1m'; C_NC='\033[0m';

# --- 辅助日志函数 ---
log_info() { echo -e "${C_GREEN}✔  [信息]${C_NC} $1"; }
log_warn() { echo -e "${C_YELLOW}⚠  [警告]${C_NC} $1"; }
log_error() { echo -e "${C_RED}✖  [错误]${C_NC} $1"; }
log_step() { echo -e "\n${C_PURPLE}🚀 [步骤 ${1}/${2}]${C_NC} ${C_BOLD}$3${C_NC}"; }
log_success() { echo -e "\n${C_GREEN}🎉🎉🎉 $1 🎉🎉🎉${C_NC}"; }
print_line() { echo -e "${C_BLUE}==================================================================${C_NC}"; }

# --- [修改] 全局变量现在是动态设置的 ---
FLASK_APP_NAME=""
PROJECT_DIR=""
BACKUP_DIR=""
UPLOAD_DIR=""
FLASK_PORT=""
SYSTEMD_SERVICE_FILE=""
APP_PY_URL=""
INDEX_HTML_URL=""
APP_PY_PATH=""
INDEX_HTML_PATH=""

# MosDNS 的地址是共享的
MOSDNS_ADMIN_URL="http://127.0.0.1:9099"
WEB_USER="www-data"

# [新] 版本配置函数
select_version() {
    local version_type=$1
    if [ "$version_type" == "beta" ]; then
        FLASK_APP_NAME="mosdns_monitor_panel_beta"
        FLASK_PORT=5002 # Beta版使用新端口
        APP_PY_URL="https://raw.githubusercontent.com/Jimmyzxk/MosDNSUI/main/Beta/app.py"
        INDEX_HTML_URL="https://raw.githubusercontent.com/Jimmyzxk/MosDNSUI/main/Beta/index.html"
    else # 默认为正式版
        FLASK_APP_NAME="mosdns_monitor_panel"
        FLASK_PORT=5001 # 正式版使用原端口
        APP_PY_URL="https://raw.githubusercontent.com/Jimmyzxk/MosDNSUI/main/app.py"
        INDEX_HTML_URL="https://raw.githubusercontent.com/Jimmyzxk/MosDNSUI/main/index.html"
    fi
    
    PROJECT_DIR="/opt/$FLASK_APP_NAME"
    BACKUP_DIR="$PROJECT_DIR/backups"
    UPLOAD_DIR="$PROJECT_DIR/uploads"
    SYSTEMD_SERVICE_FILE="/etc/systemd/system/$FLASK_APP_NAME.service"
    APP_PY_PATH="$PROJECT_DIR/app.py"
    INDEX_HTML_PATH="$PROJECT_DIR/templates/index.html"
}

# --- 辅助命令执行函数 (重构版) ---
run_command() {
    local message="$1"; shift
    printf "    %-55s" "$message"
    # shellcheck disable=SC2068
    ($@ &>/dev/null) &
    local pid=$!
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % ${#spin[@]} )); printf "${C_CYAN}%s${C_NC}" "${spin:$i:1}"; sleep 0.1; printf "\b";
    done
    wait $pid
    if [ $? -eq 0 ]; then echo -e "[ ${C_GREEN}成功${C_NC} ]"; return 0;
    else echo -e "[ ${C_RED}失败${C_NC} ]"; return 1; fi
}

# --- 所有核心函数现在都依赖于 select_version 设置的全局变量 ---

uninstall_monitor() {
    log_warn "正在卸载 ${FLASK_APP_NAME}..."
    run_command "停止并禁用服务" systemctl stop "$FLASK_APP_NAME" && systemctl disable "$FLASK_APP_NAME"
    run_command "移除服务文件" rm -f "$SYSTEMD_SERVICE_FILE" && systemctl daemon-reload
    run_command "移除项目目录" rm -rf "$PROJECT_DIR"
    log_success "卸载完成！"
}

deploy_monitor() {
    print_line; echo -e "${C_BLUE}  🚀  开始部署 ${C_BOLD}${FLASK_APP_NAME}${C_NC}  🚀${C_NC}"; print_line
    log_step 1 5 "环境检测与依赖安装"
    run_command "测试 MosDNS 接口..." curl --output /dev/null --silent --head --fail "$MOSDNS_ADMIN_URL/metrics" || { log_error "无法访问 MosDNS 接口。"; return 1; }
    if ! id -u "$WEB_USER" >/dev/null 2>&1; then run_command "创建系统用户 '$WEB_USER'..." adduser --system --no-create-home --group "$WEB_USER" || return 1; fi
    run_command "更新 apt 缓存..." apt-get update -qq
    run_command "安装系统依赖..." apt-get install -y python3 python3-pip python3-flask python3-requests python3-werkzeug curl wget || return 1
    
    log_step 2 5 "创建项目目录结构"
    run_command "创建所有目录..." mkdir -p "$PROJECT_DIR/templates" "$PROJECT_DIR/static" "$BACKUP_DIR" "$UPLOAD_DIR" || return 1
    
    log_step 3 5 "下载核心应用文件"
    run_command "下载 app.py..." wget -qO "$APP_PY_PATH" "$APP_PY_URL" || { log_error "下载 app.py 失败！"; return 1; }
    run_command "下载 index.html..." wget -qO "$INDEX_HTML_PATH" "$INDEX_HTML_URL" || { log_error "下载 index.html 失败！"; return 1; }
    run_command "设置文件权限..." chown -R "$WEB_USER:$WEB_USER" "$PROJECT_DIR" || return 1

    log_step 4 5 "创建并配置 Systemd 服务"
    local python_path; python_path=$(which python3)
    cat <<EOF > "$SYSTEMD_SERVICE_FILE"
[Unit]
Description=MosDNS Monitoring Panel (${FLASK_APP_NAME})
After=network.target
[Service]
User=$WEB_USER
Group=$WEB_USER
WorkingDirectory=$PROJECT_DIR
ExecStart=$python_path app.py
Environment="FLASK_PORT=$FLASK_PORT"
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    run_command "创建 Systemd 服务文件..." true

    log_step 5 5 "启动服务并设置开机自启"
    run_command "重载 Systemd..." systemctl daemon-reload || return 1
    run_command "启用服务..." systemctl enable "$FLASK_APP_NAME" || return 1
    run_command "重启服务..." systemctl restart "$FLASK_APP_NAME" || { log_error "服务启动失败！请检查日志。"; return 1; }
    
    local ip_addr; ip_addr=$(hostname -I | awk '{print $1}')
    print_line; log_success "部署完成！"
    echo -e "${C_CYAN}
    ┌──────────────────────────────────────────────────┐
    │                                                  │
    │   ${C_BOLD}${FLASK_APP_NAME}${C_NC} 已就绪！                      │
    │   请在浏览器中访问: ${C_BOLD}http://${ip_addr}:${FLASK_PORT}${C_NC} │
    │                                                  │
    └──────────────────────────────────────────────────┘
    ${C_NC}"
    return 0
}

update_app() {
    print_line; echo -e "${C_BLUE}  🔄  开始更新 ${C_BOLD}${FLASK_APP_NAME}${C_NC}  🔄${C_NC}"; print_line
    if [ ! -d "$PROJECT_DIR" ]; then log_error "项目目录不存在，请先部署。"; return 1; fi
    local timestamp; timestamp=$(date +"%Y%m%d-%H%M%S")
    local current_backup_dir="$BACKUP_DIR/$timestamp"
    
    run_command "创建备份目录..." mkdir -p "$current_backup_dir/templates" || return 1
    run_command "备份 app.py..." cp "$APP_PY_PATH" "$current_backup_dir/app.py" || return 1
    run_command "备份 index.html..." cp "$INDEX_HTML_PATH" "$current_backup_dir/templates/index.html" || return 1

    log_info "正在从 GitHub 下载最新版本..."
    run_command "下载新版 app.py..." wget -qO "$APP_PY_PATH" "$APP_PY_URL" || { log_error "下载失败！"; return 1; }
    run_command "下载新版 index.html..." wget -qO "$INDEX_HTML_PATH" "$INDEX_HTML_URL" || { log_error "下载失败！"; return 1; }
    
    run_command "重设文件权限..." chown -R "$WEB_USER:$WEB_USER" "$PROJECT_DIR"
    run_command "重启服务..." systemctl restart "$FLASK_APP_NAME"
    log_success "更新成功！"
}

revert_app() {
    print_line; echo -e "${C_BLUE}  ⏪  开始恢复 ${C_BOLD}${FLASK_APP_NAME}${C_NC}  ⏪${C_NC}"; print_line
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR")" ]; then log_warn "没有找到任何备份。"; return 0; fi

    log_info "发现以下备份版本（按时间倒序）："
    local backups=(); while IFS= read -r line; do backups+=("$line"); done < <(ls -1r "$BACKUP_DIR")
    local i=1; for backup in "${backups[@]}"; do echo -e "    ${C_YELLOW}$i)${C_NC} ${C_CYAN}$backup${C_NC}"; i=$((i+1)); done
    local selection; read -rp "请输入您要恢复的备份版本编号: " selection
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#backups[@]} ]; then log_error "无效的编号。"; return 1; fi

    local selected_backup_dir="$BACKUP_DIR/${backups[$((selection-1))]}"
    read -rp "确定要用版本 ${backups[$((selection-1))]} 覆盖当前文件吗？(y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[yY]$ ]]; then
        run_command "恢复文件..." cp "$selected_backup_dir/app.py" "$APP_PY_PATH" && cp "$selected_backup_dir/templates/index.html" "$INDEX_HTML_PATH"
        run_command "重设文件权限..." chown -R "$WEB_USER:$WEB_USER" "$PROJECT_DIR"
        run_command "重启服务..." systemctl restart "$FLASK_APP_NAME"
        log_success "恢复成功！"
    else log_info "恢复操作已取消。"; fi
}

# --- 主程序逻辑 ---
main() {
    clear; print_line
    echo -e "${C_PURPLE}  __  __  ____  ____    _   _ ____  _   _ ___  _   _${C_NC}"; echo -e "${C_PURPLE} |  \\/  |/ ___|/ ___|  | \\ | |  _ \\| \\ | |_ _|| \\ | |${C_NC}"; echo -e "${C_PURPLE} | |\\/| | |  _| |      |  \\| | | | |  \\| || | |  \\| |${C_NC}"; echo -e "${C_PURPLE} | |  | | |_| | |___   | |\\  | |_| | |\\  || | | |\\  |${C_NC}"; echo -e "${C_PURPLE} |_|  |_|\\____|\\____|  |_| \\_|____/|_| \\_|___||_| \\_|${C_NC}";
    echo -e "${C_BLUE}           独立监控面板 - 管理脚本 v9.0${C_NC}"; print_line; echo ""

    if [[ $EUID -ne 0 ]]; then log_error "此脚本必须以 root 用户运行。"; exit 1; fi

    echo -e "${C_BOLD}请首先选择您要操作的版本:${C_NC}"
    echo -e "    ${C_YELLOW}1)${C_NC} ${C_GREEN}正式版 (端口: 5001)${C_NC}"
    echo -e "    ${C_YELLOW}2)${C_NC} ${C_PURPLE}Beta 测试版 (端口: 5002)${C_NC}"
    echo ""
    local version_choice; read -rp "请输入版本编号 [1-2]: " version_choice
    
    local version_name
    case $version_choice in
        1) select_version "stable"; version_name="正式版";;
        2) select_version "beta"; version_name="Beta 测试版";;
        *) log_error "无效的版本选择。脚本退出。"; exit 1;;
    esac

    clear; print_line
    echo -e "${C_BLUE}当前操作对象: ${C_BOLD}${version_name}${C_NC}"
    print_line; echo ""

    echo -e "${C_BOLD}请选择您要对 ${C_BOLD}${version_name}${C_NC} 执行的操作:${C_NC}"
    echo -e "    ${C_YELLOW}1)${C_NC} ${C_CYAN}部署 / 重装${C_NC}"
    echo -e "    ${C_YELLOW}2)${C_NC} ${C_CYAN}一键更新 (从 GitHub)${C_NC}"
    echo -e "    ${C_YELLOW}3)${C_NC} ${C_CYAN}一键恢复 (从本地备份)${C_NC}"
    echo -e "    ${C_YELLOW}4)${C_NC} ${C_RED}卸载${C_NC}"
    echo -e "    ${C_YELLOW}5)${C_NC} ${C_CYAN}返回上级菜单 / 退出${C_NC}"
    echo ""

    local action_choice; read -rp "请输入操作编号 [1-5]: " action_choice
    
    case $action_choice in
        1)
            read -rp "这将覆盖现有部署。确定吗？ (y/N): " CONFIRM
            if [[ "$CONFIRM" =~ ^[yY]$ ]]; then uninstall_monitor; deploy_monitor; fi
            ;;
        2)
            read -rp "这将备份当前版本并从GitHub下载最新版。确定吗？ (y/N): " CONFIRM
            if [[ "$CONFIRM" =~ ^[yY]$ ]]; then update_app; fi
            ;;
        3) revert_app ;;
        4)
            read -rp "警告：这将删除所有相关文件、服务和备份！确定吗？(y/N): " CONFIRM
            if [[ "$CONFIRM" =~ ^[yY]$ ]]; then uninstall_monitor; fi
            ;;
        5) log_info "操作已取消，返回主菜单..." ;;
        *) log_error "无效的选项。" ;;
    esac
    
    echo ""; print_line; echo -e "${C_BLUE}    -- 操作完成 --${C_NC}"; print_line
}

# --- 脚本入口 ---
main "$@"
