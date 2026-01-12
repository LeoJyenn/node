#!/bin/bash

# 颜色设置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 工作目录
WORK_DIR="/root/argo_tunnel_script"

# 1. 检查是否为 Root 用户
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}错误：本脚本必须以 root 身份运行！${PLAIN}"
    exit 1
fi

# 2. 系统检测与依赖安装 (修复 sudo 和 uuid 问题)
echo -e "${YELLOW}正在检查并安装系统依赖 (sudo, curl, uuidgen)...${PLAIN}"

if [ -f /etc/alpine-release ]; then
    # Alpine Linux
    apk update
    apk add --no-cache bash curl wget sudo util-linux tar ca-certificates
elif [ -f /etc/debian_version ]; then
    # Debian / Ubuntu
    apt-get update
    apt-get install -y curl wget sudo uuid-runtime tar ca-certificates
elif [ -f /etc/redhat-release ]; then
    # CentOS / Fedora
    yum install -y curl wget sudo util-linux tar ca-certificates
else
    echo -e "${RED}无法识别的操作系统，请手动安装 sudo 和 uuidgen${PLAIN}"
fi

echo -e "${GREEN}系统依赖检查完成！${PLAIN}"

# 3. 准备目录
mkdir -p "$WORK_DIR"
cd "$WORK_DIR" || exit 1

# 4. 收集用户输入
echo -e "\n${GREEN}=== 配置参数 ===${PLAIN}"

# UUID
read -p "请输入 UUID (留空自动生成): " UUID
if [ -z "$UUID" ]; then
    UUID=$(uuidgen)
fi
echo -e "${YELLOW}使用 UUID: ${UUID}${PLAIN}"

# Argo Token
echo -e "\n--- Cloudflare Argo Tunnel 配置 ---"
read -p "请输入 Argo Token (eyJh...): " ARGO_TOKEN
if [ -z "$ARGO_TOKEN" ]; then
    echo -e "${RED}错误：Argo Token 不能为空！${PLAIN}"
    exit 1
fi

# 域名
read -p "请输入固定隧道域名 (例如 rn.vds.us.kg): " ARGO_DOMAIN
if [ -z "$ARGO_DOMAIN" ]; then
    echo -e "${RED}错误：域名不能为空！${PLAIN}"
    exit 1
fi

# 哪吒监控 (可选)
echo -e "\n--- 哪吒监控配置 (可选) ---"
read -p "请输入哪吒面板地址 (留空跳过): " NEZHA_SERVER
NEZHA_OPT=""
if [ ! -z "$NEZHA_SERVER" ]; then
    read -p "请输入哪吒密钥 (Secret): " NEZHA_KEY
    read -p "是否开启 TLS? (y/n, 默认n): " NEZHA_TLS
    TLS_FLAG=""
    if [[ "$NEZHA_TLS" == "y" ]]; then TLS_FLAG="--tls"; fi
    NEZHA_OPT="-s $NEZHA_SERVER -p $NEZHA_KEY $TLS_FLAG"
fi

# 5. 下载核心组件 (使用原脚本源)
echo -e "\n${YELLOW}正在下载核心组件...${PLAIN}"

# 尝试下载 bot (Argo wrapper) 和 web (Xray)
# 注意：这里使用通用源，如果原作者源失效，需替换链接
BASE_URL="https://github.com/LeoJyenn/node/raw/main"
wget -O bot "$BASE_URL/bot" || { echo -e "${RED}下载 bot 失败${PLAIN}"; exit 1; }
wget -O web "$BASE_URL/web" || { echo -e "${RED}下载 web 失败${PLAIN}"; exit 1; }

chmod +x bot web

# 6. 生成 Systemd 服务文件 (修复路径问题的核心步骤)
echo -e "\n${YELLOW}正在配置 Systemd 服务...${PLAIN}"

cat > /etc/systemd/system/argo_bot.service <<EOF
[Unit]
Description=Argo Tunnel Service By Script
After=network.target

[Service]
Type=simple
User=root
# 关键修复：指定工作目录，防止程序找不到文件
WorkingDirectory=${WORK_DIR}
# 启动命令：传入所有参数
ExecStart=${WORK_DIR}/bot -t ${ARGO_TOKEN} -d ${ARGO_DOMAIN} -u ${UUID} ${NEZHA_OPT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# 7. 启动服务
systemctl daemon-reload
systemctl enable argo_bot
systemctl restart argo_bot

# 8. 检查状态并输出节点
sleep 2
if pgrep -f "bot" > /dev/null; then
    echo -e "\n${GREEN}================ 部署成功！ =================${PLAIN}"
    echo -e "服务状态: ${GREEN}运行中${PLAIN}"
    
    echo -e "\n${YELLOW}=== VLESS 节点链接 ===${PLAIN}"
    echo "vless://${UUID}@cdns.doon.eu.org:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&fp=firefox&type=ws&host=${ARGO_DOMAIN}&path=%2Fvless-argo%3Fed%3D2560#Argo-VLESS"
    
    echo -e "\n${YELLOW}=== VMESS 节点链接 ===${PLAIN}"
    VMESS_JSON="{\"v\":\"2\",\"ps\":\"Argo-VMESS\",\"add\":\"cdns.doon.eu.org\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"none\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${ARGO_DOMAIN}\",\"path\":\"/vmess-argo?ed=2560\",\"tls\":\"tls\",\"sni\":\"${ARGO_DOMAIN}\",\"alpn\":\"\",\"fp\":\"firefox\"}"
    echo "vmess://$(echo -n $VMESS_JSON | base64 -w 0)"
    
    echo -e "\n${YELLOW}=== Trojan 节点链接 ===${PLAIN}"
    echo "trojan://${UUID}@cdns.doon.eu.org:443?security=tls&sni=${ARGO_DOMAIN}&fp=firefox&type=ws&host=${ARGO_DOMAIN}&path=%2Ftrojan-argo%3Fed%3D2560#Argo-Trojan"
    
    echo -e "\n配置已保存至: ${WORK_DIR}"
else
    echo -e "\n${RED}服务启动失败！${PLAIN}"
    echo "请运行以下命令查看日志："
    echo "journalctl -u argo_bot.service -n 20 --no-pager"
fi
