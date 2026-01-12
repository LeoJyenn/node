#!/bin/bash
# onekey cf modified: vless only + token

# 基础依赖检查与安装
linux_os=("Debian" "Ubuntu" "CentOS" "Fedora" "Alpine")
linux_update=("apt update" "apt update" "yum -y update" "yum -y update")
linux_install=("apt -y install" "apt -y install" "yum -y install" "yum -y install")
n=0
for i in `echo ${linux_os[@]}`
do
	if [ $i == $(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2 | awk '{print $1}') ]
	then
		break
	else
		n=$[$n+1]
	fi
done
if [ $n == 5 ]
then
	echo 当前系统$(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2)没有适配
	echo 默认使用APT包管理器
	n=0
fi
if [ -z $(type -P unzip) ]
then
	${linux_update[$n]}
	${linux_install[$n]} unzip
fi
if [ -z $(type -P curl) ]
then
	${linux_update[$n]}
	${linux_install[$n]} curl
fi
if [ -z $(type -P systemctl) ]
then
	${linux_update[$n]}
	${linux_install[$n]} systemctl
fi

function installtunnel(){
    # 获取交互式输入
    clear
    echo "======================================================"
    echo "          Cloudflare Argo Tunnel + Xray VLESS         "
    echo "======================================================"
    
    # 1. 获取 Token
    read -p "请输入 Cloudflare Tunnel Token (在CF后台获取): " cf_token
    if [ -z "$cf_token" ]; then echo "Token 不能为空"; exit; fi

    # 2. 获取域名
    read -p "请输入绑定的完整域名 (例如 vpn.example.com): " cf_domain
    if [ -z "$cf_domain" ]; then echo "域名不能为空"; exit; fi

    # 3. 获取本地端口
    read -p "请输入 Xray 本地监听端口 (1000-65535): " local_port
    if [ -z "$local_port" ]; then echo "端口不能为空"; exit; fi

    #清理旧文件
    mkdir -p /opt/argotunnel/ >/dev/null 2>&1
    rm -rf xray cloudflared-linux xray.zip
    
    # 下载核心文件
    echo "正在下载组件..."
    case "$(uname -m)" in
        x86_64 | x64 | amd64 )
        curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip
        curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared-linux
        ;;
        i386 | i686 )
        curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-32.zip -o xray.zip
        curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386 -o cloudflared-linux
        ;;
        armv8 | arm64 | aarch64 )
        curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip -o xray.zip
        curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o cloudflared-linux
        ;;
        armv71 )
        curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip -o xray.zip
        curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm -o cloudflared-linux
        ;;
        * )
        echo 当前架构$(uname -m)没有适配
        exit
        ;;
    esac

    unzip -d xray xray.zip >/dev/null 2>&1
    chmod +x cloudflared-linux xray/xray
    mv cloudflared-linux /opt/argotunnel/
    mv xray/xray /opt/argotunnel/
    rm -rf xray xray.zip

    # 生成配置参数
    uuid=$(cat /proc/sys/kernel/random/uuid)
    urlpath=$(echo $uuid | awk -F- '{print $1}')
    
    # 生成 Xray 配置文件 (仅 VLESS)
    cat>/opt/argotunnel/config.json<<EOF
{
    "inbounds": [
        {
            "port": $local_port,
            "listen": "localhost",
            "protocol": "vless",
            "settings": {
                "decryption": "none",
                "clients": [
                    {
                        "id": "$uuid"
                    }
                ]
            },
            "streamSettings": {
                "network": "ws",
                "wsSettings": {
                    "path": "/$urlpath"
                }
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "settings": {}
        }
    ]
}
EOF

    # 创建 Cloudflared 服务 (使用 Token 模式，无需本地 Config)
    cat>/lib/systemd/system/cloudflared.service<<EOF
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

    # 创建 Xray 服务
    cat>/lib/systemd/system/xray.service<<EOF
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

    # 启动服务
    systemctl enable cloudflared.service >/dev/null 2>&1
    systemctl enable xray.service >/dev/null 2>&1
    systemctl --system daemon-reload
    systemctl start cloudflared.service
    systemctl start xray.service

    # 生成 VLESS 链接
    echo -e "VLESS 链接已生成" >/opt/argotunnel/v2ray.txt
    echo "------------------------------------------------------" >>/opt/argotunnel/v2ray.txt
    echo "UUID: $uuid" >>/opt/argotunnel/v2ray.txt
    echo "Path: /$urlpath" >>/opt/argotunnel/v2ray.txt
    echo "Port (Local): $local_port" >>/opt/argotunnel/v2ray.txt
    echo "Domain: $cf_domain" >>/opt/argotunnel/v2ray.txt
    echo "------------------------------------------------------" >>/opt/argotunnel/v2ray.txt
    
    # 构造标准 VLESS 链接
    # 注意：Cloudflare Tunnel 默认对外端口是 443 (TLS)
    vless_link="vless://$uuid@$cf_domain:443?encryption=none&security=tls&type=ws&host=$cf_domain&path=%2f$urlpath#Argo_VLESS"
    echo "$vless_link" >>/opt/argotunnel/v2ray.txt
    
    echo "" >>/opt/argotunnel/v2ray.txt
    echo "IMPORTANT: 请确保在 Cloudflare Dashboard (Zero Trust) -> Tunnels -> Public Hostname 中" >>/opt/argotunnel/v2ray.txt
    echo "添加了域名: $cf_domain" >>/opt/argotunnel/v2ray.txt
    echo "并指向服务: http://localhost:$local_port" >>/opt/argotunnel/v2ray.txt

    # 创建管理脚本
    cat>/opt/argotunnel/argotunnel.sh<<EOF
#!/bin/bash
clear
while true
do
echo argo \$(systemctl status cloudflared.service | sed -n '3p')
echo xray \$(systemctl status xray.service | sed -n '3p')
echo 1.重启服务
echo 2.停止服务
echo 3.查看 VLESS 链接
echo 4.卸载服务
echo 0.退出
read -p "请选择菜单(默认0): " menu
if [ -z "\$menu" ]
then
	menu=0
fi
if [ \$menu == 1 ]
then
	systemctl restart cloudflared.service
	systemctl restart xray.service
	echo 服务已重启
	sleep 1
elif [ \$menu == 2 ]
then
	systemctl stop cloudflared.service
	systemctl stop xray.service
	echo 服务已停止
	sleep 1
elif [ \$menu == 3 ]
then
	clear
	cat /opt/argotunnel/v2ray.txt
	echo ""
	read -p "按回车键继续..."
elif [ \$menu == 4 ]
then
	systemctl stop cloudflared.service
	systemctl stop xray.service
	systemctl disable cloudflared.service
	systemctl disable xray.service
	rm -rf /opt/argotunnel /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /usr/bin/argotunnel
	systemctl --system daemon-reload
	echo 服务已卸载
	exit
elif [ \$menu == 0 ]
then
	exit
fi
done
EOF
    chmod +x /opt/argotunnel/argotunnel.sh
    ln -sf /opt/argotunnel/argotunnel.sh /usr/bin/argotunnel
}

# 主入口
clear
echo "======================================================"
echo "      Cloudflare Argo Tunnel 快捷部署 (Token版)       "
echo "======================================================"
echo 1. 安装/重装服务
echo 2. 卸载服务
echo 0. 退出
read -p "请选择(默认1):" mode
if [ -z "$mode" ]; then mode=1; fi

if [ $mode == 1 ]; then
    installtunnel
    clear
    cat /opt/argotunnel/v2ray.txt
    echo -e "\n管理命令: argotunnel"
elif [ $mode == 2 ]; then
    systemctl stop cloudflared.service
    systemctl stop xray.service
    systemctl disable cloudflared.service
    systemctl disable xray.service
    rm -rf /opt/argotunnel /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /usr/bin/argotunnel
    systemctl --system daemon-reload
    echo "服务已卸载"
else
    exit
fi
