from flask import Flask, request, jsonify, render_template, abort
import time
import os
from datetime import datetime

app = Flask(__name__)

# ================= 新增：Jinja2 自定义过滤器 =================
@app.template_filter('datetime')
def format_datetime(value):
    """将时间戳格式化为可读日期时间"""
    if not value:
        return "-"
    try:
        return datetime.fromtimestamp(float(value)).strftime('%Y-%m-%d %H:%M:%S')
    except Exception:
        return "-"

# ================= 配置 =================
AUTH_TOKEN = "hard-core-v7"
OFFLINE_THRESHOLD = 30  # 30秒无心跳视为离线

# ================= 内存数据库 =================
# 结构: { "nodes": { "hostname": { "last_update": ts, "name": "别名", "data": {...} } } }
GLOBAL_STATE = {
    "nodes": {}
}

# ================= 工具函数 =================
def format_uptime_smart(boot_ts):
    """智能格式化运行时间 (e.g. 5d 12h)"""
    if not boot_ts: return "-"
    uptime_sec = time.time() - boot_ts
    if uptime_sec < 0: uptime_sec = 0
    days = int(uptime_sec // 86400)
    hours = int((uptime_sec % 86400) // 3600)
    mins = int((uptime_sec % 3600) // 60)
    if days > 0: return f"{days}d {hours}h"
    return f"{hours}h {mins}m"

def format_bytes(size):
    """将字节转换为易读格式 (e.g. 1.2G, 500M)"""
    if not size: return "0"
    power = 1024
    n = 0
    power_labels = {0 : '', 1: 'K', 2: 'M', 3: 'G', 4: 'T'}
    while size > power and n < 4:
        size /= power
        n += 1
    return f"{size:.1f}{power_labels.get(n, '')}"

# ================= 核心路由 =================

# --- 1. 数据接收接口 (Agent -> Server) ---
@app.route('/report', methods=['POST'])
def receive_report():
    payload = request.json
    if not payload or payload.get("token") != AUTH_TOKEN:
        return jsonify({"error": "Unauthorized"}), 403

    # 提取身份
    node_info = payload.get("node_info", {})
    hostname = node_info.get("hostname")
    if not hostname:
        # 兼容旧版
        hostname = payload.get("system", {}).get("hostname", "unknown")
    
    node_name = node_info.get("name", hostname)

    # 存入内存
    GLOBAL_STATE["nodes"][hostname] = {
        "last_update": time.time(),
        "name": node_name,
        "data": payload
    }
    return jsonify({"status": "ok"})

# --- 2. 前端 API 接口 (JS -> Server) [核心修复] ---
@app.route('/api/fleet_status')
def api_fleet_status():
    """为前端提供实时跳动的数据源 (计算逻辑下沉到后端)"""
    now = time.time()
    nodes_list = []
    
    for hostname, info in GLOBAL_STATE["nodes"].items():
        last_ts = info.get("last_update", 0)
        is_offline = (now - last_ts) > OFFLINE_THRESHOLD
        
        raw_data = info.get("data", {})
        sys = raw_data.get("system", {})
        bot = raw_data.get("bot", {})
        
        # --- 深度计算逻辑 ---
        # 1. 内存: 算出 "已用/总量"
        mem_pct = sys.get("mem_pct", 0)
        mem_total = sys.get("mem_total", 0)
        mem_used_bytes = mem_total * (mem_pct / 100)
        mem_str = f"{mem_pct}% ({format_bytes(mem_used_bytes)}/{format_bytes(mem_total)})"
        
        # 2. 硬盘
        disk_pct = sys.get("disk_pct", 0)
        disk_total = sys.get("disk_total", 0)
        disk_used_bytes = disk_total * (disk_pct / 100)
        disk_str = f"{disk_pct}% ({format_bytes(disk_used_bytes)}/{format_bytes(disk_total)})"
        
        # 3. CPU 描述
        cpu_cores = sys.get("cpu_cores", 1)
        cpu_str = f"{sys.get('cpu_pct', 0)}% ({cpu_cores}C)"
        
        # 4. 流量统计 (Total & Avg)
        boot_time = sys.get("boot_time", now)
        uptime_days = (now - boot_time) / 86400
        if uptime_days < 0.01: uptime_days = 0.01 # 避免除零
        
        sent_total = sys.get("net_sent_total", 0)
        recv_total = sys.get("net_recv_total", 0)
        traffic_total = sent_total + recv_total
        
        daily_avg = traffic_total / uptime_days
        traffic_str = f"Tot {format_bytes(traffic_total)} · Day {format_bytes(daily_avg)}"

        # 构造精简对象供前端渲染
        nodes_list.append({
            "hostname": hostname,
            "name": info.get("name"),
            "is_offline": is_offline,
            
            # 资源数据 (已格式化为字符串)
            "cpu_text": cpu_str,         # e.g. "20% (2C)"
            "mem_text": mem_str,         # e.g. "49% (2G/4G)"
            "disk_text": disk_str,       # e.g. "8% (20G/100G)"
            
            # 网络数据
            "up_speed": sys.get("up_kb", 0),
            "down_speed": sys.get("down_kb", 0),
            "traffic_text": traffic_str, # e.g. "Total 4.8G | Avg 1.2G/D"
            
            # 状态数据
            "uptime": format_uptime_smart(boot_time),
            
            # 这里的 has_bot 决定了前端是否显示 CONSOLE 按钮
            "has_bot": bot.get("has_bot", False),
            
            # [修复关键点] 使用 (or {}) 技巧防止 NoneType 报错
            # 原理解析：如果 get 返回 None，则变成了 None or {}，即 {}，后续 safe
            "bot_mode": (bot.get("autopilot") or {}).get("current_mode"),
            
            # 排序权重 (在线优先)
            "_sort_score": 0 if is_offline else 1
        })
    
    # 排序: 在线在前，然后按名字排序
    nodes_list.sort(key=lambda x: (x['_sort_score'], x['name']), reverse=True)
    
    return jsonify({"nodes": nodes_list})

# --- 3. 页面路由 ---
@app.route('/')
def index():
    # 首页骨架 (数据由 JS 加载)
    return render_template('index.html')

@app.route('/node/<hostname>')
def node_detail(hostname):
    # 详情页保持不变 (复用原有逻辑)
    node = GLOBAL_STATE["nodes"].get(hostname)
    if not node:
        return abort(404, description="Node not found.")
    
    data = node.get("data", {})
    last_update = node.get("last_update", 0)
    
    display_data = {
        "is_offline": (time.time() - last_update) > OFFLINE_THRESHOLD,
        "last_update_ts": last_update,
        "system": data.get("system", {}),
        "bot": data.get("bot", {}),
        "logs": data.get("logs", [])
    }
    
    boot_time = display_data["system"].get("boot_time")
    display_data["system"]["uptime_str"] = format_uptime_smart(boot_time)

    return render_template('detail.html', **display_data)

if __name__ == '__main__':
    # 从环境变量读取 Host 和 Port，默认 0.0.0.0:5000
    host = os.getenv('FLASK_HOST', '0.0.0.0')
    port = int(os.getenv('FLASK_PORT', 5000))
    app.run(host=host, port=port)