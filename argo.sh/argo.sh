#!/bin/bash

# ==========================================================
# 功能：Xray + Argo Tunnel + Nezha 全能部署脚本
# 支持：Debian/Ubuntu, CentOS/RHEL/Alma, Alpine
# 特性：开机自启 (Systemd)、交互菜单、一键卸载
# ==========================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# 变量定义
WORK_DIR="$HOME/argo_tunnel_script"
CONFIG_FILE="$WORK_DIR/config.json"
ARGO_LOG="$WORK_DIR/boot.log"
SERVICE_NAME="argo-xray"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# 二进制文件路径
WEB_BIN="$WORK_DIR/web"    # Xray
BOT_BIN="$WORK_DIR/bot"    # Cloudflared
AGENT_BIN="$WORK_DIR/agent" # Nezha

# ----------------------------------------------------------
# 系统检查与依赖安装
# ----------------------------------------------------------
check_dependencies() {
    echo -e "${YELLOW}正在检查系统依赖...${PLAIN}"
    
    # 定义通用的依赖命令列表
    local cmds=("curl" "wget" "jq" "base64" "openssl" "tar")
    # uuidgen 在不同系统包名不同，单独处理
    
    # 检测包管理器
    PM=""
    if [ -x "$(command -v apt)" ]; then PM="apt"; fi
    if [ -x "$(command -v yum)" ]; then PM="yum"; fi
    if [ -x "$(command -v dnf)" ]; then PM="dnf"; fi
    if [ -x "$(command -v apk)" ]; then PM="apk"; fi

    # 安装基础命令
    for cmd in "${cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}未安装 $cmd，正在尝试安装...${PLAIN}"
            case $PM in
                apt) sudo apt update && sudo apt install -y "$cmd" ;;
                yum|dnf) sudo $PM install -y "$cmd" ;;
                apk) sudo apk add --no-cache "$cmd" ;;
                *) echo -e "${RED}无法识别包管理器，请手动安装: $cmd${PLAIN}"; exit 1 ;;
            esac
        fi
    done

    # 特殊处理 uuidgen
    if ! command -v uuidgen &> /dev/null; then
        echo -e "${RED}未安装 uuidgen，正在尝试安装...${PLAIN}"
        case $PM in
            apt) sudo apt install -y uuid-runtime ;;
            yum|dnf) sudo $PM install -y util-linux ;;
            apk) sudo apk add --no-cache uuidgen ;;
        esac
    fi
}

# ----------------------------------------------------------
# 核心安装逻辑
# ----------------------------------------------------------
get_user_input() {
    echo -e "${GREEN}=== 配置参数 ===${PLAIN}"
    
    # 1. UUID
    read -p "请输入 UUID (留空自动生成): " INPUT_UUID
    if [ -z "$INPUT_UUID" ]; then
        UUID=$(uuidgen)
        echo -e "${YELLOW}已生成 UUID: $UUID${PLAIN}"
    else
        UUID="$INPUT_UUID"
    fi

    # 2. Argo 配置
    echo -e "\n${YELLOW}--- Cloudflare Argo Tunnel 配置 ---${PLAIN}"
    echo "1. 使用临时隧道 (无需 Token，随机域名)"
    echo "2. 使用固定隧道 (需要 Cloudflare Tunnel Token)"
    read -p "请选择 (默认 1): " ARGO_TYPE
    ARGO_AUTH=""
    ARGO_DOMAIN=""
    
    if [ "$ARGO_TYPE" == "2" ]; then
        read -p "请输入 Argo Token (eyJh...): " ARGO_AUTH
        read -p "请输入固定隧道域名 (例如 arg.example.com): " ARGO_DOMAIN
    fi

    # 3. 哪吒监控
    echo -e "\n${YELLOW}--- 哪吒监控配置 (可选) ---${PLAIN}"
    read -p "请输入哪吒面板地址 (例如 nz.example.com，留空跳过): " NEZHA_SERVER
    NEZHA_CMD=""
    if [ -n "$NEZHA_SERVER" ]; then
        read -p "请输入哪吒 Agent 密钥 (Client Secret): " NEZHA_KEY
        read -p "请输入哪吒面板端口 (默认 5555): " NEZHA_PORT
        NEZHA_PORT=${NEZHA_PORT:-5555}
        
        TLS_PORTS=("443" "8443" "2096" "2087" "2083" "2053")
        NEZHA_TLS=""
        for p in "${TLS_PORTS[@]}"; do
            if [ "$NEZHA_PORT" == "$p" ]; then NEZHA_TLS="--tls"; break; fi
        done
        # 拼接启动命令供 Systemd 或 nohup 使用
        NEZHA_CMD="$AGENT_BIN -s ${NEZHA_SERVER}:${NEZHA_PORT} -p ${NEZHA_KEY} ${NEZHA_TLS} --disable-auto-update --report-delay 4 --skip-conn --skip-procs"
    fi
}

download_files() {
    mkdir -p "$WORK_DIR"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then DL_ARCH="arm64";
    elif [[ "$ARCH" == "x86_64" ]]; then DL_ARCH="amd64";
    else echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1; fi

    echo -e "${YELLOW}正在下载核心组件 (架构: $DL_ARCH)...${PLAIN}"
    wget -q --show-progress -O "$WEB_BIN" "https://${DL_ARCH}.ssss.nyc.mn/web"
    wget -q --show-progress -O "$BOT_BIN" "https://${DL_ARCH}.ssss.nyc.mn/bot"
    if [ -n "$NEZHA_CMD" ]; then
        wget -q --show-progress -O "$AGENT_BIN" "https://${DL_ARCH}.ssss.nyc.mn/agent"
        chmod +x "$AGENT_BIN"
    fi
    chmod +x "$WEB_BIN" "$BOT_BIN"
}

generate_config() {
    cat <<EOF > "$CONFIG_FILE"
{
    "log": { "loglevel": "none" },
    "inbounds": [
        {
            "port": 8001,
            "protocol": "vless",
            "settings": {
                "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
                "decryption": "none",
                "fallbacks": [
                    { "dest": 3001 },
                    { "path": "/vless-argo", "dest": 3002 },
                    { "path": "/vmess-argo", "dest": 3003 },
                    { "path": "/trojan-argo", "dest": 3004 }
                ]
            },
            "streamSettings": { "network": "tcp" }
        },
        { "port": 3001, "listen": "127.0.0.1", "protocol": "vless", "settings": { "clients": [{ "id": "$UUID" }], "decryption": "none" }, "streamSettings": { "network": "tcp", "security": "none" } },
        { "port": 3002, "listen": "127.0.0.1", "protocol": "vless", "settings": { "clients": [{ "id": "$UUID", "level": 0 }], "decryption": "none" }, "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/vless-argo" } } },
        { "port": 3003, "listen": "127.0.0.1", "protocol": "vmess", "settings": { "clients": [{ "id": "$UUID", "alterId": 0 }] }, "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess-argo" } } },
        { "port": 3004, "listen": "127.0.0.1", "protocol": "trojan", "settings": { "clients": [{ "password": "$UUID" }] }, "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/trojan-argo" } } }
    ],
    "outbounds": [ { "protocol": "freedom", "tag": "direct" }, { "protocol": "blackhole", "tag": "block" } ]
}
EOF
}

# ----------------------------------------------------------
# 运行方式：Nohup (普通) 或 Systemd (推荐)
# ----------------------------------------------------------
start_nohup() {
    echo -e "${YELLOW}正在使用 nohup 后台启动...${PLAIN}"
    nohup "$WEB_BIN" -c "$CONFIG_FILE" > /dev/null 2>&1 &
    
    if [ -n "$NEZHA_CMD" ]; then
        nohup $NEZHA_CMD > /dev/null 2>&1 &
    fi

    if [ -n "$ARGO_AUTH" ]; then
        nohup "$BOT_BIN" tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token "$ARGO_AUTH" > /dev/null 2>&1 &
        DOMAIN="$ARGO_DOMAIN"
    else
        rm -f "$ARGO_LOG"
        nohup "$BOT_BIN" tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --logfile "$ARGO_LOG" --loglevel info --url http://localhost:8001 > /dev/null 2>&1 &
        echo -e "${YELLOW}正在申请临时域名...${PLAIN}"
        sleep 5
        DOMAIN=$(grep -oE "https://.*trycloudflare.com" "$ARGO_LOG" | head -n 1 | sed 's/https:\/\///')
    fi
}

start_systemd() {
    if [ ! -d "/etc/systemd/system" ]; then
        echo -e "${RED}未检测到 Systemd，将回退到 nohup 模式。${PLAIN}"
        start_nohup
        return
    fi

    echo -e "${YELLOW}正在配置 Systemd 服务 (开机自启)...${PLAIN}"

    # 构建 ExecStart 命令
    # 创建一个 wrapper 脚本来管理所有进程，简化 Systemd 配置
    WRAPPER_SCRIPT="$WORK_DIR/entrypoint.sh"
    
    cat <<EOF > "$WRAPPER_SCRIPT"
#!/bin/bash
# 启动 Xray
$WEB_BIN -c $CONFIG_FILE &

# 启动 Nezha (如果有)
${NEZHA_CMD} &

# 启动 Argo
if [ -n "$ARGO_AUTH" ]; then
    $BOT_BIN tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token "$ARGO_AUTH"
else
    # 临时隧道模式
    $BOT_BIN tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --logfile $ARGO_LOG --loglevel info --url http://localhost:8001
fi
wait
EOF
    chmod +x "$WRAPPER_SCRIPT"

    # 生成 service 文件
    sudo cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Argo Tunnel Service
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$WORK_DIR
ExecStart=$WRAPPER_SCRIPT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # 启用并启动
    sudo systemctl daemon-reload
    sudo systemctl enable ${SERVICE_NAME}
    sudo systemctl restart ${SERVICE_NAME}
    
    echo -e "${GREEN}Systemd 服务已安装并启动！${PLAIN}"
    
    # 临时隧道需等待日志
    if [ -z "$ARGO_AUTH" ]; then
        echo -e "${YELLOW}正在申请临时域名...${PLAIN}"
        sleep 5
        DOMAIN=$(grep -oE "https://.*trycloudflare.com" "$ARGO_LOG" | head -n 1 | sed 's/https:\/\///')
    else
        DOMAIN="$ARGO_DOMAIN"
    fi
}

# ----------------------------------------------------------
# 结果输出
# ----------------------------------------------------------
print_result() {
    if [ -z "$DOMAIN" ]; then
        if [ -z "$ARGO_AUTH" ]; then
            sleep 5
            DOMAIN=$(grep -oE "https://.*trycloudflare.com" "$ARGO_LOG" | head -n 1 | sed 's/https:\/\///')
        fi
        if [ -z "$DOMAIN" ]; then echo -e "${RED}域名获取失败，请运行 cat $ARGO_LOG 查看日志${PLAIN}"; return; fi
    fi

    CFIP="cdns.doon.eu.org" 
    CFPORT="443"
    NAME="ArgoNode"
    
    VLESS_LINK="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${DOMAIN}&fp=firefox&type=ws&host=${DOMAIN}&path=%2Fvless-argo%3Fed%3D2560#${NAME}-VLESS"
    VMESS_JSON="{\"v\":\"2\",\"ps\":\"${NAME}-VMESS\",\"add\":\"${CFIP}\",\"port\":\"${CFPORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"none\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"/vmess-argo?ed=2560\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\",\"alpn\":\"\",\"fp\":\"firefox\"}"
    VMESS_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"
    TROJAN_LINK="trojan://${UUID}@${CFIP}:${CFPORT}?security=tls&sni=${DOMAIN}&fp=firefox&type=ws&host=${DOMAIN}&path=%2Ftrojan-argo%3Fed%3D2560#${NAME}-Trojan"

    echo -e "\n${GREEN}================ 节点配置 ================${PLAIN}"
    echo -e "${SKYBLUE}VLESS:${PLAIN}\n$VLESS_LINK"
    echo -e "${SKYBLUE}VMESS:${PLAIN}\n$VMESS_LINK"
    echo -e "${SKYBLUE}Trojan:${PLAIN}\n$TROJAN_LINK"
    
    echo "$VLESS_LINK" > "$WORK_DIR/list.txt"
    echo "$VMESS_LINK" >> "$WORK_DIR/list.txt"
    echo "$TROJAN_LINK" >> "$WORK_DIR/list.txt"
    echo -e "${GREEN}配置已保存至: $WORK_DIR/list.txt${PLAIN}"
}

# ----------------------------------------------------------
# 卸载与菜单
# ----------------------------------------------------------
uninstall() {
    echo -e "${YELLOW}正在卸载...${PLAIN}"
    # 停止 Systemd
    if [ -f "$SERVICE_FILE" ]; then
        sudo systemctl stop ${SERVICE_NAME}
        sudo systemctl disable ${SERVICE_NAME}
        sudo rm "$SERVICE_FILE"
        sudo systemctl daemon-reload
        echo -e "${GREEN}Systemd 服务已移除${PLAIN}"
    fi
    
    # 停止进程
    pkill -f "$WEB_BIN"
    pkill -f "$BOT_BIN"
    pkill -f "$AGENT_BIN"
    pkill -f "entrypoint.sh"
    
    # 删除文件
    rm -rf "$WORK_DIR"
    echo -e "${GREEN}所有文件已清理。${PLAIN}"
}

install() {
    check_dependencies
    get_user_input
    download_files
    generate_config
    
    echo -e "\n${YELLOW}请选择运行模式:${PLAIN}"
    echo "1. Systemd 服务 (推荐，支持开机自启，需要 root/sudo)"
    echo "2. Nohup 后台运行 (简单，无权限要求，重启失效)"
    read -p "选择 [1-2] (默认1): " RUN_MODE
    
    if [[ "$RUN_MODE" == "2" ]]; then
        start_nohup
    else
        # 默认尝试 Systemd
        start_systemd
    fi
    
    print_result
}

menu() {
    clear
    echo -e "${GREEN}####################################################${PLAIN}"
    echo -e "${GREEN}#    Xray + Argo Tunnel + Nezha 全能脚本           #${PLAIN}"
    echo -e "${GREEN}#    支持：Debian / CentOS / Alpine / Ubuntu       #${PLAIN}"
    echo -e "${GREEN}####################################################${PLAIN}"
    echo -e " 1. 安装 / 重置配置 (Install)"
    echo -e " 2. 查看当前节点链接 (Show Links)"
    echo -e " 3. 卸载 (Uninstall)"
    echo -e " 0. 退出 (Exit)"
    read -p "请输入: " choice
    case $choice in
        1) install ;;
        2) 
            if [ -f "$WORK_DIR/list.txt" ]; then cat "$WORK_DIR/list.txt"; else echo "未找到配置文件"; fi 
            ;;
        3) uninstall ;;
        0) exit 0 ;;
        *) echo "无效选项"; menu ;;
    esac
}

menu
