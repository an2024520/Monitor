# ... (前面的配置和 get_net_bytes, read_json_file 等函数保持不变) ...

# --------------------------------------------------------
# 辅助函数：只读取当前 /proc/stat 的数值，不做计算
# --------------------------------------------------------
read_cpu_stat() {
    read -r cpu a b c idle rest < /proc/stat
    # total = user + nice + system + idle
    echo "$((a+b+c+idle)) $idle"
}

# --------------------------------------------------------
# 主循环
# --------------------------------------------------------

# 1. 初始化基准数据 (网络 & CPU)
read last_rx last_tx <<< $(get_net_bytes)
read last_cpu_total last_cpu_idle <<< $(read_cpu_stat)

echo ">>> [Native Agent] 启动: $NODE_NAME -> $SERVER_URL"

while true; do
    # === 关键修改：先 Sleep，利用 Sleep 的时间作为采样窗口 ===
    # 这样计算出的就是这 3 秒内的精准平均值，非常平滑
    sleep $INTERVAL

    # 2. 获取当前数据 (CPU & 网络)
    read curr_cpu_total curr_cpu_idle <<< $(read_cpu_stat)
    read curr_rx curr_tx <<< $(get_net_bytes)

    # 3. 计算 CPU 使用率 (差值法)
    # 现在的 diff_total 大约是 300 (3秒 * 100Hz)，精度极高
    diff_total=$((curr_cpu_total - last_cpu_total))
    diff_idle=$((curr_cpu_idle - last_cpu_idle))
    
    cpu_pct="0.0"
    if [ "$diff_total" -gt 0 ]; then
        # (1 - idle/total) * 100
        cpu_pct=$(awk -v i="$diff_idle" -v t="$diff_total" 'BEGIN {printf "%.1f", (1 - i/t) * 100}')
    fi

    # 4. 计算网络速率
    diff_rx=$((curr_rx - last_rx))
    diff_tx=$((curr_tx - last_tx))
    
    down_kb=$(awk "BEGIN {printf \"%.1f\", $diff_rx / 1024 / $INTERVAL}")
    up_kb=$(awk "BEGIN {printf \"%.1f\", $diff_tx / 1024 / $INTERVAL}")

    # 5. 更新旧值 (为下一轮做准备)
    last_rx=$curr_rx
    last_tx=$curr_tx
    last_cpu_total=$curr_cpu_total
    last_cpu_idle=$curr_cpu_idle

    # === 下面是常规的数据采集和发送 ===
    
    # Boot Time
    uptime_sec=$(awk '{print $1}' /proc/uptime)
    now_sec=$(date +%s)
    boot_time=$(awk "BEGIN {print $now_sec - $uptime_sec}")
    
    cpu_cores=$(nproc)

    # 内存
    mem_info=$(free -b | grep Mem)
    mem_total=$(echo $mem_info | awk '{print $2}')
    mem_avail=$(echo $mem_info | awk '{print $7}')
    mem_pct=$(awk "BEGIN {printf \"%.1f\", ($mem_total - $mem_avail) / $mem_total * 100}")

    # 硬盘
    disk_info=$(df -B1 / | tail -1)
    disk_total=$(echo $disk_info | awk '{print $2}')
    disk_pct=$(echo $disk_info | awk '{print $5}' | tr -d '%')

    # 读取机器人状态
    grid_json=$(read_json_file "$PATH_FUTURE_GRID")
    autopilot_json=$(read_json_file "$PATH_AUTOPILOT")
    logs_json=$(get_logs_json)
    
    has_bot="false"
    if [ "$grid_json" != "null" ] || [ "$autopilot_json" != "null" ]; then
        has_bot="true"
    fi

    # 组装 Payload
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

    # 发送数据
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
    
    # 注意：这里不需要再 sleep $INTERVAL 了，因为循环开头已经 sleep 过了
done