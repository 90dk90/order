#!/bin/sh
# Restore classic Digi path: BD20 bridge x520wan<->tap20 + Linux pppd
set -eu
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"

rm -f /etc/default/vpp-pppoe-native
echo 'VPP_PPPOE_MODE=linux' > /etc/default/vpp-pppoe-mode

# Stop native helpers if any
systemctl stop vpp-pppoe-native.service 2>/dev/null || true
systemctl disable vpp-pppoe-native.service 2>/dev/null || true

# Delete native client if present
$VPP create pppoe client x520wan host-uniq 1 del 2>/dev/null || true
$VPP create pppoe client x520wan del 2>/dev/null || true

systemctl enable pppoe-vpp.service
systemctl restart vpp.service
# reconcile pulls bootstrap + pppoe + vxlan + gre
sleep 5
systemctl start vpp-stack-reconcile.service || true
echo "rollback: linux pppd path requested via vpp restart"
