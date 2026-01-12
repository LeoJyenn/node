#!/bin/bash

R='\033[0;31m'
G='\033[0;32m'
Y='\033[0;33m'
B='\033[0;34m'
E='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${R}Error: This script must be run as root!${E}"
    exit 1
fi

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
    echo -e "${R}OS not fully supported, trying default apt...${E}"
    pkg_mgr="apt -y install"
    update_cmd="apt update"
    svc_start="systemctl start"
    svc_enable="systemctl enable"
    svc_restart="systemctl restart"
    svc_stop="systemctl stop"
fi

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

install_tunnel() {
    clear
    echo -e "${B}======================================================${E}"
    echo -e "${G}          Cloudflare Argo Tunnel + Xray VLESS         ${E}"
    echo -e "${B}======================================================${E}"
    
    echo -e "${Y}[1/3] Configuration${E}"
    read -p "Token: " cf_token
    if [ -z "$cf_token" ]; then echo -e "${R}Token required${E}"; exit; fi

    read -p "Domain (e.g., vpn.example.com): " cf_domain
    if [ -z "$cf_domain" ]; then echo -e "${R}Domain required${E}"; exit; fi

    read -p "Local Port (1000-65535): " local_port
    if [ -z "$local_port" ]; then echo -e "${R}Port required${E}"; exit; fi

    echo -e "\n${Y}[2/3] Installing Core Components...${E}"
    
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
            echo -e "${R}Unsupported architecture: $arch${E}"
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

    echo -e "\n${Y}[3/3] Configuring Services...${E}"

    if [ $is_alpine -eq 1 ]; then
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

    echo -e "${G}Success! Service Installed.${E}"
    
    cat > /opt/argotunnel/v2ray.txt <<EOF
======================================================
      Xray VLESS Configuration Info
======================================================
Domain:   $cf_domain
UUID:     $uuid
Path:     /$urlpath
Port:     443
Security: TLS
------------------------------------------------------
VLESS Link:
vless://$uuid@$cf_domain:443?encryption=none&security=tls&type=ws&host=$cf_domain&path=%2f$urlpath#Argo_VLESS
------------------------------------------------------
NOTE: Ensure Public Hostname in CF Dashboard points to
http://localhost:$local_port
======================================================
EOF

    create_manager
    echo -e "Command: ${G}argo${E}"
}

create_manager() {
    cat > /opt/argotunnel/argotunnel.sh <<EOF
#!/bin/bash
R='\033[0;31m'
G='\033[0;32m'
Y='\033[0;33m'
E='\033[0m'
clear
echo -e "\${G}=== Tunnel Manager (argo) ===\${E}"
echo "1. Restart Services"
echo "2. Stop Services"
echo "3. Show Config"
echo "4. Uninstall"
echo "0. Exit"
read -p "Select: " menu
case \$menu in
    1)
        if [ $is_alpine -eq 1 ]; then
            rc-service cloudflared restart
            rc-service xray restart
        else
            systemctl restart cloudflared xray
        fi
        echo -e "\${G}Restarted.\${E}"
        ;;
    2)
        if [ $is_alpine -eq 1 ]; then
            rc-service cloudflared stop
            rc-service xray stop
        else
            systemctl stop cloudflared xray
        fi
        echo -e "\${R}Stopped.\${E}"
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
        echo -e "\${G}Uninstalled.\${E}"
        exit
        ;;
    0) exit ;;
esac
EOF
    chmod +x /opt/argotunnel/argotunnel.sh
    ln -sf /opt/argotunnel/argotunnel.sh /usr/bin/argo
}

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
    echo -e "${G}System Cleaned.${E}"
}

clear
echo -e "${B}--------------------------------${E}"
echo -e "${G}   Argo Tunnel OneKey Manager   ${E}"
echo -e "${B}--------------------------------${E}"
echo -e "1. Install"
echo -e "2. Uninstall"
echo -e "0. Exit"
read -p "Select: " main_opt

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
