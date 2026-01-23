#!/bin/bash

# ========================================================
#  MyQuant Monitor Agent 一键部署脚本 (交互增强 + 命名版)
# ========================================================

# --- 配置区域 ---
RAW_URL="https://raw.githubusercontent.com/an2024520/Monitor/refs/heads/main/agent.py"
APP_DIR="/opt/monitor_agent"
SERVICE_NAME="mq-monitor"

# ========================================================

if [ "$EUID" -ne 0 ]; then 
  echo "❌ 请使用 root 权限运行 (sudo bash deploy_agent.sh)"
  exit 1
fi

echo ">>> 🚀 开始部署 MQ 监控探针 (Agent)..."

# ================= 1. 智能配置读取 =================
# 尝试从旧服务中读取配置，作为默认值
DEFAULT_IP=""
DEFAULT_PORT="5000"
DEFAULT_TOKEN="hard-core-v7"
DEFAULT_NAME=$(hostname)

if systemctl list-units --full -all | grep -q "$SERVICE_NAME.service"; then
    # 尝试读取旧的环境变量
    OLD_URL=$(systemctl show $SERVICE_NAME --property=Environment | grep -oP 'AGENT_REPORT_URL=\K[^ ]+')
    OLD_TOKEN=$(systemctl show $SERVICE_NAME --property=Environment | grep -oP 'AGENT_TOKEN=\K[^ ]+')
    OLD_NAME=$(systemctl show $SERVICE_NAME --property=Environment | grep -oP 'AGENT_NAME=\K[^ ]+')
    
    if [[ "$OLD_URL" =~ http://([^:]+):([0-9]+)/report ]]; then
        DEFAULT_IP="${BASH_REMATCH[1]}"
        DEFAULT_PORT="${BASH_REMATCH[2]}"
    fi
    if [ ! -z "$OLD_TOKEN" ]; then DEFAULT_TOKEN="$OLD_TOKEN"; fi
    if [ ! -z "$OLD_NAME" ]; then DEFAULT_NAME="$OLD_NAME"; fi
    
    echo "ℹ️  检测到旧配置: IP=$DEFAULT_IP, Name=$DEFAULT_NAME"
fi

echo "--------------------------------------------------------"
echo "⚙️  配置 Agent 参数"
echo "--------------------------------------------------------"

# 1. 设置 IP
read -p "1. Server IP [默认: ${DEFAULT_IP:-127.0.0.1}, 若IPV6请手动加方括号]: " INPUT_IP
SERVER_IP=${INPUT_IP:-${DEFAULT_IP:-"127.0.0.1"}}

# 2. 设置 端口
read -p "2. Server Port [默认: ${DEFAULT_PORT}]: " INPUT_PORT
SERVER_PORT=${INPUT_PORT:-$DEFAULT_PORT}

# 3. 设置 节点别名 (这里补上了)
read -p "3. 节点别名 (Node Name) [默认: ${DEFAULT_NAME}]: " INPUT_NAME
NODE_NAME=${INPUT_NAME:-$DEFAULT_NAME}

# 4. 设置 Token
read -p "4. 通讯 Token [默认: $DEFAULT_TOKEN]: " INPUT_TOKEN
AUTH_TOKEN=${INPUT_TOKEN:-$DEFAULT_TOKEN}

# 构造完整 URL
REPORT_URL="http://${SERVER_IP}:${SERVER_PORT}/report"

echo "✅ 目标地址: $REPORT_URL"
echo "✅ 节点名称: $NODE_NAME"
echo "--------------------------------------------------------"

# ========================================================

# 2. 基础环境
echo ">>> [1/5] 安装基础工具..."
apt-get update -y > /dev/null 2>&1
apt-get install -y python3 python3-venv curl > /dev/null 2>&1

# 3. 目录创建
echo ">>> [2/5] 准备目录: $APP_DIR"
if [ ! -d "$APP_DIR" ]; then mkdir -p "$APP_DIR"; fi

# 4. 虚拟环境
echo ">>> [3/5] 检查 Python 环境..."
if [ ! -d "$APP_DIR/venv" ]; then python3 -m venv "$APP_DIR/venv"; fi
"$APP_DIR/venv/bin/pip" install --upgrade pip > /dev/null 2>&1
"$APP_DIR/venv/bin/pip" install psutil requests > /dev/null 2>&1

# 5. 下载代码
echo ">>> [4/5] 下载/更新 Agent 代码..."
curl -s -L "$RAW_URL" -o "$APP_DIR/agent.py"

if [ ! -f "$APP_DIR/agent.py" ]; then
    echo "❌ 下载失败，请检查 GitHub 连接。"
    exit 1
fi

# 6. 配置 Systemd (注入环境变量)
echo ">>> [5/5] 配置系统服务..."
cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=MyQuant Monitor Agent
After=network.target

[Service]
User=root
Group=root
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/venv/bin/python ${APP_DIR}/agent.py

Environment=PYTHONUNBUFFERED=1
Environment=PYTHONIOENCODING=utf-8
Environment=LANG=C.UTF-8

# --- 核心配置 ---
Environment=AGENT_REPORT_URL=${REPORT_URL}
Environment=AGENT_TOKEN=${AUTH_TOKEN}
Environment=AGENT_NAME=${NODE_NAME}
# --------------

Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ${SERVICE_NAME}
systemctl restart ${SERVICE_NAME}

echo "========================================================"
echo "✅ 部署完成！"
echo "📡 连接至: $REPORT_URL"
echo "🏷️  本机名: $NODE_NAME"
echo "--------------------------------------------------------"
echo "🔍 查看状态: systemctl status ${SERVICE_NAME}"
echo "========================================================"