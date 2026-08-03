#!/bin/sh
set -eu
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"

MODE=linux
if [ -r /etc/default/vpp-pppoe-mode ]; then
  # shellcheck disable=SC1091
  . /etc/default/vpp-pppoe-mode
  MODE="${VPP_PPPOE_MODE:-linux}"
fi

DST_VTEP=2a10:4646:500::1
LOCAL_IP=172.16.206.2/30
PEER_IP=172.16.206.1
HOST_IF=vpp-gre-infra
PBR_TABLE=81
PBR_SOURCE=79.172.242.0

# Prefer live Digi WAN IPv6 observed by pppoeclient (native mode).
SRC_VTEP=""
UNDERLAY_GW=""
UNDERLAY_IF=""
if [ "$MODE" = "native" ]; then
  DETAIL=$($VPP show pppoe client detail 2>/dev/null || true)
  OBS=$(printf '%s\n' "$DETAIL" | sed -n 's/.*wan-ipv6 observed \([^ ]*\).*/\1/p' | tr -d '\r' | head -1)
  case "$OBS" in
    */*)
      SRC_VTEP=${OBS%/*}
      UNDERLAY_IF=digi
      UNDERLAY_GW=fe80::1
      ;;
  esac
fi

# Fallback: classic tap30 PD env (linux softpath / delegated /56)
if [ -z "$SRC_VTEP" ] && [ -r /run/vpp-tap30-ipv6.env ]; then
  # shellcheck disable=SC1091
  . /run/vpp-tap30-ipv6.env
  SRC_VTEP="${VXLAN_LOCAL_IP6:-}"
  UNDERLAY_GW="${VXLAN_UNDERLAY_GW:-}"
  UNDERLAY_IF=tap30
fi

SRC_VTEP="${SRC_VTEP:-2a01:4700:8080:6400::2}"
UNDERLAY_GW="${UNDERLAY_GW:-2a01:4700:8080:6400::1}"
UNDERLAY_IF="${UNDERLAY_IF:-tap30}"

umask 022
printf '%s\n' "$SRC_VTEP" > /run/infrawire-vtep.txt
printf 'SRC_VTEP=%s\nDST_VTEP=%s\nUNDERLAY_GW=%s\nUNDERLAY_IF=%s\nGRE_LOCAL=%s\nGRE_PEER=%s\n' \
  "$SRC_VTEP" "$DST_VTEP" "$UNDERLAY_GW" "$UNDERLAY_IF" "$LOCAL_IP" "$PEER_IP" \
  > /run/infrawire-endpoint.env

# Keep env file consumable by older helpers
printf 'VXLAN_LOCAL_IP6=%s\nVPP_UNDERLAY_PREFIX=\nVXLAN_UNDERLAY_PREFIX=\nVXLAN_UNDERLAY_GW=%s\n' \
  "$SRC_VTEP" "$UNDERLAY_GW" > /run/vpp-tap30-ipv6.env

if [ "$UNDERLAY_IF" = "tap30" ]; then
  HOST_MAC=$(cat /sys/class/net/vpp6-host/address 2>/dev/null || true)
  if [ -n "$HOST_MAC" ]; then
    $VPP set ip neighbor tap30 "$UNDERLAY_GW" "$HOST_MAC" static >/dev/null 2>&1 || true
  fi
fi

# Underlay route to Infrawire VTEP
$VPP ip route del "$DST_VTEP/128" 2>/dev/null || true
if [ "$UNDERLAY_IF" = "digi" ]; then
  $VPP ip route add "$DST_VTEP/128" via "$UNDERLAY_GW" "$UNDERLAY_IF"
else
  $VPP ip route add "$DST_VTEP/128" via "$UNDERLAY_GW" "$UNDERLAY_IF" resolve-via-host
fi

# Recreate GRE when missing or when Digi endpoint (src) changed
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
# Never leave gre0 unnumbered to digi (steals Digi CGNAT/WAN addrs onto GRE)
$VPP set interface unnumbered del gre0 2>/dev/null || true
$VPP set interface ip address del gre0 all || true
$VPP set interface ip address gre0 "$LOCAL_IP"

if ! $VPP show lcp 2>/dev/null | grep -q "[[:space:]]$HOST_IF\\>"; then
  $VPP lcp create gre0 host-if "$HOST_IF" tun >/dev/null 2>&1 || true
fi

$VPP ip table add "$PBR_TABLE" 2>/dev/null || true

# Client LAN lives in table 81 so Digi pppoeclient default (fib0) cannot steal egress
LOOP_ADDR=$($VPP show interface address loop10 2>/dev/null | sed -n 's/.*L3 \([0-9.][0-9.]*\/[0-9]*\).*/\1/p' | head -1)
LOOP_ADDR=${LOOP_ADDR:-79.172.242.1/24}
$VPP set interface ip address del loop10 all 2>/dev/null || true
$VPP set interface ip table loop10 "$PBR_TABLE" 2>/dev/null || true
$VPP set interface ip address loop10 "$LOOP_ADDR" 2>/dev/null || true
$VPP set interface state loop10 up 2>/dev/null || true

$VPP ip route del 79.172.242.0/24 table "$PBR_TABLE" 2>/dev/null || true
$VPP ip route add 79.172.242.0/24 table "$PBR_TABLE" via loop10
$VPP ip route del 79.172.242.1/32 table "$PBR_TABLE" 2>/dev/null || true
$VPP ip route add 79.172.242.1/32 table "$PBR_TABLE" via local
# Return path: gre0 is in fib0 — must reach LAN even though loop10 lives in table 81
$VPP ip route del 79.172.242.0/24 2>/dev/null || true
$VPP ip route add 79.172.242.0/24 via loop10
# More-specific host routes beat stale LCP drop on the /24
$VPP ip route del 79.172.242.2/32 2>/dev/null || true
$VPP ip route add 79.172.242.2/32 via 79.172.242.2 loop10
# Gateway .1 must be received in table 81 (replies use gre0 default, not Digi)
$VPP ip route del 79.172.242.1/32 2>/dev/null || true
$VPP ip route add 79.172.242.1/32 via ip4-lookup-in-table "$PBR_TABLE"

for iface in loop10 x520lan x520extra0 x520extra1; do
  $VPP l3xc del "$iface" via 10.81.81.1 loop11 2>/dev/null || true
done

if [ -e /run/vpp-prefer-digi-snat ]; then
  :
else
  # Digi SNAT must stay off while Infrawire is primary (public /24 via GRE)
  $VPP set interface nat44 in loop10 out digi del 2>/dev/null || true
  $VPP set interface nat44 in x520lan out digi del 2>/dev/null || true
  $VPP set interface nat44 in loop10 out digi output-feature del 2>/dev/null || true
  $VPP set interface nat44 in x520lan out digi output-feature del 2>/dev/null || true
  DIGI_IP4=$($VPP show interface address digi 2>/dev/null | sed -n 's/.*L3 \([0-9.][0-9.]*\)\/32.*/\1/p' | head -1)
  if [ -n "$DIGI_IP4" ]; then
    $VPP nat44 add address "$DIGI_IP4" del 2>/dev/null || true
  fi
  $VPP clear nat44 ed sessions 2>/dev/null || true
  $VPP nat44 plugin disable 2>/dev/null || true

  # Interface-route default: avoid unresolved via 172.16.206.1 (LCP /32 peer traps)
  $VPP ip route del 0.0.0.0/0 table "$PBR_TABLE" 2>/dev/null || true
  $VPP ip route del 0.0.0.0/0 table "$PBR_TABLE" via "$PEER_IP" gre0 2>/dev/null || true
  $VPP ip route add 0.0.0.0/0 table "$PBR_TABLE" via gre0
  $VPP ip route del 0.0.0.0/0 2>/dev/null || true
  $VPP ip route del 0.0.0.0/0 via 10.254.254.2 tap50 2>/dev/null || true
  $VPP ip route del 0.0.0.0/0 via 10.81.81.1 loop11 2>/dev/null || true
  $VPP ip route del 0.0.0.0/0 via "$PEER_IP" gre0 2>/dev/null || true
  $VPP ip route add 0.0.0.0/0 via gre0 2>/dev/null || true
fi

IDX=""
if [ -r /run/vpp-vxlan2-pbr-classify-index ]; then
  IDX=$(cat /run/vpp-vxlan2-pbr-classify-index)
fi
if [ -n "$IDX" ]; then
  $VPP classify session del table-index "$IDX" match l3 ip4 src "$PBR_SOURCE" >/dev/null 2>&1 || true
fi
