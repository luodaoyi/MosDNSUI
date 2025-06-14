# Beta/app.py
import os
import sys
import requests
from flask import Flask, render_template, jsonify, Response, request, send_from_directory
from werkzeug.utils import secure_filename
import re
import datetime

app = Flask(__name__)

# --- 全局配置 ---
PROJECT_ROOT = os.path.dirname(os.path.abspath(__file__))
UPLOAD_FOLDER = os.path.join(PROJECT_ROOT, 'uploads')
ALLOWED_EXTENSIONS = {'png', 'jpg', 'jpeg', 'gif', 'webp'}
CUSTOM_BG_FILENAME = 'custom_background'

# 确保上传目录存在
if not os.path.exists(UPLOAD_FOLDER):
    os.makedirs(UPLOAD_FOLDER)

app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER

MOSDNS_ADMIN_URL = os.environ.get('MOSDNS_ADMIN_URL', 'http://127.0.0.1:9099')

# --- 辅助函数 ---
def allowed_file(filename):
    """检查文件后缀是否允许"""
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

def get_current_background_filename():
    """检查是否存在自定义背景文件，并返回其完整文件名"""
    for ext in ALLOWED_EXTENSIONS:
        filepath = os.path.join(app.config['UPLOAD_FOLDER'], f"{CUSTOM_BG_FILENAME}.{ext}")
        if os.path.exists(filepath):
            return f"{CUSTOM_BG_FILENAME}.{ext}"
    return None

# --- 数据获取与解析 ---
def fetch_mosdns_metrics():
    try:
        response = requests.get(f"{MOSDNS_ADMIN_URL}/metrics", timeout=5)
        response.raise_for_status()
        return response.text, None
    except requests.exceptions.RequestException as e:
        return None, f"无法连接到 MosDNS metrics 接口: {e}"

def parse_metrics(metrics_text):
    data = {"caches": {}, "system": {"go_version": "N/A"}}
    patterns = {
        'cache': re.compile(r'mosdns_cache_(\w+)\{tag="([^"]+)"\}\s+([\d.eE+-]+)'),
        'start_time': re.compile(r'^process_start_time_seconds\s+([\d.eE+-]+)'),
        'cpu_time': re.compile(r'^process_cpu_seconds_total\s+([\d.eE+-]+)'),
        'resident_memory': re.compile(r'^process_resident_memory_bytes\s+([\d.eE+-]+)'),
        'heap_idle_memory': re.compile(r'^go_memstats_heap_idle_bytes\s+([\d.eE+-]+)'),
        'threads': re.compile(r'^go_threads\s+(\d+)'),
        'open_fds': re.compile(r'^process_open_fds\s+(\d+)'),
        'go_version': re.compile(r'go_info\{version="([^"]+)"\}')
    }
    for line in metrics_text.split('\n'):
        if (match := patterns['cache'].match(line)):
            metric, tag, value = match.groups()
            if tag not in data["caches"]: data["caches"][tag] = {}
            data["caches"][tag][metric] = float(value)
        elif (match := patterns['start_time'].match(line)): data["system"]["start_time"] = float(match.group(1))
        elif (match := patterns['cpu_time'].match(line)): data["system"]["cpu_time"] = float(match.group(1))
        elif (match := patterns['resident_memory'].match(line)): data["system"]["resident_memory"] = float(match.group(1))
        elif (match := patterns['heap_idle_memory'].match(line)): data["system"]["heap_idle_memory"] = float(match.group(1))
        elif (match := patterns['threads'].match(line)): data["system"]["threads"] = int(match.group(1))
        elif (match := patterns['open_fds'].match(line)): data["system"]["open_fds"] = int(match.group(1))
        elif (match := patterns['go_version'].search(line)): data["system"]["go_version"] = match.group(1)

    for tag, metrics in data["caches"].items():
        query_total = metrics.get("query_total", 0)
        hit_total = metrics.get("hit_total", 0)
        lazy_hit_total = metrics.get("lazy_hit_total", 0)
        metrics["hit_rate"] = f"{(hit_total / query_total * 100):.2f}%" if query_total > 0 else "0.00%"
        metrics["lazy_hit_rate"] = f"{(lazy_hit_total / query_total * 100):.2f}%" if query_total > 0 else "0.00%"
    
    if "start_time" in data["system"] and data["system"]["start_time"]: data["system"]["start_time"] = datetime.datetime.fromtimestamp(data["system"]["start_time"]).strftime('%Y-%m-%d %H:%M:%S')
    if "cpu_time" in data["system"] and data["system"]["cpu_time"]: data["system"]["cpu_time"] = f'{data["system"]["cpu_time"]:.2f} 秒'
    if "resident_memory" in data["system"] and data["system"]["resident_memory"]: data["system"]["resident_memory"] = f'{(data["system"]["resident_memory"] / 1024**2):.2f} MB'
    if "heap_idle_memory" in data["system"] and data["system"]["heap_idle_memory"]: data["system"]["heap_idle_memory"] = f'{(data["system"]["heap_idle_memory"] / 1024**2):.2f} MB'
        
    return data

# --- Flask 路由 ---

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/api/mosdns_status')
def get_mosdns_status():
    metrics_text, error = fetch_mosdns_metrics()
    if error: return jsonify({"error": error}), 502
    return jsonify(parse_metrics(metrics_text))

@app.route('/plugins/<path:subpath>', methods=['GET'])
def proxy_plugins_request(subpath):
    target_url = f"{MOSDNS_ADMIN_URL}/plugins/{subpath}"
    try:
        resp = requests.get(target_url, timeout=10)
        resp.raise_for_status()
        content_type = resp.headers.get('Content-Type', 'text/plain; charset=utf-8')
        return Response(resp.text, status=resp.status_code, content_type=content_type)
    except requests.exceptions.RequestException as e:
        return Response(f"请求 MosDNS 失败: {e}", status=502, mimetype='text/plain')

# --- 背景图片 API ---

@app.route('/api/background_status')
def get_background_status():
    filename = get_current_background_filename()
    if filename: return jsonify({"status": "custom", "url": f"/backgrounds/{filename}"})
    return jsonify({"status": "default"})

@app.route('/backgrounds/<path:filename>')
def serve_background(filename):
    return send_from_directory(app.config['UPLOAD_FOLDER'], filename)

@app.route('/api/upload_background', methods=['POST'])
def upload_background():
    if 'background_image' not in request.files: return jsonify({"error": "请求中没有文件部分"}), 400
    file = request.files['background_image']
    if file.filename == '': return jsonify({"error": "未选择文件"}), 400
    if file and allowed_file(file.filename):
        try:
            old_filename = get_current_background_filename()
            if old_filename: os.remove(os.path.join(app.config['UPLOAD_FOLDER'], old_filename))
            ext = file.filename.rsplit('.', 1)[1].lower()
            new_filename = f"{CUSTOM_BG_FILENAME}.{ext}"
            file.save(os.path.join(app.config['UPLOAD_FOLDER'], new_filename))
            return jsonify({"success": True, "url": f"/backgrounds/{new_filename}"})
        except Exception as e: return jsonify({"error": f"保存文件失败: {e}"}), 500
    return jsonify({"error": "文件类型不允许"}), 400

@app.route('/api/remove_background', methods=['POST'])
def remove_background():
    filename = get_current_background_filename()
    if filename:
        try:
            os.remove(os.path.join(app.config['UPLOAD_FOLDER'], filename))
            return jsonify({"success": True})
        except OSError as e: return jsonify({"error": f"删除文件失败: {e}"}), 500
    return jsonify({"success": True, "message": "没有自定义背景可删除"})

if __name__ == '__main__':
    port = int(os.environ.get('FLASK_PORT', 5002))
    app.run(host='0.0.0.0', port=port, debug=False)
