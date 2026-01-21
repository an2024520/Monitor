import time
import json
import psutil
import requests
import os
import subprocess
import socket
import sys
import platform

# ================= 常量定义 =================
# 机器人路径
PATH_FUTURE_GRID = "/opt/myquant_config/bot_state.json"
PATH_AUTOPILOT = "/opt/myquantbot/autopilot_state.json"
SERVICE_NAME = "myquant"
# ===========================================

IS_WINDOWS = platform.system() == "Windows"

class SidecarAgent:
    def __init__(self):
        # 1. 配置加载 (优先环境变量)
        self.server_url = os.getenv("AGENT_REPORT_URL", "http://127.0.0.1:5000/report")
        self.auth_token = os.getenv("AGENT_TOKEN", "hard-core-v7")
        
        # [修改] 优先读取部署脚本注入的 AGENT_NAME，如果没有则用主机名
        self.node_name = os.getenv("AGENT_NAME", socket.gethostname())
        
        self.hostname = socket.gethostname()
        self.last_net_io = psutil.net_io_counters()
        self.last_net_time = time.time()
        
        mode = "🛠️ Windows 调试模式" if IS_WINDOWS else "🚀 Linux 生产模式"
        print(f"\n>>> [Agent] 探针启动 ({mode})")
        print(f">>> [Agent] 节点名称: {self.node_name}")
        print(f">>> [Agent] 监控中枢: {self.server_url}")
        print(f">>> [Agent] 身份令牌: {self.auth_token}")
        print("------------------------------------------------")

    def _get_system_stats(self):
        """采集通用主机指标 (v4.0 增强版)"""
        # 1. CPU
        cpu_pct = psutil.cpu_percent(interval=None)
        cpu_cores = psutil.cpu_count(logical=True)
        
        # 2. 内存
        mem = psutil.virtual_memory()
        
        # 3. 硬盘
        try:
            disk_path = 'C:\\' if IS_WINDOWS else '/'
            disk = psutil.disk_usage(disk_path)
        except:
            disk = psutil.disk_usage('/')

        # 4. 网络速率 & 总量
        curr_net = psutil.net_io_counters()
        curr_time = time.time()
        time_delta = curr_time - self.last_net_time
        
        up_speed = 0
        down_speed = 0
        
        if time_delta > 0.1:
            sent_diff = curr_net.bytes_sent - self.last_net_io.bytes_sent
            recv_diff = curr_net.bytes_recv - self.last_net_io.bytes_recv
            up_speed = round(sent_diff / time_delta / 1024, 1)
            down_speed = round(recv_diff / time_delta / 1024, 1)
            
            self.last_net_io = curr_net
            self.last_net_time = curr_time

        return {
            "hostname": self.hostname,
            "node_name": self.node_name,
            
            # --- 核心指标 ---
            "boot_time": psutil.boot_time(),
            "cpu_pct": cpu_pct,
            "mem_pct": mem.percent,
            "disk_pct": disk.percent,
            
            # --- 绝对值指标 ---
            "cpu_cores": cpu_cores,
            "mem_total": mem.total,
            "disk_total": disk.total,
            "net_sent_total": curr_net.bytes_sent,
            "net_recv_total": curr_net.bytes_recv,
            
            # --- 速率指标 ---
            "up_kb": up_speed,
            "down_kb": down_speed,
        }

    def _read_json_safe(self, path):
        if not os.path.exists(path):
            return None
        try:
            with open(path, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception:
            return None

    def _get_bot_logs(self):
        if IS_WINDOWS:
            return ["(Windows 环境: 跳过 Linux 日志抓取)"]
        try:
            ret_code = subprocess.call(
                ["systemctl", "is-active", "--quiet", SERVICE_NAME], 
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            if ret_code != 0: return ["⚠️ 服务未运行"]
            cmd = ["journalctl", "-u", SERVICE_NAME, "-n", "15", "--no-pager", "--output", "cat"]
            result = subprocess.check_output(cmd, text=True, encoding='utf-8', errors='ignore')
            return result.strip().split('\n')
        except Exception as e:
            return [f"日志获取失败: {str(e)}"]

    def run(self):
        print(">>> [Agent] 开始循环上报...")
        while True:
            try:
                sys_stats = self._get_system_stats()
                
                payload = {
                    "token": self.auth_token,
                    "timestamp": int(time.time()),
                    "type": "heartbeat",
                    "node_info": {
                        "hostname": self.hostname,
                        "name": self.node_name  # 使用环境变量或默认值
                    },
                    "system": sys_stats,
                    "bot": {
                        "has_bot": False,
                        "future_grid": None,
                        "autopilot": None
                    },
                    "logs": []
                }

                grid_state = self._read_json_safe(PATH_FUTURE_GRID)
                autopilot_state = self._read_json_safe(PATH_AUTOPILOT)
                
                if grid_state or autopilot_state:
                    payload["bot"]["has_bot"] = True
                    payload["bot"]["future_grid"] = grid_state
                    payload["bot"]["autopilot"] = autopilot_state
                    payload["logs"] = self._get_bot_logs()

                try:
                    headers = {'Content-Type': 'application/json'}
                    resp = requests.post(self.server_url, json=payload, headers=headers, timeout=3)
                    
                    ts = time.strftime('%H:%M:%S')
                    status = resp.status_code
                    if status == 200:
                        print(f"[{ts}] 上报 ✅ | 流量: {sys_stats['net_sent_total']//1024//1024} MB")
                    else:
                        print(f"[{ts}] 上报失败 ❌ | HTTP {status}")
                        
                except requests.exceptions.RequestException as e:
                    print(f"[{time.strftime('%H:%M:%S')}] 连接错误: {e}")

            except Exception as e:
                print(f"Agent Critical Error: {e}", file=sys.stderr)
            
            time.sleep(3)

if __name__ == "__main__":
    agent = SidecarAgent()
    agent.run()