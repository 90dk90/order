#!/bin/sh
set -eu
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
PD_VTEP=2a0e:97c0:4c1::60
INNER_LOCAL=172.16.207.2/30
INNER_PEER=172.16.207.1

# Discover Digi WAN IPv6
SRC=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  SRC=$($VPP show interface addr digi 2>/dev/null | awk '/L3 2a01:/{print $2}' | head -1 | cut -d/ -f1 || true)
  [ -n "$SRC" ] && break
  sleep 2
done
[ -n "$SRC" ] || { echo "no digi ipv6"; exit 1; }
printf '%s\n' "$SRC" > /run/infrawire-vtep.txt
printf 'SRC_VTEP=%s\nDST_VTEP=%s\n' "$SRC" "$PD_VTEP" > /run/pd-gre-endpoint.env

$VPP ip table add 81 2>/dev/null || true
$VPP ip route del "$PD_VTEP/128" 2>/dev/null || true
$VPP ip route add "$PD_VTEP/128" via fe80::1 digi 2>/dev/null || true
$VPP ip route del ::/0 2>/dev/null || true
$VPP ip route add ::/0 via fe80::1 digi 2>/dev/null || true

# Recreate GRE if needed
if ! $VPP show gre tunnel 2>/dev/null | grep -q "$PD_VTEP"; then
  $VPP create gre tunnel src "$SRC" dst "$PD_VTEP" instance 0 2>/dev/null || \
    $VPP create gre tunnel src "$SRC" dst "$PD_VTEP" 2>/dev/null || true
fi
$VPP set interface state gre0 up 2>/dev/null || true
$VPP set interface ip address del gre0 172.16.207.2/30 2>/dev/null || true
$VPP set interface ip address gre0 "$INNER_LOCAL" 2>/dev/null || true

# loop10 table 81
$VPP set interface ip address del loop10 79.172.242.1/24 2>/dev/null || true
$VPP set interface ip table loop10 81 2>/dev/null || true
$VPP set interface ip address loop10 79.172.242.1/24 2>/dev/null || true
$VPP set interface state loop10 up 2>/dev/null || true

$VPP ip route del table 81 0.0.0.0/0 2>/dev/null || true
$VPP ip route add table 81 0.0.0.0/0 via "$INNER_PEER" gre0 2>/dev/null || true
$VPP ip route del 79.172.242.0/24 2>/dev/null || true
$VPP ip route add 79.172.242.0/24 via loop10 2>/dev/null || true
$VPP ip route del 79.172.242.2/32 2>/dev/null || true
$VPP ip route add 79.172.242.2/32 via 79.172.242.2 loop10 2>/dev/null || true

# Keep Infrawire BGP down
birdc disable ebgp_as210699 >/dev/null 2>&1 || true
echo "pd-gre ready src=$SRC"
