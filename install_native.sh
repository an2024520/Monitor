#!/bin/bash

# ========================================================
#  MyQuant Native Agent 安装脚本
#  功能：环境准备、安装 jq、配置 Systemd 服务
# ========================================================

APP_DIR="/opt/mq_monitor_sh"
SCRIPT_NAME="agent_native.sh"
SERVICE_NAME="mq-monitor-sh" # 新的服务名，不冲突

if [ "$EUID" -ne 0 ]; then 
  echo "❌ 请使用 root 权限运行"
  exit 1
fi

echo ">>> 🚀 开始部署 Native Shell 版探针..."

# 1. 自动安装依赖 (jq, curl)
echo ">>> [1/4] 检查并安装依赖 (jq)..."
if ! command -v jq &> /dev/null; then
    if command -v apt-get &> /dev/null; then
        apt-get update -y > /dev/null 2>&1
        apt-get install -y jq curl > /dev/null 2>&1
    elif command -v yum &> /dev/null; then
        yum install -y jq curl > /dev/null 2>&1
    elif command -v apk &> /dev/null; then
        apk add jq curl > /dev/null 2>&1
    else
        echo "⚠️  无法自动安装 jq，请手动安装: apt/yum install jq"
        exit 1
    fi
    echo "    -> jq 安装完成"
else
    echo "    -> jq 已存在，跳过"
fi

# 2. 准备目录和文件
echo ">>> [2/4] 部署脚本文件..."
mkdir -p "$APP_DIR"

# 假设 agent_native.sh 和 install_native.sh 在同一目录下
# 如果是从网络下载，这里可以换成 curl 下载逻辑
if [ -f "$SCRIPT_NAME" ]; then
    cp "$SCRIPT_NAME" "$APP_DIR/"
    chmod +x "$APP_DIR/$SCRIPT_NAME"
else
    echo "❌ 错误: 未找到 $SCRIPT_NAME，请确保两个脚本在一起"
    exit 1
fi

# 3. 交互式配置 (只在安装时运行一次)
echo ">>> [3/4] 配置参数..."

# 读取旧配置作为默认值 (如果存在)
DEFAULT_IP="127.0.0.1"
DEFAULT_NAME=$(hostname)

read -p "1. Server IP [默认: $DEFAULT_IP, IPv6请加方括号]: " INPUT_IP
SERVER_IP=${INPUT_IP:-$DEFAULT_IP}

read -p "2. Server Port [默认: 30308]: " INPUT_PORT
SERVER_PORT=${INPUT_PORT:-30308}

read -p "3. 节点名称 [默认: $DEFAULT_NAME]: " INPUT_NAME
NODE_NAME=${INPUT_NAME:-$DEFAULT_NAME}

read -p "4. Token [默认: hard-core-v7]: " INPUT_TOKEN
AUTH_TOKEN=${INPUT_TOKEN:-"hard-core-v7"}

FULL_URL="http://${SERVER_IP}:${SERVER_PORT}/report"

# 4. 创建 Systemd 服务
echo ">>> [4/4] 创建系统服务 ($SERVICE_NAME)..."

cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=MyQuant Monitor Native Agent (Shell)
After=network.target

[Service]
User=root
Group=root
WorkingDirectory=${APP_DIR}
ExecStart=/bin/bash ${APP_DIR}/${SCRIPT_NAME}
Restart=always
RestartSec=5

# --- 环境变量注入 ---
Environment=AGENT_REPORT_URL=${FULL_URL}
Environment=AGENT_TOKEN=${AUTH_TOKEN}
Environment=AGENT_NAME=${NODE_NAME}
# ------------------

[Install]
WantedBy=multi-user.target
EOF

# 5. 启动服务
systemctl daemon-reload
systemctl enable ${SERVICE_NAME}
systemctl restart ${SERVICE_NAME}

echo "========================================================"
echo "✅ 部署成功！"
echo "🔧 服务名称: $SERVICE_NAME"
echo "📂 安装路径: $APP_DIR"
echo "📝 查看日志: journalctl -u $SERVICE_NAME -f"
echo "========================================================"