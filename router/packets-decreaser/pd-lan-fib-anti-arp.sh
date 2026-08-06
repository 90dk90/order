#!/bin/sh
# LAN model for 79.172.242.0/24: no connected /24 glean, no per-DIP /32.
# One static neighbor (PVE) + cover route: whole /24 via 79.172.242.2.
set -eu
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
MAC="${LAN_HOST_MAC:-c4:62:37:0d:2f:96}"
PVE="${LAN_PVE_IP:-79.172.242.2}"
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
$VPP set ip neighbor loop10 "$PVE" "$MAC" static 2>/dev/null || true
$VPP ip route add table 81 79.172.242.0/24 via "$PVE" loop10 2>/dev/null || true
$VPP ip route add table 0 79.172.242.0/24 via ip4-lookup-in-table 81 2>/dev/null || true
$VPP ip route add table 0 79.172.242.1/32 via ip4-lookup-in-table 81 2>/dev/null || true
