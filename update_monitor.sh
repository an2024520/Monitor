#!/bin/bash

# ==========================================
#  MyQuant Monitor 更新脚本
# ==========================================

APP_DIR="/opt/MyQuantMonitor"
SERVICE_NAME="myquant-monitor"

echo ">>> 📦 开始更新监控服务端..."

if [ ! -d "$APP_DIR" ]; then
    echo "❌ 错误: 找不到目录 $APP_DIR"
    exit 1
fi
cd "$APP_DIR"

# 1. 强制同步代码
echo ">>> [1/3] 拉取最新代码..."
git fetch --all
git reset --hard origin/main
git pull

# 2. 补充依赖 (防止 requirements.txt 变更)
echo ">>> [2/3] 检查依赖..."
if [ -f "requirements.txt" ]; then
    ./venv/bin/pip install -r requirements.txt > /dev/null 2>&1
fi

# 3. 重启服务
echo ">>> [3/3] 重启服务..."
systemctl restart $SERVICE_NAME

echo "=========================================="
echo "✅ 更新完成！"
echo "=========================================="