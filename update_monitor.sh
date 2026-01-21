#!/bin/bash

# ==========================================
#  MyQuant Monitor 更新脚本 (增强版)
# ==========================================

APP_DIR="/opt/MyQuantMonitor"
SERVICE_NAME="myquant-monitor"

# 检查是否为 root
if [ "$EUID" -ne 0 ]; then 
  echo "❌ 请使用 root 权限运行"
  exit 1
fi

echo ">>> 📦 开始更新监控服务端..."

if [ ! -d "$APP_DIR" ]; then
    echo "❌ 错误: 找不到目录 $APP_DIR"
    exit 1
fi

# 1. 强制同步代码
echo ">>> [1/3] 拉取最新代码 (Git reset)..."
cd "$APP_DIR"
git fetch --all
git reset --hard origin/main
git pull

# ==========================================
# [新增] 赋予执行权限 (关键修复)
# 防止 Windows 提交后权限丢失，导致脚本下次无法运行
# 使用 *.sh 可以同时修复 update_monitor.sh 和 deploy_server.sh
chmod +x "$APP_DIR"/*.sh
echo "    -> 已修复脚本执行权限 (+x)"
# ==========================================

# 2. 补充依赖
echo ">>> [2/3] 检查依赖变更..."
if [ -f "requirements.txt" ]; then
    ./venv/bin/pip install -r requirements.txt > /dev/null 2>&1
fi

# 3. 重启服务
echo ">>> [3/3] 重启服务..."
systemctl daemon-reload
systemctl restart $SERVICE_NAME

# --- 新增：配置回显 ---
echo "=========================================="
echo "✅ 更新完成！"

# 从 Systemd 获取当前运行的环境变量
CURRENT_HOST=$(systemctl show $SERVICE_NAME --property=Environment | grep -oP 'FLASK_HOST=\K[^ ]+')
CURRENT_PORT=$(systemctl show $SERVICE_NAME --property=Environment | grep -oP 'FLASK_PORT=\K[^ ]+')

# 如果获取不到（比如旧版服务文件），给个默认提示
if [ -z "$CURRENT_PORT" ]; then
    echo "⚠️  无法读取 Systemd 配置，可能运行在默认端口 5000"
else
    echo "⚙️  当前服务配置: $CURRENT_HOST:$CURRENT_PORT"
    echo "🌐 访问地址: http://<你的VPS_IP>:$CURRENT_PORT"
fi
echo "=========================================="