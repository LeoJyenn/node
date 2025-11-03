#!/usr/bin/env sh

# 原有的配置保持不变
sed -i "s/UUID/$UUID/g" /app/xy/config.json
sed -i "s/DOMAIN/$DOMAIN/g" /app/keepalive.sh

# 添加哪吒探针配置（可选）
if [ -n "$NEZHA_SERVER" ] && [ -n "$NEZHA_KEY" ]; then
  # 默认TLS为true
  TLS_VALUE="true"
  
  cat > /app/nz/config.yaml << EOF
server: $NEZHA_SERVER
client_secret: $NEZHA_KEY
tls: $TLS_VALUE
EOF
  echo "哪吒探针配置已生成"
else
  echo "未提供哪吒探针配置，跳过"
  # 确保没有配置文件
  rm -f /app/nz/config.yaml
fi

# 检查supervisord是否可用
if command -v supervisord >/dev/null 2>&1; then
    echo "✓ supervisord found, starting services..."
    exec "$@"
else
    echo "✗ supervisord not found, starting services directly..."
    # 备用方案：直接启动服务
    /usr/local/bin/xy -c /app/xy/config.json &
    if [ -f "/app/nz/config.yaml" ]; then
        /usr/local/bin/nz -c /app/nz/config.yaml &
    fi
    /usr/local/bin/td -p 80 -W bash &
    # 等待所有子进程
    wait
fi
