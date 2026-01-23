#!/bin/bash

# ========================================================
#  MyQuant Native Agent (Shell + jq 版) [Fix CPU & Net]
# ========================================================

# 1. 接收环境变量
SERVER_URL="${AGENT_REPORT_URL:-http://127.0.0.1:30308/report}"
AUTH_TOKEN="${AGENT_TOKEN:-hard-core-v7}"
NODE_NAME="${AGENT_NAME:-$(hostname)}"
INTERVAL=3

# 机器人路径
PATH_FUTURE_GRID="/opt/myquant_config/bot_state.json"
PATH_AUTOPILOT="/opt/myquantbot/autopilot_state.json"
SERVICE_TO_LOG="myquant"

# 2. 依赖检查
if ! command -v jq &> /dev/null; then
    echo "❌ Critical: 'jq' not found."
    exit 1
fi

# --------------------------------------------------------
# 核心函数
# --------------------------------------------------------

# [修复] 强制输出纯数字，防止科学计数法导致 Shell 报错
get_net_bytes() {
    cat /proc/net/dev | awk '/eth0|ens|eno|enp|wlan/{rx+=$2; tx+=$10} END{printf "%.0f %.0f", rx, tx}'
}

# [新增] 通过 /proc/stat 计算精准 CPU 使用率 (解决 0/100 跳变问题)
get_cpu_usage() {
    # 第一次读取
    read -r cpu a1 b1 c1 idle1 rest < /proc/stat
    total1=$((a1+b1+c1+idle1))
    
    sleep 0.1  # 采样窗口
    
    # 第二次读取
    read -r cpu a2 b2 c2 idle2 rest < /proc/stat
    total2=$((a2+b2+c2+idle2))

    # 计算差值
    diff_idle=$((idle2 - idle1))
    diff_total=$((total2 - total1))
    
    # 防止除以零
    if [ "$diff_total" -eq 0 ]; then
        echo "0.0"
    else
        # 计算公式: (1 - delta_idle / delta_total) * 100
        awk -v i="$diff_idle" -v t="$diff_total" 'BEGIN {printf "%.1f", (1 - i/t) * 100}'
    fi
}

read_json_file() {
    local fpath="$1"
    if [ -f "$fpath" ]; then
        cat "$fpath" | jq . 2>/dev/null || echo "null"
    else
        echo "null"
    fi
}

get_logs_json() {
    if systemctl is-active --quiet "$SERVICE_TO_LOG"; then
        journalctl -u "$SERVICE_TO_LOG" -n 15 --no-pager --output cat \
        | jq -R -s 'split("\n") | map(select(length > 0))'
    else
        echo '["⚠️ 服务未运行"]'
    fi
}

# --------------------------------------------------------
# 主循环
# --------------------------------------------------------

read last_rx last_tx <<< $(get_net_bytes)
echo ">>> [Native Agent] 启动: $NODE_NAME -> $SERVER_URL"

while true; do
    # 1. Boot Time
    uptime_sec=$(awk '{print $1}' /proc/uptime)
    now_sec=$(date +%s)
    boot_time=$(awk "BEGIN {print $now_sec - $uptime_sec}")

    # 2. [修改] 获取 CPU 使用率 (使用新函数)
    cpu_pct=$(get_cpu_usage)
    cpu_cores=$(nproc)

    # 3. 内存
    mem_info=$(free -b | grep Mem)
    mem_total=$(echo $mem_info | awk '{print $2}')
    mem_avail=$(echo $mem_info | awk '{print $7}')
    mem_pct=$(awk "BEGIN {printf \"%.1f\", ($mem_total - $mem_avail) / $mem_total * 100}")

    # 4. 硬盘
    disk_info=$(df -B1 / | tail -1)
    disk_total=$(echo $disk_info | awk '{print $2}')
    disk_pct=$(echo $disk_info | awk '{print $5}' | tr -d '%')

    # 5. 网络速率
    read curr_rx curr_tx <<< $(get_net_bytes)
    
    diff_rx=$((curr_rx - last_rx))
    diff_tx=$((curr_tx - last_tx))
    
    down_kb=$(awk "BEGIN {printf \"%.1f\", $diff_rx / 1024 / $INTERVAL}")
    up_kb=$(awk "BEGIN {printf \"%.1f\", $diff_tx / 1024 / $INTERVAL}")

    last_rx=$curr_rx
    last_tx=$curr_tx

    # 6. 读取机器人状态
    grid_json=$(read_json_file "$PATH_FUTURE_GRID")
    autopilot_json=$(read_json_file "$PATH_AUTOPILOT")
    logs_json=$(get_logs_json)
    
    has_bot="false"
    if [ "$grid_json" != "null" ] || [ "$autopilot_json" != "null" ]; then
        has_bot="true"
    fi

    # 7. 组装 Payload
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

    # 8. 发送数据
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