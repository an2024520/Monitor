#!/bin/bash

# ========================================================
#  MyQuant Monitor Server 一键部署脚本
# ========================================================

# --- 配置区域 ---
REPO_URL="https://github.com/an2024520/Monitor.git"
APP_DIR="/opt/MyQuantMonitor"
SERVICE_NAME="myquant-monitor"

# ========================================================

if [ "$EUID" -ne 0 ]; then 
  echo "❌ 请使用 root 权限运行"
  exit 1
fi

echo ">>> 🚀 开始部署监控服务端 (Server)..."

# 1. 基础工具
echo ">>> [1/5] 安装基础工具..."
apt-get update -y > /dev/null 2>&1
apt-get install -y git python3 python3-pip python3-venv > /dev/null 2>&1

# 2. 拉取代码
echo ">>> [2/5] 拉取 GitHub 代码..."
if [ -d "$APP_DIR" ]; then
    echo "    备份旧目录..."
    mv "$APP_DIR" "${APP_DIR}_backup_$(date +%s)"
fi

git clone "$REPO_URL" "$APP_DIR"
if [ $? -ne 0 ]; then
    echo "❌ 代码拉取失败。"
    exit 1
fi

# 3. 虚拟环境
echo ">>> [3/5] 创建虚拟环境..."
cd "$APP_DIR"
python3 -m venv venv

# 4. 安装依赖
echo ">>> [4/5] 安装依赖 (Flask)..."
"$APP_DIR/venv/bin/pip" install --upgrade pip > /dev/null 2>&1
# 如果仓库里有 requirements.txt 则使用，否则手动安装 Flask
if [ -f "requirements.txt" ]; then
    "$APP_DIR/venv/bin/pip" install -r requirements.txt
else
    echo "    未找到 requirements.txt，手动安装 Flask..."
    "$APP_DIR/venv/bin/pip" install flask
fi

# 5. 配置 Systemd
echo ">>> [5/5] 配置系统服务..."
cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=MyQuant Monitor Server
After=network.target

[Service]
User=root
Group=root
WorkingDirectory=${APP_DIR}
# 启动 app.py
ExecStart=${APP_DIR}/venv/bin/python ${APP_DIR}/app.py

Environment=PYTHONUNBUFFERED=1
Environment=PYTHONIOENCODING=utf-8
Environment=LANG=C.UTF-8

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ${SERVICE_NAME}
systemctl restart ${SERVICE_NAME}

echo "========================================================"
echo "✅ Server 部署完成！"
echo "🌐 访问地址: http://<你的VPS_IP>:5000"
echo "--------------------------------------------------------"
echo "📜 查看日志: journalctl -u ${SERVICE_NAME} -f"
echo "========================================================"