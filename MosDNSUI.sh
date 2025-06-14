#!/bin/bash

# MosDNS 全新独立监控面板 - 一键部署与回滚脚本
# 作者：ChatGPT
# 版本：4.1 (新增UI更新与回滚菜单，UI文件外部化；修正系统信息布局，确保始终在底部面板顶部横跨，同时移除JS中错误的DOM移动逻辑)
# 功能：部署一个独立的 Flask 应用，通过网页监控 MosDNS 状态。
#      此面板与 MosDNS 自带 UI 并行运行，互不影响。
#      提供回滚功能，移除本脚本部署的所有文件和配置。
#      提供一键诊断和尝试修复常见部署问题。
# 注意：本脚本会修改 /etc/sudoers.d/ 文件，请谨慎使用。
#      请确保 MosDNS 已正确安装并运行，/metrics 接口可访问。

# --- 定义颜色 ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 辅助日志函数 ---
log_info() {
    echo -e "${GREEN}[信息]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

log_error() {
    echo -e "${RED}[错误]${NC} $1"
}

log_blue() {
    echo -e "${BLUE}$1${NC}"
}

log_green() {
    echo -e "${GREEN}$1${NC}"
}

# --- 全局变量 ---
FLASK_APP_NAME="mosdns_monitor_panel" # 使用新名称以避免冲突
PROJECT_DIR="/opt/$FLASK_APP_NAME"
FLASK_PORT=5001 # 使用新端口，例如 5001
MOSDNS_METRICS_URL="http://localhost:9099/metrics" # MosDNS metrics 接口地址，您可以根据需要修改
WEB_USER="www-data" # 用于运行 Flask 应用的用户
SYSTEMD_SERVICE_FILE="/etc/systemd/system/$FLASK_APP_NAME.service"
VENV_DIR="$PROJECT_DIR/venv"
UI_BACKUP_DIR="$PROJECT_DIR/backup_ui"
INDEX_HTML_PATH="$PROJECT_DIR/templates/index.html"
INDEX_HTML_DOWNLOAD_URL="https://raw.githubusercontent.com/Jimmyzxk/MosDNSUI/main/index.html" # UI 文件下载地址

# --- 辅助命令执行函数 ---
run_command() {
    local cmd_list=("$@")
    if ! "${cmd_list[@]}"; then
        log_error "命令执行失败: ${cmd_list[@]}"
        return 1
    fi
    return 0
}

# --- 清理/回滚函数 ---
cleanup_existing_deployment() {
    log_warn "正在执行回滚/清理操作..."

    if systemctl is-active --quiet "$FLASK_APP_NAME"; then
        log_info "停止并禁用 Systemd 服务: $FLASK_APP_NAME..."
        run_command systemctl stop "$FLASK_APP_NAME" || true
        run_command systemctl disable "$FLASK_APP_NAME" || true
        log_info "Systemd 服务已停止并禁用。"
    fi
    
    if [ -f "$SYSTEMD_SERVICE_FILE" ]; then
        log_info "移除 Systemd 服务文件: $SYSTEMD_SERVICE_FILE..."
        run_command rm "$SYSTEMD_SERVICE_FILE" || true
        run_command systemctl daemon-reload || true
        log_info "Systemd 服务文件已移除。"
    fi

    if [ -d "$PROJECT_DIR" ]; then
        log_info "移除项目目录: $PROJECT_DIR (包含虚拟环境)..."
        run_command rm -rf "$PROJECT_DIR" || true
        log_info "项目目录已移除。"
    fi

    log_info "回滚/清理操作完成。"
}

# --- 部署函数 ---
deploy_monitor() {
    echo ""
    log_blue "--- 正在启动 MosDNS 全新监控面板部署流程 ---"
    
    # 检查 MosDNS metrics 接口是否可访问
    log_info "正在测试 MosDNS metrics 接口: $MOSDNS_METRICS_URL"
    if ! curl --output /dev/null --silent --head --fail "$MOSDNS_METRICS_URL"; then
        log_error "无法访问 MosDNS 的 /metrics 接口。请确保 MosDNS 正在运行，并且其 HTTP 服务端口为 9090。"
        log_warn "您可以在脚本顶部修改 MOSDNS_METRICS_URL 变量以匹配您的配置。"
        return 1
    fi
    log_info "MosDNS metrics 接口可访问。"

    # 检查 www-data 用户是否存在
    if ! id -u "$WEB_USER" >/dev/null 2>&1; then
        log_warn "用户 '$WEB_USER' 不存在，尝试创建..."
        run_command adduser --system --no-create-home --group "$WEB_USER"
        if [ $? -ne 0 ]; then
            log_error "无法创建系统用户 '$WEB_USER'。请手动创建或修改脚本中的 WEB_USER。"
            return 1
        fi
        log_info "用户 '$WEB_USER' 已创建。"
    fi

    log_blue "[步骤 1/7] 安装必要的依赖..."
    run_command apt update -qq
    if [ $? -ne 0 ]; then
        log_error "apt update 失败。请检查网络连接或手动运行 'apt update'。"
        return 1
    fi
    run_command apt install -y python3 python3-pip python3-venv curl wget # Added wget for downloading UI
    if [ $? -ne 0 ]; then
        log_error "无法安装 Python3、wget 或相关依赖。请手动检查并安装。"
        return 1
    fi
    log_info "Python3、wget 和相关依赖已安装。"

    log_blue "[步骤 2/7] 创建项目目录 $PROJECT_DIR 并创建 Python 虚拟环境..."
    run_command mkdir -p "$PROJECT_DIR/templates" "$PROJECT_DIR/static" "$UI_BACKUP_DIR" # Also create backup dir
    
    run_command python3 -m venv "$VENV_DIR"
    if [ $? -ne 0 ]; then
        log_error "无法创建 Python 虚拟环境。请检查 'python3-venv' 是否已安装。"
        return 1
    fi
    log_info "Python 虚拟环境已创建在 $VENV_DIR。"

    run_command chown -R "$WEB_USER:$WEB_USER" "$PROJECT_DIR"
    if [ $? -ne 0 ]; then
        log_error "无法设置项目目录和虚拟环境权限。尝试重新设置..."
        run_command chown -R "$WEB_USER:$WEB_USER" "$PROJECT_DIR" # 再次尝试
        if [ $? -ne 0 ]; then
            log_error "重试后仍无法设置项目目录和虚拟环境权限。请手动检查权限问题。"
            return 1
        fi
    fi
    log_info "项目目录权限已设置。"

    log_blue "[步骤 3/7] 在虚拟环境中安装 Flask 和 Gunicorn..."
    run_command "$VENV_DIR/bin/pip" install Flask gunicorn requests
    if [ $? -ne 0 ]; then
        log_error "无法在虚拟环境中安装 Flask、Gunicorn 或 Requests。请检查错误信息。"
        return 1
    fi
    log_info "Flask、Gunicorn 和 Requests 已安装到虚拟环境。"

    log_blue "[步骤 4/7] 创建 Flask 后端应用 (app.py)..."
    cat <<EOF > "$PROJECT_DIR/app.py"
# app.py - MosDNS Monitor Panel Backend (FIXED)
import os
import sys
import requests
from flask import Flask, render_template, jsonify, Response
import re
import datetime

app = Flask(__name__)

# --- Configuration ---
# 请确保这里的地址是您 MosDNS 的真实管理地址和端口
MOSDNS_ADMIN_URL = "http://localhost:9099"
MOSDNS_METRICS_URL = f"{MOSDNS_ADMIN_URL}/metrics"

def fetch_mosdns_metrics():
    try:
        response = requests.get(MOSDNS_METRICS_URL, timeout=5)
        response.raise_for_status()
        return response.text, None
    except requests.exceptions.RequestException as e:
        error_message = f"无法连接到 MosDNS metrics 接口: {e}"
        print(f"DEBUG: {error_message}", file=sys.stderr)
        return None, error_message

def parse_metrics(metrics_text):
    data = {
        "caches": {},
        "system": { "go_version": "N/A" }
    }
    cache_pattern = re.compile(r'mosdns_cache_(\w+)\{tag="([^"]+)"\}\s+([\d.eE+-]+)')
    for line in metrics_text.split('\n'):
        cache_match = cache_pattern.match(line)
        if cache_match:
            metric, tag, value = cache_match.groups()
            if tag not in data["caches"]:
                data["caches"][tag] = {}
            data["caches"][tag][metric] = float(value)
            continue
        if line.startswith('process_start_time_seconds'):
            data["system"]["start_time"] = float(line.split(' ')[1])
        elif line.startswith('process_cpu_seconds_total'):
            data["system"]["cpu_time"] = float(line.split(' ')[1])
        elif line.startswith('process_resident_memory_bytes'):
            data["system"]["resident_memory"] = float(line.split(' ')[1])
        elif line.startswith('go_memstats_heap_idle_bytes'):
            data["system"]["heap_idle_memory"] = float(line.split(' ')[1])
        elif line.startswith('go_threads'):
            data["system"]["threads"] = int(line.split(' ')[1])
        elif line.startswith('process_open_fds'):
            data["system"]["open_fds"] = int(line.split(' ')[1])
        elif line.startswith('go_info{version="'):
            go_version_match = re.search(r'go_info\{version="([^"]+)"\}', line)
            if go_version_match:
                data["system"]["go_version"] = go_version_match.group(1)
    for tag, metrics in data["caches"].items():
        query_total = metrics.get("query_total", 0)
        hit_total = metrics.get("hit_total", 0)
        lazy_hit_total = metrics.get("lazy_hit_total", 0)
        metrics["hit_rate"] = f"{(hit_total / query_total * 100):.2f}%" if query_total > 0 else "0.00%"
        metrics["lazy_hit_rate"] = f"{(lazy_hit_total / query_total * 100):.2f}%" if query_total > 0 else "0.00%"
    if "start_time" in data["system"]:
        data["system"]["start_time"] = datetime.datetime.fromtimestamp(data["system"]["start_time"]).strftime('%Y-%m-%d %H:%M:%S')
    if "cpu_time" in data["system"]:
        data["system"]["cpu_time"] = f'{data["system"]["cpu_time"]:.2f} 秒'
    if "resident_memory" in data["system"]:
        data["system"]["resident_memory"] = f'{(data["system"]["resident_memory"] / (1024*1024)):.2f} MB'
    if "heap_idle_memory" in data["system"]:
        data["system"]["heap_idle_memory"] = f'{(data["system"]["heap_idle_memory"] / (1024*1024)):.2f} MB'
    return data

@app.route('/')
def index():
    # 这里我们使用您提供的最新HTML版本
    return render_template('index.html')

@app.route('/api/mosdns_status')
def get_mosdns_status():
    metrics_text, error = fetch_mosdns_metrics()
    if error:
        return jsonify({"error": error}), 500
    data = parse_metrics(metrics_text)
    return jsonify(data)

# --- [NEW] 新增的代理路由，修复 "Not Found" 问题 ---
@app.route('/view/<path:subpath>', methods=['GET', 'POST'])
def proxy_mosdns_request(subpath):
    """
    代理对 MosDNS 内部 API 的请求。
    前端请求 /view/plugins/my_fakeiplist/show
    后端实际请求 http://localhost:9099/plugins/my_fakeiplist/show
    """
    mosdns_url = f"{MOSDNS_ADMIN_URL}/{subpath}"
    
    try:
        if request.method == 'POST':
            # 对于 POST 请求，例如清空缓存
            resp = requests.post(mosdns_url, timeout=10)
        else: # GET
            # 对于 GET 请求，例如查看列表
            resp = requests.get(mosdns_url, timeout=10)
        
        resp.raise_for_status()

        # 将 MosDNS 的响应头和内容直接返回给浏览器
        # 对于文本内容，显示为纯文本
        content_type = resp.headers.get('Content-Type', 'text/plain')
        
        # 特殊处理，让浏览器以纯文本方式渲染，避免当成HTML解析
        if 'text' in content_type or 'json' in content_type:
             return Response(resp.text, mimetype='text/plain; charset=utf-8')

        return Response(resp.content, status=resp.status_code, headers=dict(resp.headers))

    except requests.exceptions.RequestException as e:
        error_message = f"代理请求到 MosDNS 失败 ({mosdns_url}): {e}"
        print(f"DEBUG: {error_message}", file=sys.stderr)
        return Response(f"请求 MosDNS 失败: {e}", status=502, mimetype='text/plain')


if __name__ == '__main__':
    port = int(os.environ.get('FLASK_PORT', 5001)) 
    app.run(host='0.0.0.0', port=port, debug=False)
EOF

    if [ $? -ne 0 ]; then
        log_error "无法创建 app.py 文件。"
        return 1
    fi
    run_command chown "$WEB_USER:$WEB_USER" "$PROJECT_DIR/app.py"
    log_info "Flask 应用 (app.py) 已创建。"


    log_blue "[步骤 5/7] 创建网站图标 (favicon.png)..."
    # A simple blue dot favicon (32x32px PNG)
    local FAVICON_BASE64="iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABz51DBAAAAVklEQVR4Xu2WIREAMAgD+5+sO/D9S8Y1Y8UfH6bYk9XbK4iICAgICAgICAgICAgICAgICAgICAj4P+6qEBAQ+O/gJ42Y+G8DAAAA//8AQMhW0P9cE+kAAAAASUVORK5CYII=" # Updated favicon to a more distinct blue dot
    
    echo "$FAVICON_BASE64" | base64 -d > "$PROJECT_DIR/static/favicon.png"
    if [ $? -eq 0 ]; then
        run_command chown "$WEB_USER:$WEB_USER" "$PROJECT_DIR/static/favicon.png"
        log_info "网站图标 (favicon.png) 已创建并设置权限。"
    else
        log_error "无法创建网站图标文件。请检查权限。"
        return 1
    fi


    log_blue "[步骤 6/7] 下载 HTML 前端页面 (index.html)..."
    # Download the latest index.html from GitHub
    run_command wget -qO "$INDEX_HTML_PATH" "$INDEX_HTML_DOWNLOAD_URL"
    if [ $? -ne 0 ]; then
        log_error "无法下载 index.html 文件。请检查网络连接或 URL ($INDEX_HTML_DOWNLOAD_URL) 是否正确。"
        return 1
    fi
    run_command chown "$WEB_USER:$WEB_USER" "$INDEX_HTML_PATH"
    log_info "HTML 前端页面 (index.html) 已下载并设置权限。"

    log_blue "[步骤 7/7] 创建 Systemd 服务文件并启动服务..."
    cat <<EOF > "$SYSTEMD_SERVICE_FILE"
[Unit]
Description=MosDNS Monitoring Panel Flask App
After=network.target

[Service]
User=$WEB_USER
Group=$WEB_USER
WorkingDirectory=$PROJECT_DIR
ExecStart=$VENV_DIR/bin/gunicorn -w 2 -b 0.0.0.0:$FLASK_PORT app:app
Restart=always
# RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    if [ $? -eq 0 ]; then
        run_command systemctl daemon-reload
        run_command systemctl enable "$FLASK_APP_NAME"
        run_command systemctl start "$FLASK_APP_NAME"
        if [ $? -eq 0 ]; then
            log_info "Systemd 服务已创建、启用并启动。"
        else
            log_error "Systemd 服务创建成功，但启动失败。请手动检查日志: 'sudo journalctl -u $FLASK_APP_NAME -f'"
            return 1
        fi
    else
        log_error "无法创建 Systemd 服务文件。"
        return 1
    fi

    log_blue "[附加] 配置防火墙 (UFW) 允许访问 $FLASK_PORT 端口..."
    if command -v ufw &>/dev/null; then
        run_command ufw allow "$FLASK_PORT"/tcp
        run_command ufw reload
        log_info "防火墙已配置。"
    else
        log_warn "未检测到 UFW。请手动检查并配置您的防火墙以允许访问 ${FLASK_PORT} 端口。"
    fi

    echo ""
    log_green "--- 部署完成！---"
    log_info "您现在可以通过以下地址访问监控页面："
    log_blue "  http://$(hostname -I | awk '{print $1}'):$FLASK_PORT"
    log_info "或使用服务器的公网 IP 地址。"
    log_info "监控页面部署在 ${PROJECT_DIR}。"
    log_info "日志可以通过 'sudo journalctl -u $FLASK_APP_NAME -f' 查看。"
    echo ""
    return 0
}

# --- UI 更新函数 ---
update_ui() {
    echo ""
    log_blue "--- 正在启动 UI 更新流程 ---"

    if [ ! -f "$INDEX_HTML_PATH" ]; then
        log_error "当前 UI 文件 '$INDEX_HTML_PATH' 不存在。请先部署监控面板。"
        return 1
    fi

    log_info "创建 UI 备份目录: $UI_BACKUP_DIR..."
    run_command mkdir -p "$UI_BACKUP_DIR"
    run_command chown "$WEB_USER:$WEB_USER" "$UI_BACKUP_DIR"

    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="$UI_BACKUP_DIR/index.html.$timestamp"

    log_info "备份当前 UI 文件到: $backup_file..."
    run_command cp "$INDEX_HTML_PATH" "$backup_file"
    run_command chown "$WEB_USER:$WEB_USER" "$backup_file"
    if [ $? -ne 0 ]; then
        log_error "UI 文件备份失败。更新中止。"
        return 1
    fi
    log_info "UI 文件备份成功。"

    log_info "正在从 $INDEX_HTML_DOWNLOAD_URL 下载最新 UI 文件..."
    run_command wget -qO "$INDEX_HTML_PATH" "$INDEX_HTML_DOWNLOAD_URL"
    if [ $? -ne 0 ]; then
        log_error "下载最新 UI 文件失败。请检查网络连接或 URL 是否正确。已保留原 UI。"
        # Optionally, revert from backup if download fails
        # run_command cp "$backup_file" "$INDEX_HTML_PATH" && log_info "已从备份恢复原 UI。"
        return 1
    fi
    run_command chown "$WEB_USER:$WEB_USER" "$INDEX_HTML_PATH"
    log_info "最新 UI 文件已下载并替换。"

    log_info "重启监控面板服务以应用 UI 变更..."
    run_command systemctl restart "$FLASK_APP_NAME"
    if [ $? -eq 0 ]; then
        log_green "UI 更新成功！请刷新您的网页。"
    else
        log_error "重启服务失败，UI 可能未正常应用。请手动检查: 'sudo journalctl -u $FLASK_APP_NAME -f'"
        return 1
    fi
    echo ""
}

# --- UI 恢复函数 ---
revert_ui() {
    echo ""
    log_blue "--- 正在启动 UI 恢复流程 ---"

    if [ ! -d "$UI_BACKUP_DIR" ] || [ -z "$(ls -A "$UI_BACKUP_DIR")" ]; then
        log_warn "没有找到任何 UI 备份文件。无法执行恢复操作。"
        return 0
    fi

    log_info "发现以下 UI 备份文件："
    local backup_files=()
    local i=1
    while IFS= read -r -d $'\0' file; do
        filename=$(basename "$file")
        filesize=$(du -h "$file" | awk '{print $1}')
        timestamp=$(echo "$filename" | sed -n 's/index.html.\([0-9]\{8\}_[0-9]\{6\}\)/\1/p')
        if [ -n "$timestamp" ]; then
            formatted_date=$(date -d "$(echo "$timestamp" | sed 's/\(....\)\(..\)\(..\)_/\1-\2-\3 /')" +"%Y-%m-%d %H:%M:%S")
        else
            formatted_date="未知日期"
        fi
        echo "  ${YELLOW}$i)${NC} ${BLUE}$filename${NC} (大小: $filesize, 备份时间: $formatted_date)"
        backup_files+=("$file")
        i=$((i+1))
    done < <(find "$UI_BACKUP_DIR" -type f -name "index.html.*" -print0 | sort -z)

    if [ ${#backup_files[@]} -eq 0 ]; then
        log_warn "没有找到有效的 UI 备份文件。请确保备份文件以 'index.html.<时间戳>' 格式存在。"
        return 0
    fi

    local selection
    read -rp "请输入您要恢复的备份编号 (1-${#backup_files[@]}): " selection

    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#backup_files[@]} ]; then
        log_error "无效的编号。恢复操作已取消。"
        return 1
    fi

    local selected_backup="${backup_files[$((selection-1))]}"
    log_info "您选择了恢复: $(basename "$selected_backup")"
    read -rp "确定要将当前 UI 备份并替换为此版本吗？(y/N): " CONFIRM_REVERT

    if [[ "$CONFIRM_REVERT" =~ ^[yY]$ ]]; then
        # Backup current UI before reverting
        log_info "备份当前 UI 文件..."
        local timestamp_current=$(date +"%Y%m%d_%H%M%S")
        local current_backup_path="$UI_BACKUP_DIR/index.html.current_pre_revert.$timestamp_current"
        run_command cp "$INDEX_HTML_PATH" "$current_backup_path"
        run_command chown "$WEB_USER:$WEB_USER" "$current_backup_path"
        if [ $? -ne 0 ]; then
            log_error "备份当前 UI 失败，恢复操作中止。"
            return 1
        fi
        log_info "当前 UI 已备份到: $(basename "$current_backup_path")"


        log_info "正在恢复 UI 文件: $(basename "$selected_backup")..."
        run_command cp "$selected_backup" "$INDEX_HTML_PATH"
        run_command chown "$WEB_USER:$WEB_USER" "$INDEX_HTML_PATH"
        if [ $? -ne 0 ]; then
            log_error "UI 文件恢复失败。请手动检查权限。"
            return 1
        fi
        log_info "UI 文件恢复成功。"

        log_info "重启监控面板服务以应用 UI 变更..."
        run_command systemctl restart "$FLASK_APP_NAME"
        if [ $? -eq 0 ]; then
            log_green "UI 恢复成功！请刷新您的网页。"
        else
            log_error "重启服务失败，UI 可能未正常应用。请手动检查: 'sudo journalctl -u $FLASK_APP_NAME -f'"
            return 1
        fi
    else
        log_info "UI 恢复操作已取消。"
    fi
    echo ""
}


# --- 诊断与修复函数 ---
diagnose_and_fix() {
    echo ""
    log_blue "--- 正在启动诊断与修复流程 ---"
    local issues_found=0

    # 1. 检查 MosDNS 服务
    log_blue "[诊断] 检查 MosDNS 服务状态..."
    if curl --output /dev/null --silent --head --fail "$MOSDNS_METRICS_URL"; then
        log_info "MosDNS 服务: 正在运行且 /metrics 接口可访问。"
    else
        log_warn "MosDNS 服务: 未运行或 /metrics 接口不可访问。请手动检查 MosDNS 服务状态。"
        issues_found=1
    fi

    # 2. 检查 Flask 应用服务
    log_blue "[诊断] 检查监控面板服务 ($FLASK_APP_NAME) 状态..."
    if systemctl is-active --quiet "$FLASK_APP_NAME"; then
        log_info "监控面板服务: 运行中。"
    else
        log_warn "监控面板服务: 未运行。尝试启动..."
        run_command systemctl start "$FLASK_APP_NAME"
        if [ $? -eq 0 ]; then
            log_info "监控面板服务已启动。"
        else
            log_error "无法启动监控面板服务。请手动检查: 'sudo journalctl -u $FLASK_APP_NAME -f'"
            issues_found=1
        fi
    fi

    # 3. 检查防火墙规则
    log_blue "[诊断] 检查防火墙规则 (UFW) 是否允许 $FLASK_PORT 端口..."
    if command -v ufw &>/dev/null; then
        if ufw status | grep -qE "^$FLASK_PORT/tcp\s+(ALLOW IN|ALLOW Anywhere)"; then
            log_info "UFW 已配置，允许访问 $FLASK_PORT 端口。"
        else
            log_warn "UFW 未配置允许访问 $FLASK_PORT 端口。尝试添加规则..."
            run_command ufw allow "$FLASK_PORT"/tcp
            run_command ufw reload
            if [ $? -eq 0 ]; then
                log_info "UFW 规则已添加并重新加载。"
            else
                log_error "无法添加 UFW 规则。请手动检查防火墙配置。"
                issues_found=1
            fi
        fi
    else
        log_warn "未检测到 UFW。请手动检查并配置您的防火墙以允许访问 ${FLASK_PORT} 端口。"
    fi

    echo ""
    if [ $issues_found -eq 0 ]; then
        log_green "诊断完成。未发现主要问题，或问题已尝试修复。请刷新网页检查。"
    else
        log_warn "诊断完成。发现并尝试修复了一些问题。请检查上述错误信息，并刷新网页验证。"
    fi
    echo ""
}

# --- 主程序逻辑 ---

clear
echo -e "${BLUE}--- MosDNS 全新独立监控面板 - 一键部署脚本 ---${NC}"

# 检查是否以 Root 用户运行
if [[ $EUID -ne 0 ]]; then
   log_error "此脚本必须以 root 用户运行。请使用 'sudo ./MosDNSUI.sh'"
   exit 1
fi

PS3="请选择一个操作: "
options=("部署 MosDNS 监控面板" "回滚/清理部署" "一键更新 UI" "一键恢复 UI" "一键诊断并尝试修复" "退出")
select opt in "${options[@]}"
do
    case $opt in
        "部署 MosDNS 监控面板")
            read -rp "您确定要部署监控面板吗？(y/N): " CONFIRM_DEPLOY
            if [[ "$CONFIRM_DEPLOY" =~ ^[yY]$ ]]; then
                deploy_monitor_result=0
                deploy_monitor || deploy_monitor_result=$?
                
                if [ "$deploy_monitor_result" -ne 0 ]; then
                    log_error "部署过程中发生错误。"
                    read -rp "是否尝试回滚已进行的部署操作？(y/N): " CONFIRM_ROLLBACK
                    if [[ "$CONFIRM_ROLLBACK" =~ ^[yY]$ ]]; then
                        cleanup_existing_deployment
                    else
                        log_info "已取消回滚操作。请手动检查并清理。"
                    fi
                fi
            else
                log_info "部署已取消。"
            fi
            break
            ;;
        "回滚/清理部署")
            read -rp "您确定要回滚/清理现有部署吗？这将删除所有相关文件和服务。(y/N): " CONFIRM_CLEAN
            if [[ "$CONFIRM_CLEAN" =~ ^[yY]$ ]]; then
                cleanup_existing_deployment
            else
                log_info "回滚/清理操作已取消。"
            fi
            break
            ;;
        "一键更新 UI")
            read -rp "您确定要更新 UI 吗？这会备份当前 UI 并下载最新版本。(y/N): " CONFIRM_UPDATE
            if [[ "$CONFIRM_UPDATE" =~ ^[yY]$ ]]; then
                update_ui
            else
                log_info "UI 更新操作已取消。"
            fi
            break
            ;;
        "一键恢复 UI")
            read -rp "您确定要恢复 UI 吗？这会用备份替换当前 UI。(y/N): " CONFIRM_REVERT_MENU
            if [[ "$CONFIRM_REVERT_MENU" =~ ^[yY]$ ]]; then
                revert_ui
            else
                log_info "UI 恢复操作已取消。"
            fi
            break
            ;;
        "一键诊断并尝试修复")
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
