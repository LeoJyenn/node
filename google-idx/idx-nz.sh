#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

echo -e "${BLUE}"
echo "╔══════════════════════════════════════╗"
echo "║         Nezha Agent 安装脚本         ║"
echo "╚══════════════════════════════════════╝"
echo -e "${PLAIN}"

# 获取用户输入
read -p "请输入项目名称: " project_name
read -p "请输入哪吒监控面板地址: " nezha_server
read -p "请输入哪吒客户端密钥: " nezha_key

# 设置基础路径
BASE_DIR="/home/user/$project_name/app/nezha"

echo
echo -e "${YELLOW}开始安装 Nezha Agent...${PLAIN}"
echo "安装目录: $BASE_DIR"
echo

# 创建目录
echo -e "${BLUE}[1/5] 创建目录...${PLAIN}"
mkdir -p "$BASE_DIR"
cd "$BASE_DIR" || {
    echo -e "${RED}错误: 无法进入目录 $BASE_DIR${PLAIN}"
    exit 1
}

# 下载和解压
echo -e "${BLUE}[2/5] 下载 Nezha Agent...${PLAIN}"
wget -q https://github.com/nezhahq/agent/releases/latest/download/nezha-agent_linux_amd64.zip
unzip -q nezha-agent_linux_amd64.zip
rm -f nezha-agent_linux_amd64.zip

# 创建配置文件
echo -e "${BLUE}[3/5] 创建配置文件...${PLAIN}"
cat > config.yaml << CONFIG
server: "$nezha_server"
client_secret: "$nezha_key"
tls: true
disable_auto_update: false
CONFIG

# 赋予执行权限
echo -e "${BLUE}[4/5] 设置执行权限...${PLAIN}"
chmod +x nezha-agent

# 创建启动脚本
echo -e "${BLUE}[5/5] 创建启动脚本...${PLAIN}"
cat > startup.sh << 'SCRIPT'
#!/usr/bin/env sh
cd "$(dirname "$0")"
nohup ./nezha-agent -c config.yaml > nezha.log 2>&1 &
SCRIPT

chmod +x startup.sh

echo
echo -e "${GREEN}✅ 安装完成！${PLAIN}"
echo
echo "请将以下命令加入启动方法："
echo "nezha = \"$BASE_DIR/startup.sh\";"