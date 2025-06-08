#!/bin/bash

# MosDNS 全新独立监控面板 - 一键部署与回滚脚本
# 作者：ChatGPT
# 版本：3.6 (修正系统信息布局，确保始终在底部面板顶部横跨，同时移除JS中错误的DOM移动逻辑)
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
    run_command apt install -y python3 python3-pip python3-venv curl
    if [ $? -ne 0 ]; then
        log_error "无法安装 Python3 或相关依赖。请手动检查并安装。"
        return 1
    fi
    log_info "Python3 和相关依赖已安装。"

    log_blue "[步骤 2/7] 创建项目目录 $PROJECT_DIR 并创建 Python 虚拟环境..."
    run_command mkdir -p "$PROJECT_DIR/templates" "$PROJECT_DIR/static"
    
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
# app.py - MosDNS Monitor Panel Backend
import os
import sys
import requests
from flask import Flask, render_template, jsonify
import re
import datetime

app = Flask(__name__)

# --- Configuration ---
MOSDNS_METRICS_URL = "$MOSDNS_METRICS_URL"

def fetch_mosdns_metrics():
    try:
        response = requests.get(MOSDNS_METRICS_URL, timeout=5)
        response.raise_for_status()  # Throws an exception for non-2xx status codes
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

    # Regex patterns for robustness
    cache_pattern = re.compile(r'mosdns_cache_(\w+)\{tag="([^"]+)"\}\s+([\d.eE+-]+)')
    
    for line in metrics_text.split('\\n'):
        cache_match = cache_pattern.match(line)
        if cache_match:
            metric, tag, value = cache_match.groups()
            if tag not in data["caches"]:
                data["caches"][tag] = {}
            data["caches"][tag][metric] = float(value)
            continue # Move to next line

        # System Info using simple startswith for efficiency
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

    # Calculate hit rates
    for tag, metrics in data["caches"].items():
        query_total = metrics.get("query_total", 0)
        hit_total = metrics.get("hit_total", 0)
        lazy_hit_total = metrics.get("lazy_hit_total", 0)
        
        if query_total > 0:
            metrics["hit_rate"] = f"{(hit_total / query_total * 100):.2f}%"
            metrics["lazy_hit_rate"] = f"{(lazy_hit_total / query_total * 100):.2f}%"
        else:
            metrics["hit_rate"] = "0.00%"
            metrics["lazy_hit_rate"] = "0.00%"
            
    # Format system info
    if "start_time" in data["system"]:
        data["system"]["start_time"] = datetime.datetime.fromtimestamp(data["system"]["start_time"]).strftime('%Y-%m-%d %H:%M:%S')
    if "cpu_time" in data["system"]:
        data["system"]["cpu_time"] = f'{data["system"]["cpu_time"]:.2f} 秒'
    if "resident_memory" in data["system"]:
        # Convert bytes to MB
        data["system"]["resident_memory"] = f'{(data["system"]["resident_memory"] / (1024*1024)):.2f} MB'
    if "heap_idle_memory" in data["system"]:
        # Convert bytes to MB
        data["system"]["heap_idle_memory"] = f'{(data["system"]["heap_idle_memory"] / (1024*1024)):.2f} MB'

    return data


@app.route('/')
def index():
    return render_template('index.html')

@app.route('/api/mosdns_status')
def get_mosdns_status():
    metrics_text, error = fetch_mosdns_metrics()
    if error:
        return jsonify({"error": error}), 500

    data = parse_metrics(metrics_text)
    return jsonify(data)

@app.route('/api/flush_fakeip_cache', methods=['POST'])
def flush_fakeip_cache():
    # Assumes Mosdns admin API is on the same host/port as metrics
    # MosDNS's admin API for flushing cache is typically /plugins/cache/flush
    # if metrics is on :9099/metrics, then flush is on :9099/plugins/cache/flush
    flush_url = MOSDNS_METRICS_URL.replace("/metrics", "/plugins/cache/flush")
    try:
        response = requests.post(flush_url, timeout=5)
        response.raise_for_status() # Raise HTTPError for bad responses (4xx or 5xx)
        return jsonify({"message": "FakeIP cache flushed successfully."}), 200
    except requests.exceptions.RequestException as e:
        error_message = f"无法清空缓存: {e}"
        print(f"DEBUG: {error_message}", file=sys.stderr)
        return jsonify({"error": error_message}), 500

if __name__ == '__main__':
    port = int(os.environ.get('FLASK_PORT', $FLASK_PORT)) 
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


    log_blue "[步骤 6/7] 创建 HTML 前端页面 (index.html)..."
    cat <<'EOF' > "$PROJECT_DIR/templates/index.html"
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MosDNS 服务监控</title>

    <!-- Favicon / 网站图标 -->
    <link rel="icon" type="image/png" href="/static/favicon.png">
    <link rel="apple-touch-icon" href="/static/favicon.png">

    <!-- Font Awesome for Icons -->
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.2/css/all.min.css" integrity="sha512-SnH5WK+bZxgPHs44uWIX+LLJAJ9/2PkPKZ5QiAj6Ta86w+fsb2TkcmfRyVX3pBnMFcV7oQPJkl9QevSCWr3W6A==" crossorigin="anonymous" referrerpolicy="no-referrer" />

    <!-- Chart.js 和 datalabels 插件 -->
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.3/dist/chart.umd.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-datalabels@2.2.0"></script>

    <style>
        /* CSS Variables for theming */
        :root {
            --bg-color: #f7f9fd; /* Light blueish background */
            --text-color: #2c3e50; /* Darker text */
            --card-bg: #ffffff;
            --card-shadow: 0 8px 20px rgba(0, 0, 0, 0.08); /* Softer, deeper shadow */
            --border-color: #e0e6ec; /* Lighter border */
            --accent-color: #4a90e2; /* A modern blue */
            --error-color: #e74c3c;
            --label-color: #7f8c8d; /* Muted label */
            --value-color: #34495e; /* Stronger value */
            --control-bg: #f0f4f7;
            --control-border: #d5dce2;
            --control-text: #5e727e;
            --control-hover-bg: #e5edf3;
            --control-active-bg: var(--accent-color);
            --control-active-text: #ffffff;
            --toggle-shadow: 0 2px 6px rgba(0, 0, 0, 0.1);

            /* Status Dot Colors */
            --status-green: #2ecc71;
            --status-yellow: #f1c40f;
            --status-red: #e74c3c;

            /* Gradient Colors */
            --gradient-start: #4a90e2;
            --gradient-mid: #2e86de;
            --gradient-end: #4a90e2;

            /* Border Radii */
            --radius-main: 1rem; /* Slightly larger radius */
            --radius-bar: 0.2rem;
            --radius-control: 0.5rem; /* For buttons and toggles */

            /* Chart Colors */
            --chart-color-hit: rgba(74, 144, 226, 0.7);
            --chart-color-miss: rgba(189, 195, 199, 0.3); /* Lighter gray for miss */
            --chart-border-hit: var(--accent-color);
            --chart-border-miss: #bdc3c7;
        }

        /* --- Theme: Dark (Default Dark) --- */
        body.theme-dark {
            --bg-color: #1a1a1a; /* Cleaner, very dark gray */
            --text-color: #e0e0e0;
            --card-bg: #282828; /* Slightly lighter card background for contrast */
            --card-shadow: 0 8px 25px rgba(0, 0, 0, 0.5); /* Deeper shadow */
            --border-color: #3a3a3a;
            --label-color: #bbbbbb; /* Lighter for readability */
            --value-color: #ffffff; /* Pure white for values */
            --control-bg: #353535;
            --control-border: #4a4a4a;
            --control-text: #e0e0e0;
            --control-hover-bg: #404040;
            --control-active-bg: #555555; /* A more neutral dark grey for active state */
            --control-active-text: #ffffff;
            --gradient-start: #5096ff; /* Brighter blue gradient for dark mode */
            --gradient-mid: #3a7ce0;
            --gradient-end: #5096ff;
            --chart-color-hit: rgba(80, 150, 255, 0.7); /* Brighter blue for hit in dark mode */
            --chart-color-miss: rgba(100, 100, 100, 0.3);
            --chart-border-hit: #5096ff;
            --chart-border-miss: #707070;
        }

        /* --- Theme: Cyberpunk --- */
        body.theme-cyberpunk {
            --bg-color: #0c0221;
            --text-color: #e0e1dd;
            --card-bg: #1a0f3d;
            --card-shadow: 0 10px 30px rgba(42, 7, 102, 0.6);
            --border-color: #3b2a60;
            --accent-color: #00f6ff; /* Cyan */
            --error-color: #ff005c; /* Magenta */
            --label-color: #a9a2c1;
            --value-color: #f0f0f0;
            --gradient-start: #00f6ff;
            --gradient-mid: #ff005c;
            --gradient-end: #00f6ff;
            --control-bg: #1e114d;
            --control-border: #4a3a79;
            --control-text: #a0a0e0;
            --control-hover-bg: #2e1e5d;
            --control-active-bg: #00f6ff;
            --control-active-text: #0c0221;
            --chart-color-hit: rgba(0, 246, 255, 0.7);
            --chart-color-miss: rgba(255, 0, 92, 0.3);
            --chart-border-hit: #00f6ff;
            --chart-border-miss: #ff005c;
        }

        /* --- Theme: Forest --- */
        body.theme-forest {
            --bg-color: #e8f5e9;
            --text-color: #2e3d32;
            --card-bg: #ffffff;
            --card-shadow: 0 6px 18px rgba(0, 0, 0, 0.06);
            --border-color: #d0e0d0;
            --accent-color: #4a7c59; /* Forest Green */
            --error-color: #c0392b;
            --label-color: #607b6c;
            --value-color: #2e3d32;
            --gradient-start: #4a7c59;
            --gradient-mid: #3a6246;
            --gradient-end: #4a7c59;
            --control-bg: #e1f0e2;
            --control-border: #c8d8c8;
            --control-text: #506f5c;
            --control-hover-bg: #d6e8d7;
            --control-active-bg: #4a7c59;
            --control-active-text: #ffffff;
            --chart-color-hit: rgba(74, 124, 89, 0.7);
            --chart-color-miss: rgba(160, 180, 165, 0.3);
            --chart-border-hit: #4a7c59;
            --chart-border-miss: #a0a0a0;
        }

        /* --- Theme: Sunset --- */
        body.theme-sunset {
            --bg-color: #2c203a;
            --text-color: #fde8d7;
            --card-bg: #3a2a4e;
            --card-shadow: 0 10px 30px rgba(44, 32, 58, 0.6);
            --border-color: #553e70;
            --accent-color: #ff8c42; /* Orange */
            --error-color: #e74c3c;
            --label-color: #d3b7e8;
            --value-color: #fde8d7;
            --gradient-start: #ff8c42;
            --gradient-mid: #ff4d6d;
            --gradient-end: #ff8c42;
            --control-bg: #4a3360;
            --control-border: #5c4278;
            --control-text: #e0c8f5;
            --control-hover-bg: #5a4370;
            --control-active-bg: #ff8c42;
            --control-active-text: #2c203a;
            --chart-color-hit: rgba(255, 140, 66, 0.7);
            --chart-color-miss: rgba(255, 77, 109, 0.3);
            --chart-border-hit: #ff8c42;
            --chart-border-miss: #ff4d6d;
        }

        /* --- Theme: Monochrome --- */
        body.theme-monochrome {
            --bg-color: #eef1f4;
            --text-color: #2b2e31;
            --card-bg: #ffffff;
            --card-shadow: 0 6px 18px rgba(0, 0, 0, 0.07);
            --border-color: #d8dee3;
            --accent-color: #4a4a4a; /* Deeper gray for accent */
            --error-color: #b00020;
            --label-color: #7f8c8d;
            --value-color: #1a1a1a;
            --gradient-start: #666666;
            --gradient-mid: #333333;
            --gradient-end: #666666;
            --control-bg: #e1e4e7;
            --control-border: #c9ccd0;
            --control-text: #5e6872;
            --control-hover-bg: #d6dbdf;
            --control-active-bg: #4a4a4a;
            --control-active-text: #ffffff;
            --chart-color-hit: rgba(74, 74, 74, 0.7);
            --chart-color-miss: rgba(160, 160, 160, 0.3);
            --chart-border-hit: #4a4a4a;
            --chart-border-miss: #a0a0a0;
        }

        /* Base styles */
        html {
            font-size: 16px;
        }
        body {
            font-family: 'SF Pro Text', 'system-ui', -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Roboto', 'Oxygen', 'Ubuntu', 'Cantarell', 'Fira Sans', 'Droid Sans', 'Helvetica Neue', sans-serif;
            margin: 0;
            padding: 2rem; /* Increased padding */
            background-color: var(--bg-color);
            color: var(--text-color);
            line-height: 1.6; /* Slightly increased line height */
            transition: background-color 0.4s ease-in-out, color 0.4s ease-in-out;
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            align-items: center;
            box-sizing: border-box;
        }

        .header {
            text-align: center;
            width: 100%;
            max-width: 1200px;
            margin-bottom: 2rem;
            position: relative;
        }

        .header h1 {
            font-size: 2.5rem; /* Larger title */
            color: var(--accent-color);
            margin: 0 0 0.8rem 0; /* More spacing */
            font-weight: 700;
            letter-spacing: -0.03em; /* Tighter letter spacing for title */
        }
        .header-gradient-bar {
            width: 100%;
            max-width: 160px; /* Wider bar */
            height: 5px; /* Thicker bar */
            border-radius: var(--radius-bar);
            background-image: linear-gradient(to right, var(--gradient-start), var(--gradient-mid), var(--gradient-end));
            margin: 0 auto 1.5rem auto;
            transition: background-image 0.4s ease-in-out;
        }

        /* Theme Toggle Buttons (now in footer) */
        .theme-selector {
            display: flex;
            flex-wrap: wrap; /* Allow wrapping on smaller screens */
            gap: 0.5rem; /* Gap between buttons */
            /* Removed fixed positioning styles */
            background-color: var(--control-bg); /* Use control background */
            border: 1px solid var(--control-border); /* Use control border */
            border-radius: var(--radius-control);
            box-shadow: var(--toggle-shadow);
            overflow: hidden;
            padding: 0.5rem; /* Padding for the container */
            justify-content: center; /* Center buttons within its container */
        }
        .theme-selector button {
            background: none;
            border: none;
            padding: 0.6rem 0.9rem;
            color: var(--control-text);
            font-size: 0.9rem;
            cursor: pointer;
            outline: none;
            transition: background-color 0.2s ease, color 0.2s ease, transform 0.1s ease-out;
            border-radius: var(--radius-control); /* Apply radius to individual buttons */
            flex-grow: 1; /* Allow buttons to grow */
            min-width: 90px; /* Ensure a minimum width for buttons */
        }
        .theme-selector button:hover {
            background-color: var(--control-hover-bg);
        }
        .theme-selector button.active {
            background-color: var(--control-active-bg);
            color: var(--control-active-text);
            box-shadow: inset 0 1px 3px rgba(0,0,0,0.1);
        }
        /* No border-right needed if buttons have gap and individual border-radius */
        .theme-selector button i {
            margin-right: 0.3em;
        }

        .main-container {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(380px, 1fr)); /* Auto-fit columns, slightly wider min */
            gap: 1.5rem; /* Increased gap */
            width: 100%;
            max-width: 1400px;
            flex-grow: 1;
            margin-bottom: 2rem; /* Space before footer */
        }

        .card {
            background-color: var(--card-bg);
            border-radius: var(--radius-main);
            box-shadow: var(--card-shadow);
            padding: 1.8rem; /* More padding inside cards */
            display: none; /* Initially hidden */
            flex-direction: column;
            box-sizing: border-box;
            transition: all 0.3s ease-in-out;
            border: 1px solid var(--border-color);
            transform: translateY(0); /* Ensure smooth hover */
        }
        .card.visible {
            display: flex;
        }
        .card:hover {
            transform: translateY(-0.35rem); /* Slightly more pronounced lift */
            box-shadow: 0 12px 30px rgba(0, 0, 0, 0.12); /* Enhanced hover shadow */
        }
        .card-content {
            display: flex;
            flex-direction: row;
            gap: 2rem; /* Increased gap within card */
            flex-grow: 1;
        }

        h2, h3 {
            color: var(--text-color);
            border-bottom: none;
            padding-bottom: 0;
            margin-top: 0;
            margin-bottom: 0.6rem; /* More margin */
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 0.6rem; /* More gap for icon */
        }
        h2 { font-size: 1.6rem; } /* Slightly larger */
        h3 { font-size: 1.3rem; border-bottom: 1px solid var(--border-color); padding-bottom: 0.6rem; margin-bottom: 1rem; }

        h2 .title-text {
            flex-grow: 1;
            text-align: left;
        }
        h2 .status-dot {
            width: 0.6rem; /* Slightly larger dot */
            height: 0.6rem;
            border-radius: 50%;
            transition: background-color 0.3s ease-in-out;
            flex-shrink: 0;
        }
        h2 .status-dot.status-green { background-color: var(--status-green); }
        h2 .status-dot.status-yellow { background-color: var(--status-yellow); }

        .card-title-gradient-bar {
            width: 100%;
            height: 4px; /* Thicker bar */
            border-radius: var(--radius-bar);
            background-image: linear-gradient(to right, var(--gradient-start), var(--gradient-mid), var(--gradient-end));
            margin-bottom: 1.2rem;
            transition: background-image 0.4s ease-in-out;
        }

        .metrics-container {
            flex: 1;
            display: grid;
            grid-template-columns: auto 1fr;
            gap: 0.6rem 1.2rem; /* More space */
            align-items: baseline;
        }
        .metrics-container p {
            margin: 0; /* Remove default paragraph margin */
            font-size: 1.05rem; /* Slightly larger text */
            display: contents;
        }
        .label {
            font-weight: 500;
            color: var(--label-color);
            text-align: right;
            padding-right: 0.6rem;
        }
        .value {
            color: var(--value-color);
            font-weight: 600;
            text-align: left;
        }
        .value.accent {
            color: var(--accent-color);
            font-weight: 700; /* More emphasis */
        }

        .charts {
            display: flex;
            flex-direction: column;
            gap: 1.2rem; /* More gap between charts */
            flex-shrink: 0;
            align-items: center; /* Center charts */
        }
        .chart-container {
            position: relative;
            width: 140px; /* Slightly larger charts */
            height: 140px;
            background-color: var(--card-bg); /* Ensure chart background matches card */
            border-radius: var(--radius-main); /* Match card radius */
            padding: 0.5rem; /* Padding for chart */
            box-sizing: border-box;
        }

        /* Footer Panel */
        .footer-panel {
            width: 100%;
            max-width: 1400px;
            display: flex; /* Changed from grid to flex container */
            flex-direction: column; /* Stack children vertically */
            gap: 2rem; /* Gap between system-info and controls-row */
            margin-top: auto; /* Push to bottom */
            padding: 1.8rem;
            border: 1px solid var(--border-color);
            border-radius: var(--radius-main);
            background-color: var(--card-bg);
            box-shadow: var(--card-shadow);
            align-items: flex-start; /* Align children to start (left) */
        }

        /* System Info card within footer - always full width */
        .system-info-container {
            width: 100%; /* Occupy full width of footer-panel */
            /* No need for grid-column on this specific item anymore */
        }

        /* New container for the 3 control groups in a grid below system info */
        .footer-control-sections {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); /* Auto-fit into up to 3 columns */
            gap: 2rem; /* Gap between control groups */
            width: 100%; /* Occupy full width of footer-panel */
        }

        /* Common styling for control groups (already defined for control-group) */
        .control-group {
            display: flex;
            flex-direction: column;
            gap: 1rem;
            align-items: flex-start;
        }
        /* Specific tweaks for inner elements */
        .toggle-group {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(120px, 1fr)); /* Better toggle layout */
            gap: 0.8rem;
            width: 100%; /* Fill available space */
        }
        .toggle-group label {
            display: flex;
            align-items: center;
            gap: 0.5rem;
            cursor: pointer;
            font-size: 0.95rem;
            padding: 0.5rem 0.8rem; /* Padding for toggle label area */
            background-color: var(--control-bg);
            border: 1px solid var(--control-border);
            border-radius: var(--radius-control);
            transition: all 0.2s ease;
            color: var(--control-text);
        }
        .toggle-group label:hover {
            background-color: var(--control-hover-bg);
            border-color: var(--accent-color);
        }
        .toggle-group input[type="checkbox"] {
            /* Hide default checkbox */
            appearance: none;
            -webkit-appearance: none;
            -moz-appearance: none;
            width: 18px;
            height: 18px;
            border: 2px solid var(--control-border);
            border-radius: 4px;
            background-color: var(--card-bg);
            position: relative;
            cursor: pointer;
            transition: all 0.2s ease;
            flex-shrink: 0;
        }
        .toggle-group input[type="checkbox"]:checked {
            background-color: var(--accent-color);
            border-color: var(--accent-color);
        }
        .toggle-group input[type="checkbox"]:checked::after {
            content: '\2713'; /* Checkmark unicode character */
            display: block;
            position: absolute;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            font-size: 14px;
            color: white;
        }

        .action-buttons {
            display: flex;
            gap: 1.2rem; /* More space between buttons */
            align-items: center;
            flex-wrap: wrap;
            margin-top: 0.5rem;
            width: 100%; /* Ensure it takes full width within its parent */
            justify-content: flex-start; /* Default to start alignment */
            flex-direction: column; /* Default to column for grouped buttons */
            align-items: flex-start; /* Align stacked items to the left */
        }
        .action-buttons button {
            padding: 0.7rem 1.4rem; /* Larger buttons */
            border-radius: var(--radius-control);
            border: 1px solid var(--control-border);
            background-color: var(--control-bg);
            color: var(--control-text);
            font-size: 0.95rem;
            transition: all 0.2s ease-in-out;
            cursor: pointer;
            outline: none;
            display: inline-flex; /* For icon + text alignment */
            align-items: center;
            gap: 0.5rem; /* Space between icon and text */
            width: 100%; /* Make buttons span full width */
            justify-content: center; /* Center content within full width button */
        }
        .action-buttons button:hover {
            background-color: var(--control-hover-bg);
            border-color: var(--accent-color);
            transform: translateY(-2px);
            box-shadow: 0 4px 8px rgba(0, 0, 0, 0.1);
        }
        .action-buttons button.primary {
            background-color: var(--accent-color);
            color: white;
            border-color: var(--accent-color);
        }
        .action-buttons button.primary:hover {
            background-color: var(--gradient-mid);
            border-color: var(--gradient-mid);
        }
        span#last_updated {
            font-size: 0.9rem;
            color: var(--label-color);
            margin-left: 0; /* Reset margin from previous auto-left */
            text-align: left; /* Default to left align */
            width: 100%; /* Take full width below buttons */
        }

        .error {
            color: var(--error-color);
            font-weight: bold;
            background-color: rgba(231, 76, 60, 0.1);
            border: 1px solid var(--error-color);
            padding: 1.5rem;
            border-radius: var(--radius-main);
            margin-top: 2rem;
        }

        /* Loading Spinner */
        #loading-spinner {
            display: none;
            width: 40px;
            height: 40px;
            border: 4px solid var(--border-color);
            border-top-color: var(--accent-color);
            border-radius: 50%;
            animation: spin 1s linear infinite;
            margin: 4rem auto;
        }
        @keyframes spin {
            to { transform: rotate(360deg); }
        }
        .loading #loading-spinner {
            display: block;
        }
        .loading #main-content, .loading .footer-panel {
            opacity: 0.5;
            pointer-events: none;
        }

        /* Responsive */
        @media (max-width: 1280px) {
            .main-container {
                grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); /* Slightly smaller min-width */
            }
        }
        @media (max-width: 992px) {
            body { padding: 1.5rem; }
            .header { margin-bottom: 1.5rem; }
            /* Footer grid layout for medium screens */
            .footer-control-sections { /* The 3 control groups will stack */
                grid-template-columns: 1fr; 
                gap: 1.5rem;
            }
            .card { padding: 1.5rem; }
            .footer-panel { padding: 1.5rem; }
            .action-buttons {
                justify-content: center; /* Center buttons on smaller screens */
                align-items: center; /* Center stacked items for smaller screens */
            }
            span#last_updated {
                margin-left: 0; /* Reset margin on smaller screens */
                text-align: center;
                width: 100%;
            }
            .control-group { /* Target all control groups */
                align-items: center; /* Center content */
            }
            .toggle-group {
                grid-template-columns: repeat(auto-fit, minmax(100px, 1fr));
                justify-content: center;
            }
        }

        @media (max-width: 768px) {
            html { font-size: 15px; } /* Base font smaller */
            body { padding: 1rem; }
            .header h1 { font-size: 2rem; margin-bottom: 0.5rem; }
            .header-gradient-bar { max-width: 120px; height: 4px; margin-bottom: 1rem; }
            .card, .footer-panel { padding: 1rem; border-radius: 0.8rem; }
            h2 { font-size: 1.4rem; margin-bottom: 0.3rem; }
            h3 { font-size: 1.2rem; padding-bottom: 0.4rem; margin-bottom: 0.7rem; }
            .card-content { flex-direction: column; gap: 1rem; }
            .metrics-container {
                grid-template-columns: 1fr; /* Stack labels and values */
                gap: 0.4rem;
            }
            .metrics-container p {
                display: block;
                line-height: 1.3;
            }
            .label, .value {
                text-align: left;
                display: inline;
                padding-right: 0;
            }
            .label::after {
                content: ': ';
            }
            .charts {
                flex-direction: row;
                justify-content: space-around;
                flex-wrap: wrap; /* Allow charts to wrap */
            }
            .chart-container { width: 110px; height: 110px; padding: 0.3rem;}
        }

        @media (max-width: 480px) {
            html { font-size: 14px; }
            .header h1 { font-size: 1.8rem; }
            .header-gradient-bar { max-width: 90px; height: 3px; }
            .card { padding: 0.8rem; }
            .charts { gap: 0.8rem; }
            .chart-container { width: 90px; height: 90px; }
            .toggle-group { grid-template-columns: 1fr; } /* Stack toggles */
            .action-buttons button { padding: 0.6rem 1rem; font-size: 0.85rem; }
            .theme-selector button { min-width: unset; } /* Allow buttons to shrink further */
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>MosDNS 监控面板</h1>
        <div class="header-gradient-bar"></div>
    </div>

    <div id="loading-spinner"></div>

    <div id="main-content" class="main-container">
        <!-- Cache cards will be populated by JS -->
    </div>

    <div class="footer-panel">
        <div class="system-info-container control-group">
            <h3><i class="fas fa-server"></i> 系统信息</h3>
            <div class="metrics-container" id="metrics-system"></div>
        </div>

        <div class="footer-control-sections"> <!-- New container for grid controls -->
            <div class="card-toggle-container control-group">
                <h3><i class="fas fa-eye"></i> 显示卡片</h3>
                <div class="toggle-group" id="card-toggles">
                    <!-- Toggles will be generated by JS -->
                </div>
            </div>
            
            <div class="theme-control-group control-group">
                <h3><i class="fas fa-palette"></i> 主题切换</h3>
                <div class="theme-selector" id="theme-selector">
                    <!-- Theme buttons will be populated by JS -->
                </div>
            </div>

            <div class="refresh-cache-control-group control-group">
                <h3><i class="fas fa-tools"></i> 操作与刷新</h3>
                <div class="toggle-group">
                    <label>
                        <input type="checkbox" id="auto-refresh-toggle"> 启用自动刷新 (5s)
                    </label>
                </div>
                <div class="action-buttons">
                    <button id="refresh-now-btn" class="primary"><i class="fas fa-sync-alt"></i> 立即刷新</button>
                    <button id="flush-cache-btn"><i class="fas fa-broom"></i> 清空 FakeIP 缓存</button>
                    <span id="last_updated"><i class="fas fa-clock"></i> </span>
                </div>
            </div>
        </div>
    </div>

    <script>
        const API_URL = '/api/mosdns_status';
        const FLUSH_ENDPOINT = '/api/flush_fakeip_cache';
        const REFRESH_INTERVAL = 5000;
        let chartInstances = {};
        let autoRefreshTimer;
        let isRefreshing = false; // Prevent multiple simultaneous fetches

        // --- 修复点：注册 Chart.js 插件 ---
        Chart.register(ChartDataLabels);

        // Helper function to create HTML elements
        function createElement(tag, className, innerText = '') {
            const el = document.createElement(tag);
            if (className) el.className = className;
            if (innerText) el.innerText = innerText;
            return el;
        }

        // Helper for number formatting
        function formatNumber(num) {
            if (typeof num !== 'number') {
                num = parseFloat(num);
                if (isNaN(num)) return num; // If it's truly not a number, return as is
            }
            if (num >= 1000000) {
                return (num / 1000000).toFixed(1) + 'M';
            }
            if (num >= 1000) {
                return (num / 1000).toFixed(1) + 'K';
            }
            return num.toLocaleString();
        }

        // --- Theme handling ---
        const themeMap = {
            'light': { name: '默认亮色', icon: 'fa-sun' },
            'dark': { name: '默认暗色', icon: 'fa-moon' },
            'cyberpunk': { name: '赛博朋克', icon: 'fa-robot' },
            'forest': { name: '静谧森林', icon: 'fa-tree' },
            'sunset': { name: '日落余晖', icon: 'fa-cloud-sun-rain' },
            'monochrome': { name: '高级灰', icon: 'fa-grip-lines' }
        };
        const body = document.body; // Reference to the body element
        const themeSelector = document.getElementById('theme-selector'); // Now in the footer

        function setTheme(mode) {
            body.className = '';
            if (mode !== 'light') {
                body.classList.add(`theme-${mode}`);
            }
            localStorage.setItem('theme', mode);
            updateThemeButtons(mode); // Update active button state
            // Force rebuild and chart update to pick up new theme colors
            refreshData(true, true); 
        }

        function updateThemeButtons(activeMode) {
            themeSelector.innerHTML = ''; // Clear existing buttons
            for (const mode in themeMap) {
                const themeData = themeMap[mode];
                const button = createElement('button');
                button.dataset.theme = mode;
                button.innerHTML = `<i class="fas ${themeData.icon}"></i> ${themeData.name}`;
                if (mode === activeMode) {
                    button.classList.add('active');
                }
                button.addEventListener('click', () => setTheme(mode));
                themeSelector.appendChild(button);
            }
        }

        const savedTheme = localStorage.getItem('theme') || 'light';
        updateThemeButtons(savedTheme); // Initialize buttons
        if (savedTheme !== 'light') {
            body.classList.add(`theme-${savedTheme}`);
        }


        // --- Data Fetching and Parsing ---
        async function fetchData() {
            if (isRefreshing) return null; // Prevent multiple fetches
            isRefreshing = true;
            document.body.classList.add('loading'); // Show loading spinner

            try {
                const response = await fetch(API_URL);
                if (!response.ok) {
                    const errorDetails = await response.text();
                    throw new Error(`Network response was not ok: ${response.statusText} (${errorDetails})`);
                }
                return await response.json();
            } catch (error) {
                console.error('Error fetching data:', error);
                const mainContent = document.getElementById('main-content');
                if (mainContent) {
                    mainContent.innerHTML = `<p class="error" style="text-align:center; grid-column: 1 / -1; font-size: 1.2rem; padding: 2rem;">
                        <i class="fas fa-exclamation-triangle"></i> 无法连接到 MosDNS 的 API 接口。
                        <br>请确保 MosDNS 和此监控面板的后端服务正在运行，并且您从正确的地址访问此页面。
                        <br><small>${error.message}</small>
                    </p>`;
                }
                return null;
            } finally {
                isRefreshing = false;
                document.body.classList.remove('loading'); // Hide loading spinner
            }
        }

        // --- UI Rendering ---
        function createCacheCard(tag, title) {
            const card = createElement('div', 'card');
            card.dataset.tag = tag;

            const h2 = createElement('h2');
            const titleText = createElement('span', 'title-text', title);
            const statusDot = createElement('span', 'status-dot');
            statusDot.id = `status-dot-${tag}`;
            h2.append(createElement('i', 'fas fa-server'), titleText, statusDot); // Added icon

            const gradientBar = createElement('div', 'card-title-gradient-bar');

            const cardContent = createElement('div', 'card-content');

            const metricsContainer = createElement('div', 'metrics-container');
            metricsContainer.id = `metrics-${tag}`;

            const chartsContainer = createElement('div', 'charts');
            const totalHitChartContainer = createElement('div', 'chart-container');
            const lazyHitChartContainer = createElement('div', 'chart-container');
            const totalHitCanvas = createElement('canvas');
            const lazyHitCanvas = createElement('canvas');
            totalHitCanvas.id = `chart-hit-${tag}`;
            lazyHitCanvas.id = `chart-lazy-${tag}`;
            totalHitChartContainer.appendChild(totalHitCanvas);
            lazyHitChartContainer.appendChild(lazyHitCanvas);
            chartsContainer.append(totalHitChartContainer, lazyHitChartContainer);

            cardContent.append(metricsContainer, chartsContainer);
            card.append(h2, gradientBar, cardContent);
            return card;
        }

        function createOrUpdatePieChart(id, title, hit, total) {
            const ctx = document.getElementById(id);
            if (!ctx) return;

            const miss = Math.max(0, total - hit);
            const computedStyle = getComputedStyle(body); 

            const hitColor = computedStyle.getPropertyValue('--chart-color-hit').trim();
            const missColor = computedStyle.getPropertyValue('--chart-color-miss').trim();
            const hitBorder = computedStyle.getPropertyValue('--chart-border-hit').trim();
            const missBorder = computedStyle.getPropertyValue('--chart-border-miss').trim();
            const textColor = computedStyle.getPropertyValue('--text-color').trim();

            const data = {
                labels: ['命中', '未命中'],
                datasets: [{
                    data: [hit, miss],
                    backgroundColor: [hitColor, missColor],
                    borderColor: [hitBorder, missBorder],
                    borderWidth: 1.5
                }]
            };

            const options = {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    title: { display: true, text: title, color: textColor, font: { size: 12, weight: 'bold' } },
                    legend: { display: false },
                    datalabels: {
                        formatter: (value, context) => {
                            const sum = context.chart.data.datasets[0].data.reduce((a, b) => a + b, 0);
                            if (sum === 0) return value === 0 ? '' : `${value}`;
                            const percentage = (value / sum * 100);
                            return percentage > 5 ? `${percentage.toFixed(percentage < 10 ? 1 : 0)}%` : '';
                        },
                        color: textColor,
                        font: { weight: 'bold', size: 11 }
                    }
                },
                cutout: '70%',
            };

            if (chartInstances[id]) {
                chartInstances[id].data = data;
                chartInstances[id].options.plugins.title.color = textColor;
                chartInstances[id].options.plugins.datalabels.color = textColor;
                chartInstances[id].update('none'); // Update without animation for smoother refresh
            } else {
                chartInstances[id] = new Chart(ctx, { type: 'doughnut', data, options, plugins: [ChartDataLabels] });
            }
        }

        function updateMetrics(containerId, metricsData) {
            const container = document.getElementById(containerId);
            if (!container) return;
            container.innerHTML = '';
            metricsData.forEach(metric => {
                const p = createElement('p');
                const labelSpan = createElement('span', 'label', metric.label);
                const valueSpan = createElement('span', 'value', metric.value);

                if (metric.numericValue !== undefined) {
                    valueSpan.innerText = formatNumber(metric.numericValue);
                } else if (metric.value.includes('%')) {
                    valueSpan.innerText = metric.value;
                } else {
                    valueSpan.innerText = metric.value;
                }

                if (metric.accent) valueSpan.classList.add('accent');
                p.append(labelSpan, valueSpan);
                container.appendChild(p);
            });
        }

        // --- Card Toggles Logic ---
        const cacheOrder = ['cache_all', 'cache_cn', 'cache_google', 'cache_node'];
        const cacheTitles = {
            'cache_all': '全部缓存', 'cache_cn': '国内缓存', 'cache_google': '国外缓存', 'cache_node': '节点缓存'
        };
        let visibleCards = JSON.parse(localStorage.getItem('visibleMosdnsCards')) || cacheOrder;

        function setupCardToggles() {
            const toggleContainer = document.getElementById('card-toggles');
            toggleContainer.innerHTML = '';
            cacheOrder.forEach(tag => {
                const label = createElement('label');
                const checkbox = createElement('input');
                checkbox.type = 'checkbox';
                checkbox.dataset.tag = tag;
                checkbox.checked = visibleCards.includes(tag);
                checkbox.addEventListener('change', handleToggleChange);
                label.append(checkbox, document.createTextNode(cacheTitles[tag]));
                toggleContainer.appendChild(label);
            });
        }
        function handleToggleChange(event) {
            const tag = event.target.dataset.tag;
            if (event.target.checked) {
                if (!visibleCards.includes(tag)) visibleCards.push(tag);
            } else {
                visibleCards = visibleCards.filter(t => t !== tag);
            }
            localStorage.setItem('visibleMosdnsCards', JSON.stringify(visibleCards));
            // Card visibility change requires full rebuild to show/hide elements cleanly
            refreshData(true, true); 
        }

        // --- Auto-refresh toggle logic ---
        const autoRefreshToggle = document.getElementById('auto-refresh-toggle');
        let autoRefreshEnabled = false;

        function startAutoRefresh() {
            if (autoRefreshTimer) clearInterval(autoRefreshTimer); // Clear existing timer first
            autoRefreshTimer = setInterval(() => {
                // For auto-refresh, we only update data and charts (if needed), no full rebuild
                refreshData(false, true); // updateCharts set to true here to keep charts updated
            }, REFRESH_INTERVAL);
            console.log('Auto-refresh started.');
        }

        function stopAutoRefresh() {
            if (autoRefreshTimer) {
                clearInterval(autoRefreshTimer);
                autoRefreshTimer = null;
                console.log('Auto-refresh stopped.');
            }
        }

        autoRefreshToggle.addEventListener('change', () => {
            autoRefreshEnabled = autoRefreshToggle.checked;
            localStorage.setItem('autoRefresh', autoRefreshEnabled);
            if (autoRefreshEnabled) {
                startAutoRefresh();
            } else {
                stopAutoRefresh();
            }
        });

        // --- Main Execution ---
        async function refreshData(forceRebuild = false, updateCharts = false) {
            const data = await fetchData();
            if (!data) {
                 // If data fetching failed, stop auto-refresh temporarily
                stopAutoRefresh();
                autoRefreshToggle.checked = false; // Uncheck toggle
                autoRefreshEnabled = false;
                localStorage.setItem('autoRefresh', false);
                return;
            } else if (autoRefreshEnabled && !autoRefreshTimer) {
                // If data fetching succeeded after failure, and auto-refresh is enabled, restart
                startAutoRefresh();
            }

            const mainContent = document.getElementById('main-content');

            if (forceRebuild) {
                // If rebuilding, clear all existing cards and destroy charts
                mainContent.innerHTML = '';
                Object.values(chartInstances).forEach(chart => chart.destroy());
                chartInstances = {};

                // Re-create cards for visible ones
                cacheOrder.forEach(tag => {
                    if (data.caches[tag] && visibleCards.includes(tag)) { // Only create if visible
                        mainContent.appendChild(createCacheCard(tag, cacheTitles[tag]));
                    }
                });
                // NO LONGER append system info here. It lives permanently in the footer.
            }
            
            // Always update metrics and charts for visible cards (if updateCharts is true)
            cacheOrder.forEach(tag => {
                const card = mainContent.querySelector(`.card[data-tag="${tag}"]`);
                if (card) {
                    // Always set visibility class, regardless of forceRebuild
                    card.classList.toggle('visible', visibleCards.includes(tag));

                    if(visibleCards.includes(tag)) { // Only update if card is visible
                        const cardData = data.caches[tag];
                        updateMetrics(`metrics-${tag}`, [
                            { label: '请求总数', numericValue: cardData.query_total },
                            { label: '缓存命中', numericValue: cardData.hit_total },
                            { label: '过期缓存命中', numericValue: cardData.lazy_hit_total },
                            { label: '缓存命中率', value: cardData.hit_rate, accent: true },
                            { label: '过期缓存命中率', value: cardData.lazy_hit_rate, accent: true },
                            { label: '缓存条目数', numericValue: cardData.size_current },
                        ]);

                        const statusDot = document.getElementById(`status-dot-${tag}`);
                        if (statusDot) {
                            statusDot.classList.remove('status-green', 'status-yellow');
                            statusDot.classList.add(cardData.query_total > 0 ? 'status-green' : 'status-yellow');
                        }
                        if(updateCharts) { // Only update/create charts if explicitly requested
                            createOrUpdatePieChart(`chart-hit-${tag}`, '命中', cardData.hit_total, cardData.query_total);
                            createOrUpdatePieChart(`chart-lazy-${tag}`, '过期命中', cardData.lazy_hit_total, cardData.query_total);
                        }
                    }
                }
            });

            // System info update is always done on the fixed element in the footer
            updateMetrics('metrics-system', [
                { label: '启动时间', value: data.system.start_time },
                { label: 'CPU 时间', value: data.system.cpu_time },
                { label: '常驻内存 (RSS)', value: data.system.resident_memory },
                { label: '待用堆内存 (Idle)', value: data.system.heap_idle_memory },
                { label: 'Go 版本', value: data.system.go_version, accent: true },
                { label: '线程数', numericValue: data.system.threads },
                { label: '打开文件描述符', numericValue: data.system.open_fds },
            ]);

            document.getElementById('last_updated').innerHTML = `<i class="fas fa-clock"></i> 最后更新: ${new Date().toLocaleTimeString()}`;
        }

        document.getElementById('refresh-now-btn').addEventListener('click', () => {
            // Manual refresh button should update data and charts
            refreshData(false, true); 
        });

        document.getElementById('flush-cache-btn').addEventListener('click', async () => {
            if (window.confirm("确定要清空 FakeIP 缓存吗？ (这将调用 /plugins/cache/flush 接口)")) {
                try {
                    const response = await fetch(FLUSH_ENDPOINT, { method: 'POST' });
                    if (response.ok) {
                        alert("FakeIP 缓存已清空！页面将刷新。");
                        // After flush, force a full rebuild and chart update
                        await refreshData(true, true);
                    } else {
                        const errorData = await response.json();
                        alert(`清空失败: ${errorData.error || response.statusText}`);
                    }
                } catch (error) {
                    console.error('清空缓存请求出错:', error);
                    alert(`请求出错: ${error.message}`);
                }
            }
        });
        
        // Initial setup on page load
        setupCardToggles();
        
        // Retrieve auto-refresh preference from localStorage
        const savedAutoRefresh = localStorage.getItem('autoRefresh');
        if (savedAutoRefresh === null) { // First time user, default to true
            autoRefreshEnabled = true;
        } else {
            autoRefreshEnabled = savedAutoRefresh === 'true';
        }
        autoRefreshToggle.checked = autoRefreshEnabled;

        // Initial data load: full rebuild and chart creation
        refreshData(true, true); 

        // Start auto-refresh if enabled
        if (autoRefreshEnabled) {
            startAutoRefresh();
        } else {
            stopAutoRefresh();
        }

    </script>
</body>
</html>
EOF

    if [ $? -ne 0 ]; then
        log_error "无法创建 index.html 文件。"
        return 1
    fi
    run_command chown "$WEB_USER:$WEB_USER" "$PROJECT_DIR/templates/index.html"
    log_info "HTML 前端页面 (index.html) 已创建。"

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
options=("部署 MosDNS 监控面板" "回滚/清理部署" "一键诊断并尝试修复" "退出")
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
