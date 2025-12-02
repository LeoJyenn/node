#!/usr/bin/env sh

PORT=""
NEZHA_SERVER=""
NEZHA_KEY=""
HY2_PASSWORD="${HY2_PASSWORD:-$(openssl rand -base64 12)}"

IP=$(curl -s --max-time 2 ipv4.ip.sb || curl -s --max-time 1 api.ipify.org || echo "IP_ERROR")
echo "External IP: $IP"

curl -sSL -o index.js https://raw.githubusercontent.com/LeoJyenn/node/refs/heads/main/hy2/app.js
curl -sSL -o package.json https://raw.githubusercontent.com/LeoJyenn/node/refs/heads/main/hy2/package.json

mkdir -p /home/container/h2
cd /home/container/h2

if [ -f "/home/container/h2/h2" ]; then
    echo "Hysteria binary already exists. Skipping download."
else
    curl -sSL -o /home/container/h2/h2 https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.2/hysteria-linux-amd64
    chmod +x /home/container/h2/h2
    echo "Hysteria binary downloaded."
fi

if [ -f "/home/container/h2/config.yaml" ]; then
    echo "Hysteria config.yaml already exists. Skipping download."
else
    curl -sSL -o /home/container/h2/config.yaml https://raw.githubusercontent.com/LeoJyenn/node/refs/heads/main/hy2/hysteria-config.yaml
    echo "Config file downloaded."
fi

if [ -f "/home/container/h2/password.txt" ]; then
    HY2_PASSWORD=$(cat /home/container/h2/password.txt)
    echo "Using existing password: $HY2_PASSWORD"
else
    HY2_PASSWORD="${HY2_PASSWORD:-$(openssl rand -base64 12)}"
    echo "$HY2_PASSWORD" > /home/container/h2/password.txt
    echo "New password generated and saved."
fi

echo "Using port: $PORT"
echo "Using password: $HY2_PASSWORD"

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout /home/container/h2/key.pem -out /home/container/h2/cert.pem -subj "/CN=$IP"
chmod +x /home/container/h2

sed -i "s/10008/$PORT/g" /home/container/h2/config.yaml
sed -i "s/HY2_PASSWORD/$HY2_PASSWORD/g" /home/container/h2/config.yaml

encodedHy2Pwd=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")
hy2Url="hysteria2://${encodedHy2Pwd}@${IP}:${PORT}?insecure=1#lunes-hy2"
echo $hy2Url > /home/container/node.txt

if [ -n "$NEZHA_SERVER" ] && [ -n "$NEZHA_KEY" ]; then
  echo "[NEZHA] Installing Nezha Agent..."

  mkdir -p /home/container/nz
  cd /home/container/nz
  curl -sSL -o nezha-agent.zip https://github.com/nezhahq/agent/releases/download/v1.14.1/nezha-agent_linux_amd64.zip
  unzip -o nezha-agent.zip
  rm nezha-agent.zip
  mv nezha-agent nz
  chmod +x nz

  cat > /home/container/nz/config.yaml <<EOF
server: $NEZHA_SERVER
client_secret: $NEZHA_KEY
tls: ${NZ_TLS:-true}
EOF

  echo "[NEZHA] Nezha Agent installed."
else
  echo "[NEZHA] Nezha installation skipped (missing server or key)."
fi

cd /home/container
echo "============================================================"
echo "🚀 HY2 Node Info"
echo "------------------------------------------------------------"
echo "$hy2Url"
echo "============================================================"

npm install
npm start
