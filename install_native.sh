#!/bin/bash

# ========================================================
#  MyQuant Native Agent 管理脚本 (v1.3)
#  功能：安装(支持HTTP/HTTPS)、更新、彻底卸载
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
CYAN="\033[36m"
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
echo "   MyQuant Monitor Native Agent (Shell版) v1.3"
echo "========================================================"
echo " 1. 🚀 全新安装 (Install)"
echo " 2. 🔄 更新代码 (Update)"
echo " 3. 🗑️ 卸载/清除 (Uninstall)"
echo "========================================================"
read -p "请输入选项 [1-3]: " CHOICE

case $CHOICE in
    1)
        # ==================== [全新安装] ====================
        echo ""
        echo -e "${GREEN}>>> 进入安装模式...${RESET}"
        
        install_dependencies
        download_core

        # --- 配置交互 (核心修改部分) ---
        echo ">>> ⚙️  配置连接参数..."
        DEFAULT_NAME=$(hostname)
        
        echo -e "${CYAN}请选择通信协议:${RESET}"
        echo " 1) HTTP  (适合测试或IP直连, 默认端口 30308)"
        echo " 2) HTTPS (适合生产环境/域名反代, 默认端口 443)"
        read -p "请输入 [1-2]: " PROTO_CHOICE

        if [[ "$PROTO_CHOICE" == "2" ]]; then
            # HTTPS 模式
            PROTOCOL="https"
            DEFAULT_PORT="443"
            read -p "1. Server 域名 (例如 monitor.example.com): " INPUT_HOST
            # 如果用户没填域名，这里其实无法继续，但为了脚本不报错，暂用localhost兜底
            SERVER_HOST=${INPUT_HOST:-"localhost"}
        else
            # HTTP 模式
            PROTOCOL="http"
            DEFAULT_PORT="30308"
            DEFAULT_IP="127.0.0.1"
            read -p "1. Server IP [默认: $DEFAULT_IP, IPv6请加方括号]: " INPUT_HOST
            SERVER_HOST=${INPUT_HOST:-$DEFAULT_IP}
        fi

        read -p "2. Server Port [默认: $DEFAULT_PORT]: " INPUT_PORT
        SERVER_PORT=${INPUT_PORT:-$DEFAULT_PORT}

        read -p "3. 节点名称 [默认: $DEFAULT_NAME]: " INPUT_NAME
        NODE_NAME=${INPUT_NAME:-$DEFAULT_NAME}

        read -p "4. Token [默认: hard-core-v7]: " INPUT_TOKEN
        AUTH_TOKEN=${INPUT_TOKEN:-"hard-core-v7"}

        # 拼接最终 URL
        FULL_URL="${PROTOCOL}://${SERVER_HOST}:${SERVER_PORT}/report"
        echo -e ">>> 🔗 目标地址: ${CYAN}${FULL_URL}${RESET}"

        # --- 创建服务 ---
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
        # ==================== [无痛更新] ====================
        echo ""
        echo -e "${GREEN}>>> 进入更新模式...${RESET}"
        
        if [ ! -d "$APP_DIR" ]; then
            echo -e "${RED}❌ 错误: 未检测到安装目录，请先选择 '1. 全新安装'。${RESET}"
            exit 1
        fi

        download_core

        echo ">>> ♻️  重启服务..."
        if systemctl list-units --full -all | grep -Fq "$SERVICE_NAME.service"; then
            systemctl daemon-reload
            systemctl restart ${SERVICE_NAME}
            echo -e "${GREEN}✅ 更新完成！服务已重启。${RESET}"
            systemctl status ${SERVICE_NAME} | grep "Active:"
        else
            echo -e "${YELLOW}⚠️  警告: 代码已更新，但服务未找到。${RESET}"
        fi
        ;;

    3)
        # ==================== [卸载模式] ====================
        echo ""
        echo -e "${YELLOW}>>> ⚠️  警告：这将停止监控并删除所有相关文件！${RESET}"
        read -p "确认卸载吗？(输入 y 确认): " CONFIRM
        if [[ "$CONFIRM" != "y" ]]; then
            echo "已取消。"
            exit 0
        fi

        echo ">>> [1/3] 停止并禁用服务..."
        systemctl stop ${SERVICE_NAME} 2>/dev/null
        systemctl disable ${SERVICE_NAME} 2>/dev/null
        
        echo ">>> [2/3] 删除服务配置..."
        rm -f /etc/systemd/system/${SERVICE_NAME}.service
        systemctl daemon-reload
        
        echo ">>> [3/3] 删除程序文件..."
        rm -rf "${APP_DIR}"
        
        echo -e "${GREEN}✅ 卸载完成！系统已恢复清理干净。${RESET}"
        ;;

    *)
        echo -e "${RED}❌ 无效选项，退出。${RESET}"
        exit 1
        ;;
esac