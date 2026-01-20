#!/bin/bash

# ========================================================
#  MyQuant Monitor Agent 一键部署脚本
# ========================================================

# --- 配置区域 ---
# Agent 代码下载地址
RAW_URL="https://raw.githubusercontent.com/an2024520/Monitor/refs/heads/main/agent.py"

# 安装目录
APP_DIR="/opt/monitor_agent"

# 服务名称 (已改为更通用的名字)
SERVICE_NAME="mq-monitor"

# ========================================================

if [ "$EUID" -ne 0 ]; then 
  echo "❌ 请使用 root 权限运行 (sudo bash deploy_agent.sh)"
  exit 1
fi

echo ">>> 🚀 开始部署 MQ 监控探针 (Sidecar Mode)..."

# 1. 基础环境
echo ">>> [1/5] 安装基础工具..."
# 兼容 Debian/Ubuntu/CentOS 的写法略有不同，这里主要适配 Debian/Ubuntu
apt-get update -y > /dev/null 2>&1
apt-get install -y python3 python3-venv curl > /dev/null 2>&1

# 2. 目录创建
echo ">>> [2/5] 创建工作目录: $APP_DIR"
if [ ! -d "$APP_DIR" ]; then
    mkdir -p "$APP_DIR"
fi

# 3. 虚拟环境 (独立环境，完全兼容有无机器人的情况)
echo ">>> [3/5] 初始化独立 Python 环境..."
if [ ! -d "$APP_DIR/venv" ]; then
    python3 -m venv "$APP_DIR/venv"
fi

echo "    正在安装依赖库 (psutil, requests)..."
"$APP_DIR/venv/bin/pip" install --upgrade pip > /dev/null 2>&1
"$APP_DIR/venv/bin/pip" install psutil requests > /dev/null 2>&1

# 4. 下载代码
echo ">>> [4/5] 下载最新 Agent 代码..."
# 强制覆盖旧文件
curl -s -L "$RAW_URL" -o "$APP_DIR/agent.py"

if [ ! -f "$APP_DIR/agent.py" ]; then
    echo "❌ 下载失败，请检查网络或 GitHub 地址。"
    exit 1
fi

# 5. 配置 Systemd
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

# 防止中文乱码
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONIOENCODING=utf-8
Environment=LANG=C.UTF-8

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
echo "--------------------------------------------------------"
echo "🔍 查看状态: systemctl status ${SERVICE_NAME}"
echo "📜 查看日志: journalctl -u ${SERVICE_NAME} -f"
echo "========================================================"