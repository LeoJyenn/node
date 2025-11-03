#!/usr/bin/env sh

DOMAIN="${DOMAIN:-node68.lunes.host}"
PORT="${PORT:-10008}"
UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"
HY2_PASSWORD="${HY2_PASSWORD:-$(openssl rand -base64 12)}"

curl -sSL -o app.js https://raw.githubusercontent.com/LeoJyenn/one-node/refs/heads/main/lunes-host/app.js
curl -sSL -o package.json https://raw.githubusercontent.com/LeoJyenn/one-node/refs/heads/main/lunes-host/package.json

mkdir -p /home/container/xy
cd /home/container/xy
curl -sSL -o Xray-linux-64.zip https://github.com/XTLS/Xray-core/releases/download/v25.8.3/Xray-linux-64.zip
unzip -o Xray-linux-64.zip
rm Xray-linux-64.zip
mv xray xy
curl -sSL -o config.json https://raw.githubusercontent.com/LeoJyenn/one-node/refs/heads/main/lunes-host/xray-config.json
sed -i "s/10008/$PORT/g" config.json
sed -i "s/YOUR_UUID/$UUID/g" config.json
keyPair=$(./xy x25519)
privateKey=$(echo "$keyPair" | grep "Private key" | awk '{print $3}')
publicKey=$(echo "$keyPair" | grep "Public key" | awk '{print $3}')
sed -i "s/YOUR_PRIVATE_KEY/$privateKey/g" config.json
shortId=$(openssl rand -hex 4)
sed -i "s/YOUR_SHORT_ID/$shortId/g" config.json
vlessUrl="vless://$UUID@$DOMAIN:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.cloudflare.com&fp=chrome&pbk=$publicKey&sid=$shortId&spx=%2F&type=tcp&headerType=none#lunes-reality"
echo $vlessUrl > /home/container/node.txt

mkdir -p /home/container/h2
cd /home/container/h2
curl -sSL -o h2 https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64
curl -sSL -o config.yaml https://raw.githubusercontent.com/LeoJyenn/one-node/refs/heads/main/lunes-host/hysteria-config.yaml
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout key.pem -out cert.pem -subj "/CN=$DOMAIN"
chmod +x h2
sed -i "s/10008/$PORT/g" config.yaml
sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" config.yaml
encodedHy2Pwd=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")
hy2Url="hysteria2://$encodedHy2Pwd@$DOMAIN:$PORT?insecure=1#lunes-hy2"
echo $hy2Url >> /home/container/node.txt

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
echo "🚀 VLESS Reality & HY2 Node Info"
echo "------------------------------------------------------------"
echo "$vlessUrl"
echo "$hy2Url"
echo "============================================================"
