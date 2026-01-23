#!/bin/bash

# ========================================================
#  MyQuant Native Agent (Shell + jq 版) [Final]
#  修复内容：
#  1. 修复 CPU 0/100 跳变 (全周期差值算法)
#  2. 修复 大流量科学计数法报错 (printf 格式化)
#  3. 优化 日志抓取 (反向过滤 API 噪音，保留 Bot 关键日志)
# ========================================================

# --- 1. 基础配置 (环境变量优先) ---
SERVER_URL="${AGENT_REPORT_URL:-http://127.0.0.1:30308/report}"
AUTH_TOKEN="${AGENT_TOKEN:-hard-core-v7}"
NODE_NAME="${AGENT_NAME:-$(hostname)}"
INTERVAL=3

# 机器人路径
PATH_FUTURE_GRID="/opt/myquant_config/bot_state.json"
PATH_AUTOPILOT="/opt/myquantbot/autopilot_state.json"
SERVICE_TO_LOG="myquant"

# --- 2. 依赖检查 ---
if ! command -v jq &> /dev/null; then
    echo "❌ Critical: 'jq' not found."
    exit 1
fi

# --------------------------------------------------------
# 核心函数定义
# --------------------------------------------------------

# [修复] 强制输出纯数字，防止大流量导致科学计数法报错
get_net_bytes() {
    cat /proc/net/dev | awk '/eth0|ens|eno|enp|wlan/{rx+=$2; tx+=$10} END{printf "%.0f %.0f", rx, tx}'
}

# [新算法] 读取 CPU 原始计数 (user+nice+system+idle, idle)
read_cpu_stat() {
    read -r cpu a b c idle rest < /proc/stat
    # total = a+b+c+idle
    echo "$((a+b+c+idle)) $idle"
}

# 安全读取 JSON 文件
read_json_file() {
    local fpath="$1"
    if [ -f "$fpath" ]; then
        cat "$fpath" | jq . 2>/dev/null || echo "null"
    else
        echo "null"
    fi
}

# [优化] 获取日志 (反向过滤 API 噪音)
get_logs_json() {
    if systemctl is-active --quiet "$SERVICE_TO_LOG"; then
        # 1. -n 100: 先抓取最近 100 行 (防止最新的日志全是 API 访问记录)
        # 2. --output short-iso: 保留时间戳 (例如 2026-01-23T...)
        # 3. grep -v "GET /api/": 剔除所有包含 API 请求的噪音行
        # 4. tail -n 15: 只取最后有效的 15 行 Bot 日志
        journalctl -u "$SERVICE_TO_LOG" -n 100 --no-pager --output short-iso \
        | grep -v "GET /api/" \
        | tail -n 15 \
        | jq -R -s 'split("\n") | map(select(length > 0))'
    else
        echo '["⚠️ 服务未运行"]'
    fi
}

# --------------------------------------------------------
# 初始化 (基准数据)
# --------------------------------------------------------

# 确保所有变量初始化，防止第一次计算报错
read last_rx last_tx <<< $(get_net_bytes)
read last_cpu_total last_cpu_idle <<< $(read_cpu_stat)

# 防止读取失败导致变量为空
last_rx=${last_rx:-0}
last_tx=${last_tx:-0}
last_cpu_total=${last_cpu_total:-0}
last_cpu_idle=${last_cpu_idle:-0}

echo ">>> [Native Agent] 启动: $NODE_NAME -> $SERVER_URL"

# --------------------------------------------------------
# 主循环
# --------------------------------------------------------
while true; do
    # === 步骤 A: 采样窗口 (Sleep) ===
    # 利用 Sleep 的时间作为采样区间，直接计算这 3 秒内的平均值
    sleep $INTERVAL

    # === 步骤 B: 采集当前数据 ===
    
    # 1. CPU & 网络 (读取新值)
    read curr_cpu_total curr_cpu_idle <<< $(read_cpu_stat)
    read curr_rx curr_tx <<< $(get_net_bytes)

    # 2. 计算差值 (Delta)
    diff_cpu_total=$((curr_cpu_total - last_cpu_total))
    diff_cpu_idle=$((curr_cpu_idle - last_cpu_idle))
    
    diff_rx=$((curr_rx - last_rx))
    diff_tx=$((curr_tx - last_tx))

    # 3. 计算 CPU 使用率 (使用 awk 处理浮点运算)
    # 逻辑: 100 * (Total_Delta - Idle_Delta) / Total_Delta
    cpu_pct="0.0"
    if [ "$diff_cpu_total" -gt 0 ]; then
        cpu_pct=$(awk -v i="$diff_cpu_idle" -v t="$diff_cpu_total" 'BEGIN {printf "%.1f", (1 - i/t) * 100}')
    fi

    # 4. 计算网速 (KB/s)
    down_kb=$(awk -v rx="$diff_rx" -v intv="$INTERVAL" 'BEGIN {printf "%.1f", rx / 1024 / intv}')
    up_kb=$(awk -v tx="$diff_tx" -v intv="$INTERVAL" 'BEGIN {printf "%.1f", tx / 1024 / intv}')

    # 5. 更新基准值 (滚动)
    last_cpu_total=$curr_cpu_total
    last_cpu_idle=$curr_cpu_idle
    last_rx=$curr_rx
    last_tx=$curr_tx

    # === 步骤 C: 采集其他静态指标 ===

    # Boot Time
    uptime_sec=$(awk '{print $1}' /proc/uptime)
    now_sec=$(date +%s)
    boot_time=$(awk "BEGIN {print $now_sec - $uptime_sec}")
    
    cpu_cores=$(nproc)

    # 内存
    mem_info=$(free -b | grep Mem)
    mem_total=$(echo $mem_info | awk '{print $2}')
    mem_avail=$(echo $mem_info | awk '{print $7}')
    mem_pct="0.0"
    if [ "$mem_total" -gt 0 ]; then
        mem_pct=$(awk "BEGIN {printf \"%.1f\", ($mem_total - $mem_avail) / $mem_total * 100}")
    fi

    # 硬盘
    disk_info=$(df -B1 / | tail -1)
    disk_total=$(echo $disk_info | awk '{print $2}')
    disk_pct=$(echo $disk_info | awk '{print $5}' | tr -d '%')

    # 机器人状态
    grid_json=$(read_json_file "$PATH_FUTURE_GRID")
    autopilot_json=$(read_json_file "$PATH_AUTOPILOT")
    logs_json=$(get_logs_json)
    
    has_bot="false"
    if [ "$grid_json" != "null" ] || [ "$autopilot_json" != "null" ]; then
        has_bot="true"
    fi

    # === 步骤 D: 组装 JSON ===
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

    # === 步骤 E: 发送 ===
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
    
    # 注意：这里不需要 sleep，因为循环开头已经 sleep 过了
done