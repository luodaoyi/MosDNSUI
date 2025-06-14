#!/bin/bash

# MosDNS 独立监控面板 - Beta版专用部署脚本
# 作者：ChatGPT & JimmyDADA & Phil Horse
# 版本：9.2 (Beta独立部署版)
# 特点：
# - [独立部署] 使用独立的目录、服务名和端口，与正式版完全隔离，互不干扰。
# - 专为 Beta 版 UI (带背景上传) 设计，自动处理所有依赖和目录。

# --- 定义颜色和样式 ---
C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'; C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'; C_PURPLE='\033[0;35m'; C_BOLD='\033[1m'; C_NC='\033[0m';

# --- 辅助日志函数 ---
log_info() { echo -e "${C_GREEN}✔  [信息]${C_NC} $1"; }
log_warn() { echo -e "${C_YELLOW}⚠  [警告]${C_NC} $1"; }
log_error() { echo -e "${C_RED}✖  [错误]${C_NC} $1"; }
log_step() { echo -e "\n${C_PURPLE}🚀 [步骤 ${1}/${2}]${C_NC} ${C_BOLD}$3${C_NC}"; }
log_success() { echo -e "\n${C_GREEN}🎉🎉🎉 $1 🎉🎉🎉${C_NC}"; }
print_line() { echo -e "${C_BLUE}==================================================================${C_NC}"; }

# --- [BETA版专用配置] ---
FLASK_APP_NAME="mosdns_monitor_panel_beta"
PROJECT_DIR="/opt/$FLASK_APP_NAME"
BACKUP_DIR="$PROJECT_DIR/backups"
UPLOAD_DIR="$PROJECT_DIR/uploads"
FLASK_PORT=5002 # Beta版使用 5002 端口
SYSTEMD_SERVICE_FILE="/etc/systemd/system/$FLASK_APP_NAME.service"

# 使用您提供的 Beta 版文件下载地址
APP_PY_URL="https://raw.githubusercontent.com/Jimmyzxk/MosDNSUI/main/Beta/app.py"
INDEX_HTML_URL="https://raw.githubusercontent.com/Jimmyzxk/MosDNSUI/main/Beta/index.html"
APP_PY_PATH="$PROJECT_DIR/app.py"
INDEX_HTML_PATH="$PROJECT_DIR/templates/index.html"

# --- 共享配置 ---
MOSDNS_ADMIN_URL="http://127.0.0.1:9099"
WEB_USER="www-data"

# --- 辅助命令执行函数 (重构版) ---
run_command() {
    local message="$1"; shift
    printf "    %-55s" "$message"
    # shellcheck disable=SC2068
    ($@ &>/dev/null) &
    local pid=$!; local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'; local i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % ${#spin[@]} )); printf "${C_CYAN}%s${C_NC}" "${spin:$i:1}"; sleep 0.1; printf "\b";
    done
    wait $pid
    if [ $? -eq 0 ]; then echo -e "[ ${C_GREEN}成功${C_NC} ]"; return 0;
    else echo -e "[ ${C_RED}失败${C_NC} ]"; return 1; fi
}

# --- 核心功能函数 ---
deploy_beta() {
    print_line; echo -e "${C_BLUE}  🚀  开始部署 MosDNS 监控面板 (Beta版)  🚀${C_NC}"; print_line
    
    log_step 1 5 "环境检测与依赖安装"
    run_command "测试 MosDNS 接口..." curl --output /dev/null --silent --head --fail "$MOSDNS_ADMIN_URL/metrics" || { log_error "无法访问 MosDNS 接口。"; return 1; }
    if ! id -u "$WEB_USER" >/dev/null 2>&1; then run_command "创建系统用户 '$WEB_USER'..." adduser --system --no-create-home --group "$WEB_USER" || return 1; fi
    run_command "更新 apt 缓存..." apt-get update -qq
    run_command "安装系统依赖..." apt-get install -y python3 python3-pip python3-flask python3-requests python3-werkzeug curl wget || return 1
    
    log_step 2 5 "创建 Beta 版项目目录结构"
    run_command "创建所有目录 (包括 uploads)..." mkdir -p "$PROJECT_DIR/templates" "$PROJECT_DIR/static" "$BACKUP_DIR" "$UPLOAD_DIR" || return 1
    
    log_step 3 5 "下载 Beta 版核心应用文件"
    run_command "下载 app.py (Beta)..." wget -qO "$APP_PY_PATH" "$APP_PY_URL" || { log_error "下载 app.py 失败！"; return 1; }
    run_command "下载 index.html (Beta)..." wget -qO "$INDEX_HTML_PATH" "$INDEX_HTML_URL" || { log_error "下载 index.html 失败！"; return 1; }
    run_command "设置文件权限..." chown -R "$WEB_USER:$WEB_USER" "$PROJECT_DIR" || return 1

    log_step 4 5 "创建并配置 Beta 版 Systemd 服务"
    local python_path; python_path=$(which python3)
    cat <<EOF > "$SYSTEMD_SERVICE_FILE"
[Unit]
Description=MosDNS Monitoring Panel (Beta)
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
    run_command "创建 Systemd 服务文件 (${FLASK_APP_NAME}.service)..." true

    log_step 5 5 "启动服务并设置开机自启"
    run_command "重载 Systemd..." systemctl daemon-reload || return 1
    run_command "启用 Beta 服务..." systemctl enable "$FLASK_APP_NAME" || return 1
    run_command "重启 Beta 服务..." systemctl restart "$FLASK_APP_NAME" || { log_error "服务启动失败！请检查日志。"; return 1; }
    
    local ip_addr; ip_addr=$(hostname -I | awk '{print $1}')
    print_line; log_success "Beta 版部署完成！"
    echo -e "${C_CYAN}
    ┌──────────────────────────────────────────────────┐
    │                                                  │
    │   请在浏览器中访问 Beta 版面板:                    │
    │   ${C_BOLD}http://${ip_addr}:${FLASK_PORT}${C_NC}                     │
    │                                                  │
    └──────────────────────────────────────────────────┘
    ${C_NC}"
}

uninstall_beta() {
    log_warn "正在卸载 Beta 版..."
    run_command "停止并禁用 Beta 服务" systemctl stop "$FLASK_APP_NAME" && systemctl disable "$FLASK_APP_NAME"
    run_command "移除 Beta 服务文件" rm -f "$SYSTEMD_SERVICE_FILE" && systemctl daemon-reload
    run_command "移除 Beta 项目目录" rm -rf "$PROJECT_DIR"
    log_success "Beta 版卸载完成！"
}

# --- 主程序逻辑 ---
main() {
    clear; print_line
    echo -e "${C_BLUE}  MosDNS 监控面板 Beta 版管理脚本  ${C_NC}"; print_line; echo ""
    if [[ $EUID -ne 0 ]]; then log_error "此脚本必须以 root 用户运行。"; exit 1; fi

    PS3="请选择操作: "
    options=("部署 / 重装 Beta 版" "卸载 Beta 版" "退出")
    select opt in "${options[@]}"; do
        case $opt in
            "部署 / 重装 Beta 版")
                read -rp "这将覆盖现有 Beta 版部署。确定吗？ (y/N): " c; if [[ "$c" =~ ^[yY]$ ]]; then uninstall_beta; deploy_beta; fi; break;;
            "卸载 Beta 版")
                read -rp "警告：这将删除 Beta 版所有文件和服务！确定吗？(y/N): " c; if [[ "$c" =~ ^[yY]$ ]]; then uninstall_beta; fi; break;;
            "退出") break;;
            *) echo "无效选项 $REPLY";;
        esac
    done
    echo ""; print_line; echo -e "${C_BLUE}    -- 操作完成 --${C_NC}"; print_line
}

main "$@"
