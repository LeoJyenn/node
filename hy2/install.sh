#!/usr/bin/env sh

DOMAIN="${DOMAIN:-node68.lunes.host}"
PORT="${PORT:-10008}"
UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"
HY2_PASSWORD="${HY2_PASSWORD:-$(openssl rand -base64 12)}"

curl -sSL -o app.js https://raw.githubusercontent.com/LeoJyenn/node/refs/heads/main/hy2/app.js
curl -sSL -o package.json https://raw.githubusercontent.com/LeoJyenn/node/refs/heads/main/hy2/package.json

mkdir -p /home/container/h2
cd /home/container/h2
curl -sSL -o h2 https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64
curl -sSL -o config.yaml https://raw.githubusercontent.com/LeoJyenn/node/refs/heads/main/hy2/hysteria-config.yaml
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"
chmod +x h2
sed -i "s/10008/$PORT/g" config.yaml
sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" config.yaml
encodedHy2Pwd=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")
hy2Url="hysteria2://$encodedHy2Pwd@$DOMAIN:$PORT?insecure=1#lunes-hy2"
echo $hy2Url > /home/container/node.txt

# 判断是否安装哪吒监控
if [ -n "$NEZHA_SERVER" ] && [ -n "$NEZHA_KEY" ]; then
    echo "[NEZHA] Installing Nezha Agent binary..."
    mkdir -p /home/container/nz
    cd /home/container/nz
    curl -sSL -o nezha-agent.zip https://github.com/nezhahq/agent/releases/download/v1.14.1/nezha-agent_linux_amd64.zip
    unzip -o nezha-agent.zip
    rm nezha-agent.zip
    mv nezha-agent nz
    chmod +x nz

    echo "[NEZHA] Creating config.yaml..."
    TLS_VALUE="${NZ_TLS:-true}"

    cat > /home/container/nz/config.yaml << EOF
server: $NEZHA_SERVER
client_secret: $NEZHA_KEY
tls: $TLS_VALUE
EOF

    echo "[NEZHA] Testing config..."
    timeout 2s ./nz -c config.yaml >/dev/null 2>&1 || true

    sleep 1

    if [ -f "/home/container/nz/config.yaml" ]; then
        if ! grep -q "secret: $NEZHA_KEY" /home/container/nz/config.yaml; then
            echo "[NEZHA] Recreating config..."
            cat > /home/container/nz/config.yaml << EOF
server: $NEZHA_SERVER
secret: $NEZHA_KEY
tls: $TLS_VALUE
EOF
        fi
        
    fi

    echo "[NEZHA] Nezha Agent installed."
else
    echo "[NEZHA] Skip installation due to missing NEZHA_SERVER or NEZHA_KEY."
fi

cd /home/container

echo "============================================================"
echo "🚀 HY2 Node Info"
echo "------------------------------------------------------------"
echo "$hy2Url"
echo "============================================================"
