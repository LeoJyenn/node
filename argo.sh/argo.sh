#!/bin/bash

####################################################
#    Xray + Argo Tunnel + Nezha 修复增强版         #
#    功能：安装 / 查看配置 / 完美卸载              #
####################################################

# 颜色设置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 核心配置
WORK_DIR="/root/argo_tunnel_script"
SERVICE_FILE="/etc/systemd/system/argo_bot.service"
INFO_FILE="$WORK_DIR/info.conf"

# 1. 检查 Root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误：本脚本必须以 root 身份运行！${PLAIN}"
        exit 1
    fi
}

# 2. 系统依赖检查与修复
check_dependencies() {
    echo -e "${YELLOW}正在检查系统环境...${PLAIN}"
    
    # 自动识别系统并安装 sudo, uuidgen 等
    if [ -f /etc/alpine-release ]; then
        apk update && apk add --no-cache bash curl wget sudo util-linux tar ca-certificates
    elif [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y curl wget sudo uuid-runtime tar ca-certificates
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl wget sudo util-linux tar ca-certificates
    fi
    
    mkdir -p "$WORK_DIR"
}

# 3. 安装主逻辑
install_node() {
    check_dependencies
    
    echo -e "\n${GREEN}=== 开始配置 ===${PLAIN}"
    
    # UUID 设置
    read -p "请输入 UUID (留空自动生成): " UUID
    if [ -z "$UUID" ]; then
        UUID=$(uuidgen)
    fi
    echo -e "${YELLOW}使用 UUID: ${UUID}${PLAIN}"

    # Argo Token 设置
    while true; do
        read -p "请输入 Argo Token (eyJh...): " ARGO_TOKEN
        if [ ! -z "$ARGO_TOKEN" ]; then break; fi
        echo -e "${RED}Token 不能为空！${PLAIN}"
    done

    # 域名设置
    while true; do
        read -p "请输入固定隧道域名 (例如 rn.vds.us.kg): " ARGO_DOMAIN
        if [ ! -z "$ARGO_DOMAIN" ]; then break; fi
        echo -e "${RED}域名不能为空！${PLAIN}"
    done

    # 哪吒监控
    read -p "请输入哪吒面板地址 (留空跳过): " NEZHA_SERVER
    NEZHA_OPT=""
    if [ ! -z "$NEZHA_SERVER" ]; then
        read -p "请输入哪吒密钥 (Secret): " NEZHA_KEY
        read -p "是否开启 TLS? (y/n, 默认n): " NEZHA_TLS
        TLS_FLAG=""
        if [[ "$NEZHA_TLS" == "y" ]]; then TLS_FLAG="--tls"; fi
        NEZHA_OPT="-s $NEZHA_SERVER -p $NEZHA_KEY $TLS_FLAG"
    fi

    # 保存配置以便查看
    echo "UUID=${UUID}" > "$INFO_FILE"
    echo "DOMAIN=${ARGO_DOMAIN}" >> "$INFO_FILE"

    # 下载组件
    echo -e "\n${YELLOW}正在下载组件...${PLAIN}"
    cd "$WORK_DIR"
    # 使用备用源防止原作者删库
    BASE_URL="https://github.com/LeoJyenn/node/raw/main"
    wget -O bot "$BASE_URL/bot" -q --show-progress || { echo -e "${RED}下载 bot 失败${PLAIN}"; exit 1; }
    wget -O web "$BASE_URL/web" -q --show-progress || { echo -e "${RED}下载 web 失败${PLAIN}"; exit 1; }
    chmod +x bot web

    # 配置 Systemd (修复路径问题)
    echo -e "\n${YELLOW}正在配置开机自启...${PLAIN}"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Argo Tunnel Service
After=network.target

[Service]
Type=simple
User=root
# 关键：修复路径
WorkingDirectory=${WORK_DIR}
ExecStart=${WORK_DIR}/bot -t ${ARGO_TOKEN} -d ${ARGO_DOMAIN} -u ${UUID} ${NEZHA_OPT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # 启动服务
    systemctl daemon-reload
    systemctl enable argo_bot
    systemctl restart argo_bot
    
    sleep 2
    if pgrep -f "bot" > /dev/null; then
        echo -e "\n${GREEN}部署成功！${PLAIN}"
        show_links
    else
        echo -e "\n${RED}服务启动失败！${PLAIN} 请运行 systemctl status argo_bot 查看原因"
    fi
}

# 4. 查看链接
show_links() {
    if [ ! -f "$INFO_FILE" ]; then
        echo -e "${RED}未找到配置文件，请先安装！${PLAIN}"
        return
    fi
    
    source "$INFO_FILE"
    
    echo -e "\n${YELLOW}================ 节点配置 ================${PLAIN}"
    echo -e "${SKYBLUE}VLESS Link:${PLAIN}"
    echo "vless://${UUID}@cdns.doon.eu.org:443?encryption=none&security=tls&sni=${DOMAIN}&fp=firefox&type=ws&host=${DOMAIN}&path=%2Fvless-argo%3Fed%3D2560#Argo-VLESS"
    
    echo -e "\n${SKYBLUE}VMESS Link:${PLAIN}"
    VMESS_JSON="{\"v\":\"2\",\"ps\":\"Argo-VMESS\",\"add\":\"cdns.doon.eu.org\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"none\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"/vmess-argo?ed=2560\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\",\"alpn\":\"\",\"fp\":\"firefox\"}"
    echo "vmess://$(echo -n $VMESS_JSON | base64 -w 0)"
    
    echo -e "\n${SKYBLUE}Trojan Link:${PLAIN}"
    echo "trojan://${UUID}@cdns.doon.eu.org:443?security=tls&sni=${DOMAIN}&fp=firefox&type=ws&host=${DOMAIN}&path=%2Ftrojan-argo%3Fed%3D2560#Argo-Trojan"
    echo -e "${YELLOW}==========================================${PLAIN}"
}

# 5. 卸载功能
uninstall_node() {
    echo -e "\n${YELLOW}正在卸载...${PLAIN}"
    systemctl stop argo_bot 2>/dev/null
    systemctl disable argo_bot 2>/dev/null
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    
    rm -rf "$WORK_DIR"
    
    echo -e "${GREEN}卸载完成！所有文件和服务已清除。${PLAIN}"
}

# 6. 主菜单
menu() {
    clear
    echo -e "####################################################"
    echo -e "#     Xray + Argo Tunnel + Nezha 全能脚本 (修复版) #"
    echo -e "####################################################"
    echo -e "${GREEN}1.${PLAIN} 安装 / 重置配置 (Install)"
    echo -e "${GREEN}2.${PLAIN} 查看当前节点链接 (Show Links)"
    echo -e "${RED}3.${PLAIN} 卸载 (Uninstall)"
    echo -e "${YELLOW}0.${PLAIN} 退出 (Exit)"
    echo -e "####################################################"
    
    read -p "请输入选择 [0-3]: " choice
    
    case $choice in
        1) install_node ;;
        2) show_links ;;
        3) uninstall_node ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择，请重试${PLAIN}"; sleep 1; menu ;;
    esac
}

# 运行脚本
check_root
menu
