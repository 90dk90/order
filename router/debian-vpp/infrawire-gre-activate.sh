#!/bin/sh
set -eu
# Flip client default back to Infrawire GRE after they update the VTEP endpoint.
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
PEER_IP=172.16.206.1

rm -f /run/vpp-prefer-digi-snat
/usr/local/sbin/infrawire-vpp-exit.sh
/usr/local/sbin/infrawire-gre-up.sh

# Ensure Digi CGNAT SNAT is fully off (public /24 egress via GRE)
$VPP set interface nat44 in loop10 out digi del 2>/dev/null || true
$VPP set interface nat44 in x520lan out digi del 2>/dev/null || true
$VPP set interface nat44 in loop10 out digi output-feature del 2>/dev/null || true
$VPP set interface nat44 in x520lan out digi output-feature del 2>/dev/null || true
for a in $($VPP show nat44 addresses 2>/dev/null | sed -n 's/^\([0-9.][0-9.]*\)$/\1/p'); do
  $VPP nat44 add address "$a" del 2>/dev/null || true
done
$VPP clear nat44 ed sessions 2>/dev/null || true
$VPP nat44 plugin disable 2>/dev/null || true

$VPP ip route del 0.0.0.0/0 2>/dev/null || true
$VPP ip route del 0.0.0.0/0 via "$PEER_IP" gre0 2>/dev/null || true
$VPP ip route add 0.0.0.0/0 via gre0 2>/dev/null || true
$VPP ip table add 81 2>/dev/null || true
$VPP ip route del 0.0.0.0/0 table 81 2>/dev/null || true
$VPP ip route del 0.0.0.0/0 table 81 via "$PEER_IP" gre0 2>/dev/null || true
$VPP ip route add 0.0.0.0/0 table 81 via gre0

systemctl restart bird.service || true
/usr/local/sbin/vpp-mss-clamp.sh || true
/usr/local/sbin/vpp-performance-tuning.sh || true

echo "gre-activate: clients table81 default via gre0 (no Digi SNAT) - check:"
echo "  ping -c 3 $PEER_IP"
echo "  birdc show protocols ebgp_as210699"
echo "  vppctl show nat44 interfaces   # must be empty"
echo "  vppctl show interface address gre0   # 172.16.206.2/30 only"
