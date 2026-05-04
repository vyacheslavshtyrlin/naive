#!/bin/bash
set -euo pipefail

echo "==> Applying sysctl hardening..."

cat > /etc/sysctl.d/99-naive.conf <<'EOF'
# TCP congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Socket buffers (16MB)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Misc hardening
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
EOF

sysctl --system -q

echo "==> Sysctl applied."
