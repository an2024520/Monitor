import time
import json
import psutil
import requests
import os
import subprocess
import socket
import sys

# ================= 配置区域 =================
# 1. 监控服务端 (VPS B) 的地址
# 注意：部署完 VPS B 后，记得回来把这个 IP 改成 VPS B 的公网 IP
SERVER_URL = "http://127.0.0.1:5000/report" 

# 2. 鉴权口令 (必须与 VPS B 的配置一致)
AUTH_TOKEN = "hard-core-v7"

# 3. 机器人配置路径 (基于代码审计结果)
# 只要这两个文件存在任意一个，就视为有机器人运行
PATH_FUTURE_GRID = "/opt/myquant_config/bot_state.json"
PATH_AUTOPILOT = "/opt/myquantbot/autopilot_state.json"

# 4. 系统服务名称 (用于抓取日志)
SERVICE_NAME = "myquant"
# ===========================================

class SidecarAgent:
    def __init__(self):
        self.hostname = socket.gethostname()
        # 初始化网络计数器
        self.last_net_io = psutil.net_io_counters()
        self.last_net_time = time.time()
        
        print(f">>> [Agent] 探针启动 | Host: {self.hostname}")
        print(f">>> [Agent] 目标服务器: {SERVER_URL}")

    def _get_system_stats(self):
        """采集通用主机指标"""
        # 1. CPU & 内存
        # interval=None 表示非阻塞，瞬间返回上次调用后的统计
        cpu_pct = psutil.cpu_percent(interval=None)
        mem = psutil.virtual_memory()
        disk = psutil.disk_usage('/')
        
        # 2. 网络速率计算 (KB/s)
        curr_net = psutil.net_io_counters()
        curr_time = time.time()
        time_delta = curr_time - self.last_net_time
        
        up_speed = 0
        down_speed = 0
        
        # 只有时间间隔大于0才计算，防止除以零
        if time_delta > 0.1:
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
        except Exception:
            return None # 读取失败视为不存在，不报错

    def _get_bot_logs(self):
        """从 Systemd 获取最新日志"""
        try:
            # 1. 检查服务是否活跃 (避免对无关机器执行 journalctl)
            # systemctl is-active myquant
            ret_code = subprocess.call(
                ["systemctl", "is-active", "--quiet", SERVICE_NAME], 
                stdout=subprocess.DEVNULL, 
                stderr=subprocess.DEVNULL
            )
            
            if ret_code != 0:
                return []

            # 2. 抓取最后 15 行日志
            # journalctl -u myquant -n 15 --no-pager --output cat
            cmd = ["journalctl", "-u", SERVICE_NAME, "-n", "15", "--no-pager", "--output", "cat"]
            result = subprocess.check_output(cmd, text=True, encoding='utf-8', errors='ignore')
            lines = result.strip().split('\n')
            return lines
        except Exception:
            return []

    def run(self):
        print(">>> [Agent] 开始循环上报...")
        while True:
            try:
                # --- 1. 采集基础数据 (所有机器都有) ---
                sys_stats = self._get_system_stats()
                
                payload = {
                    "token": AUTH_TOKEN,
                    "timestamp": int(time.time()),
                    "type": "heartbeat",
                    "system": sys_stats,
                    "bot": {
                        "has_bot": False,
                        "future_grid": None,
                        "autopilot": None
                    },
                    "logs": []
                }

                # --- 2. 智能探测 (仅在有机器人的机器上执行) ---
                # 检测特定路径是否存在
                grid_state = self._read_json_safe(PATH_FUTURE_GRID)
                autopilot_state = self._read_json_safe(PATH_AUTOPILOT)
                
                if grid_state or autopilot_state:
                    payload["bot"]["has_bot"] = True
                    payload["bot"]["future_grid"] = grid_state
                    payload["bot"]["autopilot"] = autopilot_state
                    # 只有发现机器人时，才去抓取日志
                    payload["logs"] = self._get_bot_logs()

                # --- 3. 发送数据 ---
                # 设置超时为 3 秒，防止 VPS B 挂掉拖累 VPS A
                try:
                    resp = requests.post(SERVER_URL, json=payload, timeout=3)
                    # 调试模式下可以打印，生产环境建议注释掉
                    # if resp.status_code != 200:
                    #     print(f"Server rejected: {resp.status_code}")
                except requests.exceptions.RequestException:
                    # 网络不通是常态，默默忽略，不要 Crash
                    pass

            except Exception as e:
                # 捕获所有未知异常，防止探针挂掉
                print(f"Agent Critical Error: {e}", file=sys.stderr)
            
            # --- 4. 休眠 ---
            time.sleep(3)

if __name__ == "__main__":
    # 启动代理
    agent = SidecarAgent()
    agent.run()