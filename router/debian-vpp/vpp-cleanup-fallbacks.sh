#!/bin/sh
set -eu
# Remove Digi SNAT hairpin leftovers when Infrawire GRE is primary.
# Safe to re-run. Does not bounce Digi/PPPoE/VPP.
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"

rm -f /run/vpp-prefer-digi-snat

# Linux iptables from digi-snat-fallback.sh
iptables -t nat -D POSTROUTING -s 79.172.242.0/24 -o ppp0 -j MASQUERADE 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 10.254.254.0/30 -o ppp0 -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i vpp-gre-fw -o ppp0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i ppp0 -o vpp-gre-fw -j ACCEPT 2>/dev/null || true
iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1452 2>/dev/null || true

# Drop Digi hairpin default if present
$VPP ip route del 0.0.0.0/0 via 10.254.254.2 tap50 2>/dev/null || true
$VPP ip route del 0.0.0.0/0 table 81 via 10.254.254.2 tap50 2>/dev/null || true

# Delete tap50 / vpp-gre-fw if present
if $VPP show interface 2>/dev/null | grep -q '^tap50[[:space:]]'; then
  $VPP set interface state tap50 down 2>/dev/null || true
  $VPP delete tap tap50 2>/dev/null || true
fi
ip link del vpp-gre-fw 2>/dev/null || true

# Legacy linux PPPoE unit (native mode uses vpp-pppoe-native)
systemctl disable --now pppoe-vpp.service 2>/dev/null || true
systemctl reset-failed pppoe-vpp.service 2>/dev/null || true
systemctl mask pppoe-vpp.service 2>/dev/null || true

# Keep Infrawire return path
$VPP ip route del 79.172.242.0/24 2>/dev/null || true
$VPP ip route add 79.172.242.0/24 via loop10 2>/dev/null || true

echo "cleanup-fallbacks: tap50/gre-fw/iptables Digi hairpin removed"
