#!/bin/sh
set -eu
# Flip client default back to Infrawire GRE after they update the VTEP endpoint.
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
PEER_IP=172.16.206.1

rm -f /run/vpp-prefer-digi-snat
/usr/local/sbin/infrawire-vpp-exit.sh
/usr/local/sbin/infrawire-gre-up.sh

$VPP ip route del 0.0.0.0/0 2>/dev/null || true
$VPP ip route add 0.0.0.0/0 via "$PEER_IP" gre0
$VPP ip table add 81 2>/dev/null || true
$VPP ip route del 0.0.0.0/0 table 81 2>/dev/null || true
$VPP ip route add 0.0.0.0/0 table 81 via "$PEER_IP" gre0

systemctl restart bird.service || true
/usr/local/sbin/vpp-mss-clamp.sh || true
/usr/local/sbin/vpp-performance-tuning.sh || true

echo "gre-activate: default via gre0 - check:"
echo "  ping -c 3 $PEER_IP"
echo "  birdc show protocols"
