#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ ! -f "$ROOT_DIR/.env" ]]; then
    echo "ERROR: .env not found. Copy .env.example to .env and fill in the values."
    exit 1
fi

source "$ROOT_DIR/.env"

: "${DOMAIN:?DOMAIN is required}"
: "${EMAIL:?EMAIL is required}"
: "${USER:?USER is required}"
: "${PASS:?PASS is required}"
: "${FALLBACK:?FALLBACK is required}"
: "${SSH_PORT:=22}"

echo "==> Checking domain resolution..."
RESOLVED_IP=$(dig +short "$DOMAIN" | tail -1)
SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org || true)

if [[ -z "$RESOLVED_IP" ]]; then
    echo "ERROR: $DOMAIN does not resolve. Set A record to this server's IP before running."
    exit 1
fi

if [[ -n "$SERVER_IP" && "$RESOLVED_IP" != "$SERVER_IP" ]]; then
    echo "WARNING: $DOMAIN resolves to $RESOLVED_IP but server IP is $SERVER_IP"
    echo "TLS certificate may fail. Continue? [y/N]"
    read -r answer
    [[ "$answer" == "y" || "$answer" == "Y" ]] || exit 1
fi

echo "==> Installing dependencies..."
apt-get update -qq
apt-get install -y -qq curl wget git dnsutils openssl

echo "==> Configuring SSH port $SSH_PORT..."
if ! grep -q "^Port $SSH_PORT" /etc/ssh/sshd_config; then
    sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
    grep -q "^Port" /etc/ssh/sshd_config || echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
    systemctl restart sshd
fi

echo "==> Installing Go 1.22.0..."
GO_VERSION="1.22.0"
if ! command -v go &>/dev/null || [[ "$(go version | awk '{print $3}' | tr -d 'go')" != "1.22.0" ]]; then
    wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
fi
export PATH="/usr/local/go/bin:/root/go/bin:$PATH"

echo "==> Building Caddy with naive forwardproxy..."
mkdir -p /root/tmp
export TMPDIR=/root/tmp
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
~/go/bin/xcaddy build \
    --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive \
    --output /usr/bin/caddy

chmod +x /usr/bin/caddy

echo "==> Writing Caddyfile..."
mkdir -p /etc/caddy
cat > /etc/caddy/Caddyfile <<EOF
:443, ${DOMAIN}
tls ${EMAIL}

route {
  forward_proxy {
    basic_auth ${USER} ${PASS}
    hide_ip
    hide_via
    probe_resistance
  }
  reverse_proxy ${FALLBACK} {
    header_up Host {upstream_hostport}
    header_up X-Forwarded-Host {host}
  }
}
EOF

echo "==> Writing systemd unit..."
cat > /etc/systemd/system/caddy.service <<'UNIT'
[Unit]
Description=Caddy with NaiveProxy
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

echo "==> Applying sysctl settings..."
bash "$SCRIPT_DIR/harden.sh"

echo "==> Configuring firewall..."
bash "$SCRIPT_DIR/firewall.sh"

echo "==> Enabling and starting Caddy..."
systemctl daemon-reload
systemctl enable --now caddy

echo "==> Waiting for TLS certificate..."
sleep 10
if /usr/bin/caddy list-certificates 2>&1 | grep -q "$DOMAIN"; then
    echo "OK: Certificate obtained for $DOMAIN"
else
    echo "WARNING: Certificate not yet visible. Check: journalctl -u caddy -f"
fi

echo ""
echo "==> Installation complete."
echo "    Test: curl -I https://$DOMAIN"
echo "    Proxy URI: naive://${USER}:${PASS}@${DOMAIN}:443"
