#!/bin/bash

# ========================================================
#  MyQuant Native Agent 管理脚本 (安装/更新)
#  功能：一键部署或更新 Shell 版探针
# ========================================================

# 配置区域
APP_DIR="/opt/mq_monitor_sh"
SCRIPT_NAME="agent_native.sh"
SERVICE_NAME="mq-monitor-sh"
DOWNLOAD_URL="https://raw.githubusercontent.com/an2024520/Monitor/refs/heads/main/agent_native.sh"

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 权限检查
if [ "$EUID" -ne 0 ]; then 
  echo -e "${RED}❌ 请使用 root 权限运行${RESET}"
  exit 1
fi

# ========================================================
# 核心函数
# ========================================================

# 函数：下载最新代码
download_core() {
    echo -e ">>> ⬇️  正在拉取最新代码..."
    mkdir -p "$APP_DIR"
    
    # 强制覆盖下载
    curl -sL "$DOWNLOAD_URL" -o "$APP_DIR/$SCRIPT_NAME"

    # 校验
    if [ -s "$APP_DIR/$SCRIPT_NAME" ]; then
        chmod +x "$APP_DIR/$SCRIPT_NAME"
        echo -e "    -> ${GREEN}下载成功${RESET}"
    else
        echo -e "${RED}❌ 错误: 下载失败或文件为空。${RESET}"
        echo "    地址: $DOWNLOAD_URL"
        exit 1
    fi
}

# 函数：安装依赖
install_dependencies() {
    echo -e ">>> 📦 检查系统依赖 (jq, curl)..."
    if ! command -v jq &> /dev/null; then
        if command -v apt-get &> /dev/null; then
            apt-get update -y > /dev/null 2>&1
            apt-get install -y jq curl > /dev/null 2>&1
        elif command -v yum &> /dev/null; then
            yum install -y jq curl > /dev/null 2>&1
        elif command -v apk &> /dev/null; then
            apk add jq curl > /dev/null 2>&1
        else
            echo -e "${RED}⚠️  无法自动安装 jq，请手动安装: apt/yum install jq${RESET}"
            exit 1
        fi
        echo -e "    -> ${GREEN}安装完成${RESET}"
    else
        echo -e "    -> ${GREEN}jq 已存在，跳过${RESET}"
    fi
}

# ========================================================
# 菜单逻辑
# ========================================================

clear
echo "========================================================"
echo "   MyQuant Monitor Native Agent (Shell版) "
echo "========================================================"
echo " 1. 🚀 全新安装 (Install)"
echo " 2. 🔄 仅更新代码 (Update)"
echo "========================================================"
read -p "请输入选项 [1-2]: " CHOICE

case $CHOICE in
    1)
        # ==================== [全新安装流程] ====================
        echo ""
        echo -e "${GREEN}>>> 进入安装模式...${RESET}"
        
        install_dependencies
        download_core

        # 配置交互
        echo ">>> ⚙️  配置参数..."
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

        # 创建服务
        echo ">>> 📝 创建系统服务..."
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

Environment=AGENT_REPORT_URL=${FULL_URL}
Environment=AGENT_TOKEN=${AUTH_TOKEN}
Environment=AGENT_NAME=${NODE_NAME}

[Install]
WantedBy=multi-user.target
EOF

        # 启动
        systemctl daemon-reload
        systemctl enable ${SERVICE_NAME}
        systemctl restart ${SERVICE_NAME}
        
        echo -e "${GREEN}✅ 安装并启动成功！${RESET}"
        ;;

    2)
        # ==================== [更新流程] ====================
        echo ""
        echo -e "${GREEN}>>> 进入更新模式...${RESET}"
        
        # 1. 检查目录是否存在
        if [ ! -d "$APP_DIR" ]; then
            echo -e "${RED}❌ 错误: 未检测到安装目录 ($APP_DIR)，请先选择 '1. 全新安装'。${RESET}"
            exit 1
        fi

        # 2. 下载新代码
        download_core

        # 3. 重启服务
        echo ">>> ♻️  重启服务..."
        if systemctl list-units --full -all | grep -Fq "$SERVICE_NAME.service"; then
            systemctl daemon-reload
            systemctl restart ${SERVICE_NAME}
            echo -e "${GREEN}✅ 更新完成！服务已重启。${RESET}"
            
            # 显示简要状态
            echo "----------------------------------------"
            systemctl status ${SERVICE_NAME} | grep "Active:"
            echo "----------------------------------------"
        else
            echo -e "${YELLOW}⚠️  警告: 代码已更新，但服务 ($SERVICE_NAME) 未找到，可能需要手动启动。${RESET}"
        fi
        ;;

    *)
        echo -e "${RED}❌ 无效选项，退出。${RESET}"
        exit 1
        ;;
esac