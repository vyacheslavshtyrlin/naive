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
apt-get install -y -qq curl wget git dnsutils

echo "==> Installing Go..."
GO_VERSION="1.23.4"
if ! command -v go &>/dev/null || [[ "$(go version | awk '{print $3}' | tr -d 'go')" < "1.21" ]]; then
    wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
    ln -sf /usr/local/go/bin/go /usr/local/bin/go
fi
export PATH="$PATH:/usr/local/go/bin:/root/go/bin"

echo "==> Building Caddy with naive forwardproxy..."
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
~/go/bin/xcaddy build \
    --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive \
    --output /usr/local/bin/caddy

chmod +x /usr/local/bin/caddy

echo "==> Creating caddy user..."
if ! id caddy &>/dev/null; then
    useradd --system --home /var/lib/caddy --shell /sbin/nologin caddy
fi
mkdir -p /var/lib/caddy /etc/caddy /var/log/caddy
chown -R caddy:caddy /var/lib/caddy /var/log/caddy

echo "==> Writing Caddyfile..."
cat > /etc/caddy/Caddyfile <<EOF
{
    admin off
    log {
        output discard
    }
}

${DOMAIN}:443 {
    route {
        forward_proxy {
            basic_auth ${USER} ${PASS}
            hide_ip
            hide_via
            probe_resistance
        }
        reverse_proxy ${FALLBACK} {
            header_up Host {upstream_hostport}
        }
    }
}
EOF

chown caddy:caddy /etc/caddy/Caddyfile
chmod 640 /etc/caddy/Caddyfile

echo "==> Writing systemd unit..."
cat > /etc/systemd/system/caddy.service <<'UNIT'
[Unit]
Description=Caddy web server
After=network-online.target
Wants=network-online.target

[Service]
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=strict
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ReadWritePaths=/var/lib/caddy /var/log/caddy /etc/caddy

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
if /usr/local/bin/caddy list-certificates 2>&1 | grep -q "$DOMAIN"; then
    echo "OK: Certificate obtained for $DOMAIN"
else
    echo "WARNING: Certificate not yet visible. Check: journalctl -u caddy -f"
fi

echo ""
echo "==> Installation complete."
echo "    Test: curl -I https://$DOMAIN"
echo "    Test proxy: curl -v --proxy-user $USER:$PASS --proxytunnel -x https://$DOMAIN https://ifconfig.me"
