#!/bin/bash

# ========================================================
#  MyQuant Native Agent (Shell + jq 版)
#  功能：1:1 复刻 Python 版探针，零 Python 依赖
# ========================================================

# 1. 接收环境变量 (由 Systemd 注入)
SERVER_URL="${AGENT_REPORT_URL:-http://127.0.0.1:30308/report}"
AUTH_TOKEN="${AGENT_TOKEN:-hard-core-v7}"
NODE_NAME="${AGENT_NAME:-$(hostname)}"
INTERVAL=3

# 机器人路径 (保持与 Python 版一致)
PATH_FUTURE_GRID="/opt/myquant_config/bot_state.json"
PATH_AUTOPILOT="/opt/myquantbot/autopilot_state.json"
SERVICE_TO_LOG="myquant" # 需监控日志的目标服务名

# 2. 依赖检查
if ! command -v jq &> /dev/null; then
    echo "❌ Critical: 'jq' not found. Please install jq."
    exit 1
fi

# --------------------------------------------------------
# 辅助函数
# --------------------------------------------------------

# 获取当前网卡流量 (Bytes)
# [修改后] 强制输出纯数字，修复崩溃 Bug
get_net_bytes() {
    cat /proc/net/dev | awk '/eth0|ens|eno|enp|wlan/{rx+=$2; tx+=$10} END{printf "%.0f %.0f", rx, tx}'
}

# 安全读取 JSON 文件 (如果文件不存在或格式错误，返回 null)
read_json_file() {
    local fpath="$1"
    if [ -f "$fpath" ]; then
        # 使用 jq . 验证 JSON 合法性，非法则输出 null
        cat "$fpath" | jq . 2>/dev/null || echo "null"
    else
        echo "null"
    fi
}

# 获取日志并转为 JSON 数组
get_logs_json() {
    if systemctl is-active --quiet "$SERVICE_TO_LOG"; then
        # 获取最后 15 行 -> 转为纯文本 -> jq 封装为数组
        journalctl -u "$SERVICE_TO_LOG" -n 15 --no-pager --output cat \
        | jq -R -s 'split("\n") | map(select(length > 0))'
    else
        # 返回含有一个错误提示的数组
        echo '["⚠️ 服务未运行"]'
    fi
}

# --------------------------------------------------------
# 主循环
# --------------------------------------------------------

# 初始化网络计数
read last_rx last_tx <<< $(get_net_bytes)
echo ">>> [Native Agent] 启动: $NODE_NAME -> $SERVER_URL"

while true; do
    # === A. 采集系统基础指标 ===
    
    # 1. Boot Time & Uptime
    uptime_sec=$(awk '{print $1}' /proc/uptime)
    now_sec=$(date +%s)
    # 算术运算：当前时间戳 - 运行秒数 = 启动时间戳
    boot_time=$(awk "BEGIN {print $now_sec - $uptime_sec}")

    # 2. CPU (使用 top 批处理模式获取空闲率，然后 100 - idle)
    # 注意：这是最通用的方法，适配各种 Linux 发行版
    cpu_idle=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print $1}')
    cpu_pct=$(awk "BEGIN {print 100 - $cpu_idle}")
    cpu_cores=$(nproc)

    # 3. 内存
    # total used free shared buff/cache available
    # 使用 available 计算更准确
    mem_info=$(free -b | grep Mem)
    mem_total=$(echo $mem_info | awk '{print $2}')
    mem_avail=$(echo $mem_info | awk '{print $7}')
    mem_pct=$(awk "BEGIN {printf \"%.1f\", ($mem_total - $mem_avail) / $mem_total * 100}")

    # 4. 硬盘 (根目录)
    disk_info=$(df -B1 / | tail -1)
    disk_total=$(echo $disk_info | awk '{print $2}')
    disk_pct=$(echo $disk_info | awk '{print $5}' | tr -d '%')

    # 5. 网络速率计算
    read curr_rx curr_tx <<< $(get_net_bytes)
    
    diff_rx=$((curr_rx - last_rx))
    diff_tx=$((curr_tx - last_tx))
    
    # 换算为 KB/s
    down_kb=$(awk "BEGIN {printf \"%.1f\", $diff_rx / 1024 / $INTERVAL}")
    up_kb=$(awk "BEGIN {printf \"%.1f\", $diff_tx / 1024 / $INTERVAL}")

    # 更新旧值
    last_rx=$curr_rx
    last_tx=$curr_tx


    # === B. 读取机器人状态 (核心难点) ===
    
    grid_json=$(read_json_file "$PATH_FUTURE_GRID")
    autopilot_json=$(read_json_file "$PATH_AUTOPILOT")
    logs_json=$(get_logs_json)
    
    # 判断 has_bot 逻辑: 只要有一个状态不为 null，则为 true
    has_bot="false"
    if [ "$grid_json" != "null" ] || [ "$autopilot_json" != "null" ]; then
        has_bot="true"
    fi


    # === C. 使用 jq 组装最终 Payload (1:1 结构还原) ===
    # 使用 --argjson 确保数字和对象不被转为字符串
    
    JSON_PAYLOAD=$(jq -n \
        --arg token "$AUTH_TOKEN" \
        --argjson ts "$(date +%s)" \
        --arg hostname "$(hostname)" \
        --arg name "$NODE_NAME" \
        --argjson boot_time "$boot_time" \
        --argjson cpu_pct "$cpu_pct" \
        --argjson cpu_cores "$cpu_cores" \
        --argjson mem_pct "$mem_pct" \
        --argjson mem_total "$mem_total" \
        --argjson disk_pct "$disk_pct" \
        --argjson disk_total "$disk_total" \
        --argjson net_sent "$curr_tx" \
        --argjson net_recv "$curr_rx" \
        --argjson up_kb "$up_kb" \
        --argjson down_kb "$down_kb" \
        --argjson has_bot "$has_bot" \
        --argjson grid "$grid_json" \
        --argjson auto "$autopilot_json" \
        --argjson logs "$logs_json" \
        '{
            token: $token,
            timestamp: $ts,
            type: "heartbeat",
            node_info: {
                hostname: $hostname,
                name: $name
            },
            system: {
                boot_time: $boot_time,
                cpu_pct: $cpu_pct,
                cpu_cores: $cpu_cores,
                mem_pct: $mem_pct,
                mem_total: $mem_total,
                disk_pct: $disk_pct,
                disk_total: $disk_total,
                net_sent_total: $net_sent,
                net_recv_total: $net_recv,
                up_kb: $up_kb,
                down_kb: $down_kb
            },
            bot: {
                has_bot: $has_bot,
                future_grid: $grid,
                autopilot: $auto
            },
            logs: $logs
        }')

    # === D. 发送数据 ===
    # --connect-timeout 2: 防止断网时卡死
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 2 \
        --max-time 5 \
        -X POST "$SERVER_URL" \
        -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD")

    if [ "$HTTP_CODE" -eq 200 ]; then
        echo "[$(date +%H:%M:%S)] 上报 ✅ | CPU: ${cpu_pct}% MEM: ${mem_pct}%"
    else
        echo "[$(date +%H:%M:%S)] 上报 ❌ | HTTP $HTTP_CODE"
    fi

    sleep $INTERVAL
done