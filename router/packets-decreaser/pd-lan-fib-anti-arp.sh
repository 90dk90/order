#!/bin/sh
# Anti-ARP-storm LAN model for 79.172.242.0/24 (no connected /24 glean).
set -eu
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
MAC="${LAN_HOST_MAC:-c4:62:37:0d:2f:96}"
$VPP show version >/dev/null
$VPP set interface ip address del loop10 all 2>/dev/null || true
$VPP ip table add 81 2>/dev/null || true
$VPP set interface ip table loop10 81 2>/dev/null || true
$VPP set interface ip address loop10 79.172.242.1/32 2>/dev/null || true
for t in 0 81 82 83; do
  $VPP ip route del table $t 79.172.242.0/24 via loop10 2>/dev/null || true
  $VPP ip route del table $t 79.172.242.0/24 2>/dev/null || true
done
$VPP ip route del 79.172.242.0/24 via loop10 2>/dev/null || true
for h in 2 3 10 48; do
  $VPP set ip neighbor loop10 79.172.242.$h "$MAC" static 2>/dev/null || true
  $VPP ip route add table 81 79.172.242.$h/32 via 79.172.242.$h loop10 2>/dev/null || true
  $VPP ip route add table 0 79.172.242.$h/32 via ip4-lookup-in-table 81 2>/dev/null || true
done
$VPP ip route add table 81 79.172.242.0/24 via drop 2>/dev/null || true
$VPP ip route add table 0 79.172.242.0/24 via ip4-lookup-in-table 81 2>/dev/null || true
$VPP ip route add table 0 79.172.242.1/32 via ip4-lookup-in-table 81 2>/dev/null || true
