#!/bin/bash

# MosDNS 独立监控面板 - 一键部署脚本
# 作者：ChatGPT & JimmyDADA & Phil Horse
# 版本：6.2 (Python直启最终版)
# 特点：
# - [重大修复] 不再使用 Gunicorn，改为由 systemd 直接调用 'python3 app.py' 启动服务，彻底解决可执行文件找不到的问题。
# - 脚本、app.py、index.html 完全解耦，核心文件从外部 URL 下载。
# - 使用系统 apt 安装依赖。

# --- 定义颜色 ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 辅助日志函数 ---
log_info() { echo -e "${GREEN}[信息]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[警告]${NC} $1"; }
log_error() { echo -e "${RED}[错误]${NC} $1"; }
log_blue() { echo -e "${BLUE}$1${NC}"; }
log_green() { echo -e "${GREEN}$1${NC}"; }

# --- 全局变量 ---
FLASK_APP_NAME="mosdns_monitor_panel"
PROJECT_DIR="/opt/$FLASK_APP_NAME"
FLASK_PORT=5001
MOSDNS_ADMIN_URL="http://127.0.0.1:9099" # 您可以根据需要修改
WEB_USER="www-data"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/$FLASK_APP_NAME.service"

# --- 外部下载地址 ---
APP_PY_URL="https://raw.githubusercontent.com/Jimmyzxk/MosDNSUI/main/app.py"
INDEX_HTML_URL="https://raw.githubusercontent.com/Jimmyzxk/MosDNSUI/main/index.html"

# --- 辅助命令执行函数 ---
run_command() {
    local cmd_list=("$@")
    if ! "${cmd_list[@]}"; then
        log_error "命令执行失败: ${cmd_list[@]}"
        return 1
    fi
    return 0
}

# --- 清理/卸载函数 ---
uninstall_monitor() {
    log_warn "正在执行卸载/清理操作..."
    if systemctl is-active --quiet "$FLASK_APP_NAME"; then
        log_info "停止并禁用 Systemd 服务..."
        run_command systemctl stop "$FLASK_APP_NAME" || true
        run_command systemctl disable "$FLASK_APP_NAME" || true
    fi
    if [ -f "$SYSTEMD_SERVICE_FILE" ]; then
        log_info "移除 Systemd 服务文件..."
        run_command rm -f "$SYSTEMD_SERVICE_FILE" || true
        run_command systemctl daemon-reload || true
    fi
    if [ -d "$PROJECT_DIR" ]; then
        log_info "移除项目目录 $PROJECT_DIR..."
        run_command rm -rf "$PROJECT_DIR" || true
    fi
    log_info "卸载/清理操作完成。"
}

# --- 部署函数 ---
deploy_monitor() {
    echo ""
    log_blue "--- 正在启动 MosDNS 监控面板部署流程 (Python直启模式) ---"
    
    log_info "正在测试 MosDNS 接口: $MOSDNS_ADMIN_URL"
    if ! curl --output /dev/null --silent --head --fail "$MOSDNS_ADMIN_URL/metrics"; then
        log_error "无法访问 MosDNS 的 /metrics 接口。请确保 MosDNS 正在运行，且管理端口正确。"
        return 1
    fi
    log_info "MosDNS 接口可访问。"

    if ! id -u "$WEB_USER" >/dev/null 2>&1; then
        log_warn "用户 '$WEB_USER' 不存在，尝试创建..."
        run_command adduser --system --no-create-home --group "$WEB_USER" || return 1
        log_info "用户 '$WEB_USER' 已创建。"
    fi

    log_blue "[步骤 1/5] 安装系统依赖..."
    run_command apt-get update -qq || return 1
    # [MODIFIED] 不再安装 gunicorn
    run_command apt-get install -y python3 python3-pip python3-flask python3-requests curl wget || return 1
    log_info "系统依赖已安装。"

    log_blue "[步骤 2/5] 创建项目目录..."
    run_command mkdir -p "$PROJECT_DIR/templates" "$PROJECT_DIR/static" || return 1
    log_info "项目目录已创建。"

    log_blue "[步骤 3/5] 下载核心应用文件..."
    log_info "下载 app.py ..."
    run_command wget -qO "$PROJECT_DIR/app.py" "$APP_PY_URL" || { log_error "下载 app.py 失败！"; return 1; }
    
    log_info "下载 index.html ..."
    run_command wget -qO "$PROJECT_DIR/templates/index.html" "$INDEX_HTML_URL" || { log_error "下载 index.html 失败！"; return 1; }
    
    run_command chown -R "$WEB_USER:$WEB_USER" "$PROJECT_DIR" || return 1
    log_info "核心文件已下载并设置权限。"

    log_blue "[步骤 4/5] 创建 Systemd 服务文件..."
    # [MODIFIED] ExecStart 改为直接调用 python3 app.py
    cat <<EOF > "$SYSTEMD_SERVICE_FILE"
[Unit]
Description=MosDNS Monitoring Panel Flask App
After=network.target

[Service]
User=$WEB_USER
Group=$WEB_USER
WorkingDirectory=$PROJECT_DIR
# 使用 python3 直接启动 app.py，端口通过环境变量传入
ExecStart=/usr/bin/python3 app.py
Environment="FLASK_PORT=$FLASK_PORT"
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    log_info "Systemd 服务文件已创建。"

    log_blue "[步骤 5/5] 启动并配置服务..."
    run_command systemctl daemon-reload || return 1
    run_command systemctl enable "$FLASK_APP_NAME" || return 1
    run_command systemctl restart "$FLASK_APP_NAME" || {
        log_error "服务启动失败。请运行 'sudo journalctl -u $FLASK_APP_NAME -f' 查看日志。"
        return 1
    }
    log_info "Systemd 服务已启动并设为开机自启。"

    log_blue "[附加] 配置防火墙 (UFW)..."
    if command -v ufw &>/dev/null; then
        if ! ufw status | grep -qw "$FLASK_PORT"; then
            run_command ufw allow "$FLASK_PORT"/tcp || true
            run_command ufw reload || true
        fi
    fi

    echo ""
    log_green "--- 部署完成！---"
    log_info "您现在可以通过以下地址访问监控页面："
    log_blue "  http://$(hostname -I | awk '{print $1}'):$FLASK_PORT"
    echo ""
    return 0
}

# --- 诊断函数 ---
diagnose_and_fix() {
    echo ""
    log_blue "--- 正在启动诊断与修复流程 ---"
    
    log_blue "[诊断] 检查 MosDNS 服务..."
    if curl --output /dev/null --silent --head --fail "$MOSDNS_ADMIN_URL/metrics"; then
        log_info "MosDNS 服务正常。"
    else
        log_warn "MosDNS 服务无法访问。请手动检查。"
    fi

    log_blue "[诊断] 检查监控面板服务..."
    if systemctl is-active --quiet "$FLASK_APP_NAME"; then
        log_info "监控面板服务 ($FLASK_APP_NAME) 正在运行。"
    else
        log_warn "监控面板服务未运行。尝试重启..."
        run_command systemctl restart "$FLASK_APP_NAME" || log_error "重启失败，请查看日志: journalctl -u $FLASK_APP_NAME"
    fi
}

# --- 主程序逻辑 ---
main() {
    clear
    echo -e "${BLUE}--- MosDNS 独立监控面板 - 一键部署脚本 v6.2 (Python直启版) ---${NC}"

    if [[ $EUID -ne 0 ]]; then
       log_error "此脚本必须以 root 用户运行。请使用 'sudo bash $0'"
       exit 1
    fi

    PS3="请选择一个操作: "
    options=("部署 / 重装监控面板" "卸载监控面板" "一键诊断" "退出")
    select opt in "${options[@]}"
    do
        case $opt in
            "部署 / 重装监控面板")
                read -rp "这将停止现有服务并重新部署。确定吗？ (y/N): " CONFIRM
                if [[ "$CONFIRM" =~ ^[yY]$ ]]; then
                    uninstall_monitor
                    deploy_monitor
                else
                    log_info "部署已取消。"
                fi
                break
                ;;
            "卸载监控面板")
                read -rp "您确定要卸载监控面板吗？(y/N): " CONFIRM
                if [[ "$CONFIRM" =~ ^[yY]$ ]]; then
                    uninstall_monitor
                else
                    log_info "卸载已取消。"
                fi
                break
                ;;
            "一键诊断")
                diagnose_and_fix
                break
                ;;
            "退出")
                log_info "脚本已退出。"
                exit 0
                ;;
            *) echo "无效的选项 $REPLY";;
        esac
    done
    echo -e "${BLUE}--- 脚本执行结束 ---${NC}"
}

# --- 脚本入口 ---
main "$@"
