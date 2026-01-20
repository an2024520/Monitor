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
# 配置文件存储路径
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE_DIR, "agent_config.json")

# 鉴权口令
AUTH_TOKEN = "hard-core-v7"

# 机器人路径
PATH_FUTURE_GRID = "/opt/myquant_config/bot_state.json"
PATH_AUTOPILOT = "/opt/myquantbot/autopilot_state.json"
SERVICE_NAME = "myquant"
# ===========================================

IS_WINDOWS = platform.system() == "Windows"

class SidecarAgent:
    def __init__(self):
        # 1. 加载或生成配置
        self.config = self._load_or_create_config()
        self.node_name = self.config.get("node_name", socket.gethostname())
        self.server_url = self.config.get("server_url", "http://127.0.0.1:5000/report")
        
        self.hostname = socket.gethostname()
        self.last_net_io = psutil.net_io_counters()
        self.last_net_time = time.time()
        
        mode = "🛠️ Windows 调试模式" if IS_WINDOWS else "🚀 Linux 生产模式"
        print(f"\n>>> [Agent] 探针启动 ({mode})")
        print(f">>> [Agent] 节点名称: {self.node_name}")
        print(f">>> [Agent] 监控中枢: {self.server_url}")
        print("------------------------------------------------")

    def _load_or_create_config(self):
        """交互式配置生成逻辑"""
        if os.path.exists(CONFIG_PATH):
            try:
                with open(CONFIG_PATH, 'r', encoding='utf-8') as f:
                    return json.load(f)
            except Exception:
                pass

        if not sys.stdin.isatty():
            return {"server_url": "http://127.0.0.1:5000/report", "node_name": socket.gethostname()}

        print("\n" + "="*40)
        print("👋 欢迎使用 MyQuant 监控探针 v4.0 (全量采集版)")
        print("="*40)
        
        default_ip = "127.0.0.1"
        server_ip = input(f"1. 请输入监控服务端 IP [默认 {default_ip}]: ").strip() or default_ip
        final_url = server_ip if server_ip.startswith("http") else f"http://{server_ip}:5000/report"

        default_name = socket.gethostname()
        node_name = input(f"2. 请为本机取个名字 [默认 {default_name}]: ").strip() or default_name

        config = {"server_url": final_url, "node_name": node_name}
        try:
            with open(CONFIG_PATH, 'w', encoding='utf-8') as f:
                json.dump(config, f, indent=4, ensure_ascii=False)
            print(f"✅ 配置已保存")
        except Exception as e:
            print(f"❌ 保存失败: {e}")
        
        return config

    def _get_system_stats(self):
        """采集通用主机指标 (v4.0 增强版)"""
        # 1. CPU
        cpu_pct = psutil.cpu_percent(interval=None)
        cpu_cores = psutil.cpu_count(logical=True)  # [新增] 逻辑核数
        
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
            
            # --- [新增] 绝对值指标 (用于高密度展示) ---
            "cpu_cores": cpu_cores,              # 核数 (如 2)
            "mem_total": mem.total,              # 内存总量 (Bytes)
            "disk_total": disk.total,            # 硬盘总量 (Bytes)
            "net_sent_total": curr_net.bytes_sent, # 累计发送 (Bytes)
            "net_recv_total": curr_net.bytes_recv, # 累计接收 (Bytes)
            
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
                    "token": AUTH_TOKEN,
                    "timestamp": int(time.time()),
                    "type": "heartbeat",
                    "node_info": {
                        "hostname": self.hostname,
                        "name": self.node_name
                    },
                    "system": sys_stats,  # 包含新增的绝对值数据
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
                    resp = requests.post(self.server_url, json=payload, timeout=3)
                    ts = time.strftime('%H:%M:%S')
                    # 打印更丰富的调试信息，方便你确认数据是否采集到了
                    print(f"[{ts}] 上报 ✅ | 流量总量: {sys_stats['net_sent_total']//1024//1024} MB")
                except requests.exceptions.RequestException:
                    pass

            except Exception as e:
                print(f"Agent Critical Error: {e}", file=sys.stderr)
            
            time.sleep(3)

if __name__ == "__main__":
    agent = SidecarAgent()
    agent.run()