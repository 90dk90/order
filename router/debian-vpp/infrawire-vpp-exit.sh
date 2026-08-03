#!/bin/sh
set -eu
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"

# Digi PD can change across PPPoE sessions. Always follow the live PD env.
if [ -r /run/vpp-tap30-ipv6.env ]; then
  # shellcheck disable=SC1091
  . /run/vpp-tap30-ipv6.env
fi

SRC_VTEP="${VXLAN_LOCAL_IP6:-2a01:4700:8080:6400::2}"
UNDERLAY_GW="${VXLAN_UNDERLAY_GW:-2a01:4700:8080:6400::1}"
DST_VTEP=2a10:4646:500::1
UNDERLAY_IF=tap30
LOCAL_IP=172.16.206.2/30
PEER_IP=172.16.206.1
HOST_IF=vpp-gre-infra
PBR_TABLE=81
PBR_SOURCE=79.172.242.0

# Static ND for Linux peer on tap30 (required after tap recreate)
HOST_MAC=$(cat /sys/class/net/vpp6-host/address 2>/dev/null || true)
if [ -n "$HOST_MAC" ]; then
  $VPP set ip neighbor tap30 "$UNDERLAY_GW" "$HOST_MAC" static >/dev/null 2>&1 || true
fi

# Underlay route to Infrawire VTEP
$VPP ip route del "$DST_VTEP/128" 2>/dev/null || true
$VPP ip route add "$DST_VTEP/128" via "$UNDERLAY_GW" "$UNDERLAY_IF" resolve-via-host

# Recreate GRE when missing or when Digi PD (src) changed
NEED_GRE=1
CUR="$($VPP show gre tunnel 2>/dev/null | head -1 || true)"
if [ -n "$CUR" ]; then
  CSRC=$(printf '%s\n' "$CUR" | sed -n 's/.* src \([^ ]*\) dst .*/\1/p')
  CDST=$(printf '%s\n' "$CUR" | sed -n 's/.* dst \([^ ]*\) fib-idx .*/\1/p')
  if [ "$CSRC" = "$SRC_VTEP" ] && [ "$CDST" = "$DST_VTEP" ]; then
    NEED_GRE=0
  else
    CINST=$(printf '%s\n' "$CUR" | sed -n 's/.*instance \([0-9]*\) .*/\1/p')
    $VPP create gre tunnel src "$CSRC" dst "$CDST" instance "${CINST:-0}" del 2>/dev/null || true
  fi
fi
if [ "$NEED_GRE" -eq 1 ]; then
  $VPP create gre tunnel src "$SRC_VTEP" dst "$DST_VTEP" instance 0
fi

$VPP set interface state gre0 up
$VPP set interface mtu packet 1448 gre0
$VPP set interface ip address del gre0 all || true
$VPP set interface ip address gre0 "$LOCAL_IP"

# LCP tun for BIRD (tap-type LCP fails on GRE with -73)
if ! $VPP show lcp 2>/dev/null | grep -q "[[:space:]]$HOST_IF\\>"; then
  $VPP lcp create gre0 host-if "$HOST_IF" tun >/dev/null 2>&1 || true
fi

# Defaults via GRE (no Linux hairpin)
$VPP ip table add "$PBR_TABLE" 2>/dev/null || true
$VPP ip route del 0.0.0.0/0 table "$PBR_TABLE" 2>/dev/null || true
$VPP ip route add 0.0.0.0/0 table "$PBR_TABLE" via "$PEER_IP" gre0
$VPP ip route del 0.0.0.0/0 2>/dev/null || true
$VPP ip route del 0.0.0.0/0 via 10.254.254.2 tap50 2>/dev/null || true
$VPP ip route del 0.0.0.0/0 via 10.81.81.1 loop11 2>/dev/null || true
$VPP ip route add 0.0.0.0/0 via "$PEER_IP" gre0

# Remove stale L3XC to dead loop11 (old VXLAN2 path)
for iface in loop10 x520lan x520extra0 x520extra1; do
  $VPP l3xc del "$iface" via 10.81.81.1 loop11 2>/dev/null || true
done

# Keep client LAN on-link inside PBR table 81
$VPP ip route del 79.172.242.0/24 table "$PBR_TABLE" 2>/dev/null || true
$VPP ip route add 79.172.242.0/24 table "$PBR_TABLE" via loop10
$VPP ip route del 79.172.242.1/32 table "$PBR_TABLE" 2>/dev/null || true
$VPP ip route add 79.172.242.1/32 table "$PBR_TABLE" via local

# Client src PBR classify DISABLED:
# fib0 default already exits via Infrawire gre0. Old l2 classify blackholed returns.
IDX=""
if [ -r /run/vpp-vxlan2-pbr-classify-index ]; then
  IDX=$(cat /run/vpp-vxlan2-pbr-classify-index)
fi
if [ -n "$IDX" ]; then
  $VPP classify session del table-index "$IDX" match l3 ip4 src "$PBR_SOURCE" >/dev/null 2>&1 || true
fi
