#!/bin/bash

# 定义颜色
R='\033[0;31m'
G='\033[0;32m'
Y='\033[0;33m'
B='\033[0;34m'
E='\033[0m'

# 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${R}错误: 此脚本必须以 root 身份运行!${E}"
    exit 1
fi

# 系统检测
release_check=$(grep -i PRETTY_NAME /etc/os-release 2>/dev/null)
is_alpine=0

if [[ "$release_check" =~ "Alpine" ]]; then
    is_alpine=1
    pkg_mgr="apk add --no-cache"
    update_cmd="apk update"
    svc_start="rc-service"
    svc_enable="rc-update add"
    svc_restart="rc-service"
    svc_stop="rc-service"
elif [[ -f /usr/bin/apt ]] || [[ -f /usr/bin/apt-get ]]; then
    pkg_mgr="apt -y install"
    update_cmd="apt update"
    svc_start="systemctl start"
    svc_enable="systemctl enable"
    svc_restart="systemctl restart"
    svc_stop="systemctl stop"
elif [[ -f /usr/bin/yum ]]; then
    pkg_mgr="yum -y install"
    update_cmd="yum -y update"
    svc_start="systemctl start"
    svc_enable="systemctl enable"
    svc_restart="systemctl restart"
    svc_stop="systemctl stop"
else
    echo -e "${R}系统未完全适配，尝试使用默认 apt...${E}"
    pkg_mgr="apt -y install"
    update_cmd="apt update"
    svc_start="systemctl start"
    svc_enable="systemctl enable"
    svc_restart="systemctl restart"
    svc_stop="systemctl stop"
fi

# 安装依赖
install_dependencies() {
    $update_cmd
    # Alpine 需要额外安装 bash 才能运行管理脚本
    if [ $is_alpine -eq 1 ]; then
        $pkg_mgr bash curl unzip libc6-compat ca-certificates
    else
        $pkg_mgr curl unzip
    fi
    
    if [ $is_alpine -eq 0 ] && [ -z "$(command -v systemctl)" ]; then
        $pkg_mgr systemd
    fi
}

# 安装主逻辑
install_tunnel() {
    clear
    echo -e "${B}======================================================${E}"
    echo -e "${G}          Cloudflare Argo Tunnel + Xray VLESS         ${E}"
    echo -e "${B}======================================================${E}"
    
    echo -e "${Y}[1/3] 配置参数${E}"
    read -p "请输入 Cloudflare Token: " cf_token
    
    # === 自动提取 Token 逻辑 ===
    cf_token=$(echo "$cf_token" | awk '{print $NF}')
    
    if [ -z "$cf_token" ]; then echo -e "${R}必须输入 Token${E}"; exit; fi

    read -p "请输入绑定域名 (例如 vpn.example.com): " cf_domain
    if [ -z "$cf_domain" ]; then echo -e "${R}必须输入域名${E}"; exit; fi

    read -p "请输入本地端口 (1000-65535): " local_port
    if [ -z "$local_port" ]; then echo -e "${R}必须输入端口${E}"; exit; fi

    echo -e "\n${Y}[2/3] 正在安装核心组件...${E}"
    
    mkdir -p /opt/argotunnel/
    rm -rf /opt/argotunnel/xray /opt/argotunnel/cloudflared-linux /opt/argotunnel/*.zip

    arch=$(uname -m)
    case "$arch" in
        x86_64|x64|amd64)
            xray_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
            cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            ;;
        i386|i686)
            xray_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-32.zip"
            cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386"
            ;;
        armv8|arm64|aarch64)
            xray_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip"
            cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            ;;
        armv7*)
            xray_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip"
            cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
            ;;
        *)
            echo -e "${R}不支持的架构: $arch${E}"
            exit 1
            ;;
    esac

    curl -L $xray_url -o /opt/argotunnel/xray.zip
    curl -L $cf_url -o /opt/argotunnel/cloudflared-linux
    
    unzip -d /opt/argotunnel/xray_temp /opt/argotunnel/xray.zip >/dev/null 2>&1
    mv /opt/argotunnel/xray_temp/xray /opt/argotunnel/xray
    chmod +x /opt/argotunnel/cloudflared-linux /opt/argotunnel/xray
    rm -rf /opt/argotunnel/xray_temp /opt/argotunnel/xray.zip

    uuid=$(cat /proc/sys/kernel/random/uuid)
    urlpath=$(echo $uuid | cut -d- -f1)

    # 写入 Xray 配置
    cat > /opt/argotunnel/config.json <<EOF
{
    "inbounds": [{
        "port": $local_port,
        "listen": "localhost",
        "protocol": "vless",
        "settings": {
            "decryption": "none",
            "clients": [{"id": "$uuid"}]
        },
        "streamSettings": {
            "network": "ws",
            "wsSettings": {"path": "/$urlpath"}
        }
    }],
    "outbounds": [{"protocol": "freedom","settings": {}}]
}
EOF

    echo -e "\n${Y}[3/3] 正在配置服务...${E}"

    if [ $is_alpine -eq 1 ]; then
        # Alpine OpenRC 配置
        cat > /etc/init.d/cloudflared <<EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel"
command="/opt/argotunnel/cloudflared-linux"
command_args="tunnel run --token $cf_token"
command_background=true
pidfile="/run/cloudflared.pid"
EOF
        cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
description="Xray Service"
command="/opt/argotunnel/xray"
command_args="run -config /opt/argotunnel/config.json"
command_background=true
pidfile="/run/xray.pid"
EOF
        chmod +x /etc/init.d/cloudflared /etc/init.d/xray
        $svc_enable cloudflared default >/dev/null 2>&1
        $svc_enable xray default >/dev/null 2>&1
        $svc_start cloudflared start
        $svc_start xray start
    else
        # Systemd 配置
        cat > /lib/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
TimeoutStartSec=0
Type=simple
ExecStart=/opt/argotunnel/cloudflared-linux tunnel run --token $cf_token
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
        cat > /lib/systemd/system/xray.service <<EOF
[Unit]
Description=Xray
After=network.target
[Service]
TimeoutStartSec=0
Type=simple
ExecStart=/opt/argotunnel/xray run -config /opt/argotunnel/config.json
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
        $svc_enable cloudflared.service >/dev/null 2>&1
        $svc_enable xray.service >/dev/null 2>&1
        systemctl daemon-reload
        $svc_start cloudflared.service
        $svc_start xray.service
    fi

    echo -e "${G}成功! 服务已安装。${E}"
    
    vless_link="vless://$uuid@$cf_domain:443?encryption=none&security=tls&type=ws&host=$cf_domain&sni=$cf_domain&path=%2f$urlpath#Argo_VLESS"

    # 生成节点信息文件
    cat > /opt/argotunnel/v2ray.txt <<EOF
======================================================
           Xray VLESS 配置信息
======================================================
域名 (Domain):   $cf_domain
UUID:           $uuid
路径 (Path):     /$urlpath
SNI:            $cf_domain
端口 (Port):     443
安全 (Security): TLS
------------------------------------------------------
VLESS 链接:
$vless_link
------------------------------------------------------
注意: 请确保在 Cloudflare Zero Trust 后台 (Public Hostname)
已将该域名指向 http://localhost:$local_port
======================================================
EOF

    create_manager
    echo -e "管理命令: ${G}argo${E}"
}

# 创建管理脚本
create_manager() {
    cat > /opt/argotunnel/argotunnel.sh <<EOF
#!/bin/bash
R='\033[0;31m'
G='\033[0;32m'
Y='\033[0;33m'
E='\033[0m'
clear
echo -e "\${G}=== 隧道管理菜单 (argo) ===\${E}"
echo "1. 重启服务"
echo "2. 停止服务"
echo "3. 查看配置/链接"
echo "4. 卸载服务"
echo "0. 退出"
read -p "请选择: " menu
case \$menu in
    1)
        if [ $is_alpine -eq 1 ]; then
            rc-service cloudflared restart
            rc-service xray restart
        else
            systemctl restart cloudflared xray
        fi
        echo -e "\${G}已重启。\${E}"
        ;;
    2)
        if [ $is_alpine -eq 1 ]; then
            rc-service cloudflared stop
            rc-service xray stop
        else
            systemctl stop cloudflared xray
        fi
        echo -e "\${R}已停止。\${E}"
        ;;
    3)
        clear
        cat /opt/argotunnel/v2ray.txt
        echo ""
        ;;
    4)
        if [ $is_alpine -eq 1 ]; then
            rc-service cloudflared stop
            rc-service xray stop
            rc-update del cloudflared default
            rc-update del xray default
            rm -f /etc/init.d/cloudflared /etc/init.d/xray
        else
            systemctl stop cloudflared xray
            systemctl disable cloudflared xray
            rm -f /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service
            systemctl daemon-reload
        fi
        rm -rf /opt/argotunnel /usr/bin/argo
        echo -e "\${G}已卸载。\${E}"
        exit
        ;;
    0) exit ;;
esac
EOF
    chmod +x /opt/argotunnel/argotunnel.sh
    ln -sf /opt/argotunnel/argotunnel.sh /usr/bin/argo
}

# 卸载逻辑
uninstall_service() {
    if [ $is_alpine -eq 1 ]; then
        rc-service cloudflared stop 2>/dev/null
        rc-service xray stop 2>/dev/null
        rc-update del cloudflared default 2>/dev/null
        rc-update del xray default 2>/dev/null
        rm -f /etc/init.d/cloudflared /etc/init.d/xray
    else
        systemctl stop cloudflared xray 2>/dev/null
        systemctl disable cloudflared xray 2>/dev/null
        rm -f /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service
        systemctl daemon-reload
    fi
    rm -rf /opt/argotunnel /usr/bin/argo
    echo -e "${G}系统已清理。${E}"
}

# 主菜单
clear
echo -e "${B}--------------------------------${E}"
echo -e "${G}   Argo Tunnel 一键管理脚本   ${E}"
echo -e "${B}--------------------------------${E}"
echo -e "1. 安装服务"
echo -e "2. 卸载服务"
echo -e "0. 退出"
read -p "请选择: " main_opt

case $main_opt in
    1)
        install_dependencies
        install_tunnel
        cat /opt/argotunnel/v2ray.txt
        ;;
    2)
        uninstall_service
        ;;
    *)
        exit
        ;;
esac
