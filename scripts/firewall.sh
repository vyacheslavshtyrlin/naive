#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$ROOT_DIR/.env" ]]; then
    source "$ROOT_DIR/.env"
fi

SSH_PORT="${SSH_PORT:-22}"

echo "==> Configuring UFW firewall..."

if ! command -v ufw &>/dev/null; then
    apt-get install -y -qq ufw
fi

ufw --force reset

# SSH (custom port)
ufw allow "$SSH_PORT"/tcp comment 'SSH'

# HTTP — required for Let's Encrypt HTTP-01 challenge
ufw allow 80/tcp comment 'HTTP (ACME challenge)'

# HTTPS — NaiveProxy traffic
ufw allow 443/tcp comment 'HTTPS (NaiveProxy)'

ufw --force enable
ufw status verbose

echo "==> Firewall configured."
