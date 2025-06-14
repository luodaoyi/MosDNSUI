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
