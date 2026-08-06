#!/bin/sh
set -eu
# Temporary Digi CGNAT exit for 79.172.242.0/24 while Infrawire GRE endpoint is stale.
# Does NOT bounce PPPoE. Safe to re-run.
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"

if ! $VPP show interface | grep -q '^tap50[[:space:]]'; then
  $VPP create tap id 50 host-if-name vpp-gre-fw host-mtu-size 1500 \
    num-rx-queues 4 num-tx-queues 4 rx-ring-size 4096 tx-ring-size 4096
fi
$VPP set interface state tap50 up
$VPP set interface ip address del tap50 all || true
$VPP set interface ip address tap50 10.254.254.1/30

FW_MAC=$(cat /sys/class/net/vpp-gre-fw/address 2>/dev/null || true)
if [ -n "$FW_MAC" ]; then
  $VPP set ip neighbor tap50 10.254.254.2 "$FW_MAC" static
fi

ip link set vpp-gre-fw up
ip addr replace 10.254.254.2/30 dev vpp-gre-fw
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.vpp-gre-fw.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.ppp0.rp_filter=0 >/dev/null 2>&1 || true

iptables -t nat -C POSTROUTING -o ppp0 -s 79.172.242.0/24 -j MASQUERADE 2>/dev/null || \
  iptables -t nat -I POSTROUTING 1 -o ppp0 -s 79.172.242.0/24 -j MASQUERADE
iptables -t nat -C POSTROUTING -o ppp0 -s 10.254.254.0/30 -j MASQUERADE 2>/dev/null || \
  iptables -t nat -I POSTROUTING 1 -o ppp0 -s 10.254.254.0/30 -j MASQUERADE
iptables -C FORWARD -i vpp-gre-fw -o ppp0 -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD 1 -i vpp-gre-fw -o ppp0 -j ACCEPT
iptables -C FORWARD -i ppp0 -o vpp-gre-fw -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD 1 -i ppp0 -o vpp-gre-fw -j ACCEPT
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1452 2>/dev/null || \
  iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1452

# Mark Digi as preferred default; exit script will not overwrite while flag exists
touch /run/vpp-prefer-digi-snat

# Default via Digi until Infrawire GRE answers
$VPP ip route del 0.0.0.0/0 2>/dev/null || true
$VPP ip route add 0.0.0.0/0 via 10.254.254.2 tap50
$VPP ip table add 81 2>/dev/null || true
$VPP ip route del 0.0.0.0/0 table 81 2>/dev/null || true
$VPP ip route add 0.0.0.0/0 table 81 via 10.254.254.2 tap50

/usr/local/sbin/vpp-performance-tuning.sh || true
echo "digi-snat-fallback: default via tap50/ppp0 (CGNAT)"
