#!/usr/bin/env sh
set -eu

PORT="${PORT:-端口}"
NEZHA_SERVER="${NEZHA_SERVER:-哪吒v1地址}"
NEZHA_KEY="${NEZHA_KEY:-哪吒密钥}"

HYSTERIA_VERSION="${HYSTERIA_VERSION:-v2.6.2}"
HYSTERIA_BIN_NAME="hysteria-linux-amd64"
HYSTERIA_RELEASE_URL="https://github.com/apernet/hysteria/releases/download/app%2F${HYSTERIA_VERSION}/${HYSTERIA_BIN_NAME}"
NEZHA_AGENT_URL="${NEZHA_AGENT_URL:-https://github.com/nezhahq/agent/releases/download/v1.14.1/nezha-agent_linux_amd64.zip}"

INSTALL_MARKER="/home/container/.hy2_installed"
H2_DIR="/home/container/h2"
NZ_DIR="/home/container/nz"
NODE_TXT="/home/container/node.txt"
PASSWORD_FILE="${H2_DIR}/password.txt"
CONFIG_FILE="${H2_DIR}/config.yaml"
H2_BIN="${H2_DIR}/h2"

mkdir -p "$H2_DIR"

get_public_ip() {
  services="https://ipv4.ip.sb https://api.ipify.org https://ifconfig.me"
  for svc in $services; do
    ip=$(curl -s --max-time 5 "$svc" || true)
    if [ -n "$ip" ]; then
      if echo "$ip" | grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' >/dev/null 2>&1; then
        echo "$ip"
        return 0
      fi
    fi
  done
  echo "IP_ERROR"
  return 1
}

IP=$(get_public_ip || true)
echo "External IP: $IP"

if [ -f "$INSTALL_MARKER" ]; then
  echo "Installation marker found, skipping install steps."
else
  echo "Running first-time install steps..."

  if [ ! -f "/home/container/package.json" ]; then
    curl -sSL -o /home/container/package.json "https://raw.githubusercontent.com/LeoJyenn/node/refs/heads/main/hy2/package.json" || { echo "Failed to download package.json"; exit 1; }
  else
    echo "package.json already exists, skipping download."
  fi

  if [ -f "$H2_BIN" ]; then
    echo "Hysteria binary already exists. Skipping download."
  else
    curl -sSL -o "${H2_DIR}/hysteria.tmp" "$HYSTERIA_RELEASE_URL" || { echo "Failed to download hysteria binary"; rm -f "${H2_DIR}/hysteria.tmp"; exit 1; }
    mv "${H2_DIR}/hysteria.tmp" "$H2_BIN"
    chmod 700 "$H2_BIN"
    echo "Hysteria binary downloaded."
  fi

  if [ -f "$CONFIG_FILE" ]; then
    echo "Hysteria config.yaml already exists. Skipping download."
  else
    curl -sSL -o "$CONFIG_FILE" "https://raw.githubusercontent.com/LeoJyenn/node/refs/heads/main/hy2/hysteria-config.yaml" || { echo "Failed to download config.yaml"; exit 1; }
    echo "Config file downloaded."
  fi

  if [ -f "$PASSWORD_FILE" ]; then
    HY2_PASSWORD=$(cat "$PASSWORD_FILE")
    echo "Using existing password from file."
  else
    if command -v openssl >/dev/null 2>&1; then
      HY2_PASSWORD="$(openssl rand -base64 12)"
    else
      HY2_PASSWORD="$(date +%s | sha256sum | head -c 16)"
    fi
    printf '%s' "$HY2_PASSWORD" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
    echo "New password generated and saved."
  fi

  echo "Using port: $PORT"
  echo "Using password: $HY2_PASSWORD"

  if [ ! -f "${H2_DIR}/key.pem" ] || [ ! -f "${H2_DIR}/cert.pem" ]; then
    CN="$IP"
    if [ "$CN" = "IP_ERROR" ] || [ -z "$CN" ]; then
      CN="localhost"
    fi
    openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout "${H2_DIR}/key.pem" -out "${H2_DIR}/cert.pem" -subj "/CN=${CN}" >/dev/null 2>&1 || { echo "Warning: openssl failed to generate certs"; }
  fi

  escaped_pwd=$(printf '%s' "$HY2_PASSWORD" | sed 's/[\/&]/\\&/g')
  sed -i "s|10008|$PORT|g" "$CONFIG_FILE" || true
  sed -i "s|HY2_PASSWORD|$escaped_pwd|g" "$CONFIG_FILE" || true

  encodedHy2Pwd=$(node -e "console.log(encodeURIComponent(process.argv[1]))" "$HY2_PASSWORD")
  hy2Url="hysteria2://${encodedHy2Pwd}@${IP}:${PORT}?insecure=1#hy2"
  printf '%s\n' "$hy2Url" > "$NODE_TXT"

  if [ -n "$NEZHA_SERVER" ] && [ -n "$NEZHA_KEY" ]; then
    echo "[NEZHA] Installing Nezha Agent..."
    mkdir -p "$NZ_DIR"
    cd "$NZ_DIR"
    if [ ! -x "${NZ_DIR}/nz" ]; then
      curl -sSL -o nezha-agent.zip "$NEZHA_AGENT_URL" || { echo "[NEZHA] Failed to download nezha agent"; cd - >/dev/null 2>&1 || true; }
      if [ -f nezha-agent.zip ]; then
        unzip -o nezha-agent.zip >/dev/null 2>&1 || true
        rm -f nezha-agent.zip
      fi
      if [ -f nezha-agent ]; then
        mv nezha-agent nz || true
        chmod 700 nz || true
      fi
    else
      echo "[NEZHA] Nezha agent already present, skipping download."
    fi
    cat > "${NZ_DIR}/config.yaml" <<EOF
server: $NEZHA_SERVER
client_secret: $NEZHA_KEY
tls: ${NZ_TLS:-true}
EOF
    echo "[NEZHA] Nezha Agent installed/configured."
    cd - >/dev/null 2>&1 || true
  else
    echo "[NEZHA] Nezha installation skipped (missing server or key)."
  fi

  touch "$INSTALL_MARKER"
  echo "First-time install complete."
fi

echo "============================================================"
echo "🚀 HY2 Node Info"
echo "------------------------------------------------------------"
if [ -f "$NODE_TXT" ]; then
  cat "$NODE_TXT"
else
  echo "hysteria2://<password>@${IP}:${PORT}?insecure=1#hy2"
fi
echo "============================================================"

if [ -x "${NZ_DIR}/nz" ] && ! pgrep -f "${NZ_DIR}/nz" >/dev/null 2>&1; then
  echo "[NEZHA] Starting Nezha agent..."
  "${NZ_DIR}/nz" -c "${NZ_DIR}/config.yaml" >/dev/null 2>&1 &
fi

if [ -x "$H2_BIN" ]; then
  echo "Starting hysteria (server mode)..."
  exec "$H2_BIN" server -c "$CONFIG_FILE"
else
  echo "Hysteria binary not found or not executable: $H2_BIN"
  exit 1
fi
