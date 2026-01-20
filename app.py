from flask import Flask, request, jsonify, render_template
import time
from datetime import datetime

app = Flask(__name__)

# ================= 配置 =================
# 必须与 VPS A 的 agent.py 中的 AUTH_TOKEN 完全一致
AUTH_TOKEN = "hard-core-v7"

# ================= 内存数据库 =================
# 用于暂存 VPS A 发来的最新一次数据
# 结构: { "timestamp": 1234567890, "system": {...}, "bot": {...}, "logs": [...] }
GLOBAL_STATE = {
    "last_update": 0,
    "data": None
}

def format_uptime(seconds):
    """将秒数转换为 1d 2h 格式"""
    if not seconds: return "-"
    days = int(seconds // 86400)
    hours = int((seconds % 86400) // 3600)
    return f"{days}d {hours}h"

@app.template_filter('datetime')
def format_datetime(value):
    if not value: return "-"
    return datetime.fromtimestamp(value).strftime('%Y-%m-%d %H:%M:%S')

# --- 核心接口：接收数据 (由 VPS A 的 agent.py 调用) ---
@app.route('/report', methods=['POST'])
def receive_report():
    # 1. 提取 JSON
    payload = request.json
    if not payload:
        return jsonify({"error": "No data"}), 400

    # 2. 安全校验
    if payload.get("token") != AUTH_TOKEN:
        return jsonify({"error": "Unauthorized"}), 403

    # 3. 更新内存状态
    GLOBAL_STATE["data"] = payload
    GLOBAL_STATE["last_update"] = time.time()
    
    print(f"[{datetime.now().strftime('%H:%M:%S')}] 收到心跳 | Host: {payload.get('system', {}).get('hostname')}")
    return jsonify({"status": "ok"})

# --- 前端接口：网页展示 ---
@app.route('/')
def dashboard():
    data = GLOBAL_STATE["data"]
    last_update = GLOBAL_STATE["last_update"]
    
    # 计算是否离线 (超过 30 秒没收到数据视为离线)
    is_offline = (time.time() - last_update) > 30
    
    # 预处理一些显示数据
    display_data = {
        "is_offline": is_offline,
        "last_update_ts": last_update,
        "system": {},
        "bot": {"has_bot": False},
        "logs": []
    }

    if data:
        display_data["system"] = data.get("system", {})
        display_data["bot"] = data.get("bot", {})
        display_data["logs"] = data.get("logs", [])
        
        # 格式化运行时间
        uptime_days = display_data["system"].get("uptime_days", 0)
        display_data["system"]["uptime_str"] = format_uptime(uptime_days * 86400)

    return render_template('dashboard.html', **display_data)

# --- API 接口：供前端 AJAX 局部刷新 (可选) ---
@app.route('/api/status')
def get_status():
    # 这里的逻辑和 dashboard 类似，返回 JSON 给前端 JS 用
    # 为了简化，初期版本我们可以直接刷新网页
    return jsonify({
        "last_update": GLOBAL_STATE["last_update"],
        "is_offline": (time.time() - GLOBAL_STATE["last_update"]) > 30,
        "data": GLOBAL_STATE["data"]
    })

if __name__ == '__main__':
    # 监听所有 IP，端口 5000
    app.run(host='0.0.0.0', port=5000)