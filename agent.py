import time
import json
import psutil
import requests
import os
import subprocess
import socket

# ================= 配置区域 =================
# 监控服务端 (VPS B) 的地址
SERVER_URL = "http://<VPS_B_IP>:5000/report"  # 请修改为 VPS B 的真实 IP
# 鉴权口令 (必须与 VPS B 一致)
AUTH_TOKEN = "hard-core-v7"

# 机器人配置路径 (根据你的代码审计结果硬编码)
PATH_FUTURE_GRID = "/opt/myquant_config/bot_state.json"
PATH_AUTOPILOT = "/opt/myquantbot/autopilot_state.json"
SERVICE_NAME = "myquant"  # setup.sh 中定义的服务名
# ===========================================

class SidecarAgent:
    def __init__(self):
        self.hostname = socket.gethostname()
        self.last_net_io = psutil.net_io_counters()
        self.last_net_time = time.time()
        
        print(f">>> [Agent] 探针启动 | 目标服务器: {SERVER_URL}")
        print(f">>> [Agent] 监控服务: {SERVICE_NAME}")

    def _get_system_stats(self):
        """采集通用主机指标"""
        # 1. CPU & Mem
        cpu_pct = psutil.cpu_percent(interval=None)
        mem = psutil.virtual_memory()
        disk = psutil.disk_usage('/')
        
        # 2. 网络速率计算 (KB/s)
        curr_net = psutil.net_io_counters()
        curr_time = time.time()
        time_delta = curr_time - self.last_net_time
        
        up_speed = 0
        down_speed = 0
        
        if time_delta > 0:
            sent_diff = curr_net.bytes_sent - self.last_net_io.bytes_sent
            recv_diff = curr_net.bytes_recv - self.last_net_io.bytes_recv
            up_speed = round(sent_diff / time_delta / 1024, 1)   # KB/s
            down_speed = round(recv_diff / time_delta / 1024, 1) # KB/s

        # 更新缓存
        self.last_net_io = curr_net
        self.last_net_time = curr_time

        return {
            "hostname": self.hostname,
            "cpu": cpu_pct,
            "mem_pct": mem.percent,
            "disk_pct": disk.percent,
            "up_kb": up_speed,
            "down_kb": down_speed,
            "uptime_days": round((time.time() - psutil.boot_time()) / 86400, 2)
        }

    def _read_json_safe(self, path):
        """安全读取 JSON，如果文件不存在则返回 None"""
        if not os.path.exists(path):
            return None
        try:
            with open(path, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception as e:
            return {"error": f"Read failed: {str(e)}"}

    def _get_bot_logs(self):
        """从 Systemd 获取最新日志"""
        try:
            # 检查服务是否活跃
            is_active = subprocess.call(["systemctl", "is-active", "--quiet", SERVICE_NAME]) == 0
            if not is_active:
                return ["⚠️ 系统服务未运行"]

            # 抓取最后 20 行日志
            # journalctl -u myquant -n 20 --no-pager --output cat
            cmd = ["journalctl", "-u", SERVICE_NAME, "-n", "20", "--no-pager", "--output", "cat"]
            result = subprocess.check_output(cmd, text=True, encoding='utf-8', errors='ignore')
            lines = result.strip().split('\n')
            return lines
        except Exception:
            return []

    def run(self):
        while True:
            try:
                # 1. 采集数据
                payload = {
                    "token": AUTH_TOKEN,
                    "timestamp": int(time.time()),
                    "system": self._get_system_stats(),
                    "bot": {
                        # 兼容性判断：如果文件不存在，这里就是 None
                        "future_grid": self._read_json_safe(PATH_FUTURE_GRID),
                        "autopilot": self._read_json_safe(PATH_AUTOPILOT),
                        "has_bot": False 
                    },
                    "logs": []
                }

                # 2. 只有当检测到机器人配置文件存在时，才标记为"有机器人"并抓取日志
                if payload["bot"]["future_grid"] or payload["bot"]["autopilot"]:
                    payload["bot"]["has_bot"] = True
                    payload["logs"] = self._get_bot_logs()

                # 3. 发送数据 (超时 3秒，防止卡死)
                try:
                    resp = requests.post(SERVER_URL, json=payload, timeout=3)
                    if resp.status_code != 200:
                        print(f"Server rejected: {resp.status_code}")
                except requests.exceptions.RequestException:
                    # 默默失败，不要打印太多报错刷屏，或者仅打印简短信息
                    pass

            except Exception as e:
                print(f"Agent Error: {e}")
            
            # 4. 休眠 (建议 3-5 秒)
            time.sleep(3)

if __name__ == "__main__":
    # 安装依赖提示
    # pip install psutil requests
    agent = SidecarAgent()
    agent.run()
