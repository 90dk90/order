#!/bin/sh
# Digi: parallel VXLAN lab next to production GRE (gre0 untouched).
# Requires vxlan_plugin.so enabled in /etc/vpp/startup.conf (+ VPP restart once).
set -eu
CONF="${1:-/etc/pd/pd-vxlan-lab.conf}"
[ -f "$CONF" ] || CONF="$(dirname "$0")/pd-vxlan-lab.conf"
# shellcheck disable=SC1090
. "$CONF"
. /etc/pd/pd-gre.conf 2>/dev/null || true

VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
$VPP show version >/dev/null

if ! $VPP help create 2>/dev/null | grep -q 'vxlan tunnel'; then
  if ! $VPP create vxlan tunnel 2>&1 | grep -qi 'src'; then
    echo "pd-vxlan-lab-digi: vxlan plugin not loaded — enable vxlan_plugin.so and restart VPP" >&2
    exit 1
  fi
fi

# Live Digi VTEP (same picker idea as GRE)
SRC=$($VPP show pppoe client detail 2>/dev/null | sed -n 's/.*wan-ipv6 observed \([^ /]*\).*/\1/p' | tr -d '\r' | head -1)
SRC=${SRC%%/*}
if [ -z "$SRC" ] || [ "$SRC" = "<none>" ]; then
  SRC=$($VPP show interface addr digi 2>/dev/null | awk '/L3 2a01:4700:/{gsub(/\/.*/,"",$2); print $2; exit}')
fi
[ -n "$SRC" ] || { echo "pd-vxlan-lab-digi: no Digi WAN IPv6" >&2; exit 1; }
DST="${PD_VTEP}"

echo "pd-vxlan-lab-digi: outer $SRC -> $DST vni $VXLAN_VNI"

$VPP create bridge-domain "$LAB_BD" 2>/dev/null || true

# Loop BVI
if ! $VPP show interface 2>/dev/null | awk -v n="$LAB_LOOP" '$1==n{found=1} END{exit !found}'; then
  # instance = BD id for readability
  $VPP create loopback interface instance "$LAB_BD" 2>/dev/null || true
fi
$VPP set interface mac address "$LAB_LOOP" "$LAB_DIGI_MAC" 2>/dev/null || true
$VPP set interface l2 bridge "$LAB_LOOP" "$LAB_BD" bvi 2>/dev/null || true
$VPP set interface state "$LAB_LOOP" up 2>/dev/null || true
if ! $VPP show interface addr "$LAB_LOOP" 2>/dev/null | grep -q "$LAB_DIGI/30"; then
  $VPP set interface ip address "$LAB_LOOP" "$LAB_DIGI/30" 2>/dev/null || true
fi

# VXLAN L2 (interop with Linux classic VXLAN — NOT gpe/l3)
WANT="src $SRC dst $DST"
HAVE=$($VPP show vxlan tunnel 2>/dev/null | tr -d '\r' || true)
IFACE=""
IFACE=$($VPP show vxlan tunnel 2>/dev/null | awk -v v="$VXLAN_VNI" -v s="$SRC" -v d="$DST" '
  $0 ~ ("vni " v) && index($0,s) && index($0,d) {
    for (i=1;i<=NF;i++) if ($i ~ /^vxlan_tunnel/) { print $i; exit }
  }')

if [ -z "$IFACE" ]; then
  # delete stale lab instance if any
  $VPP create vxlan tunnel src "$SRC" dst "$DST" vni "$VXLAN_VNI" instance "$LAB_VXLAN_INSTANCE" del 2>/dev/null || true
  OUT=$($VPP create vxlan tunnel src "$SRC" dst "$DST" vni "$VXLAN_VNI" instance "$LAB_VXLAN_INSTANCE" dst_port "$VXLAN_PORT" 2>&1) || true
  echo "pd-vxlan-lab-digi: create: $OUT"
  IFACE=$($VPP show vxlan tunnel 2>/dev/null | awk -v v="$VXLAN_VNI" '
    $0 ~ ("vni " v) {
      for (i=1;i<=NF;i++) if ($i ~ /^vxlan_tunnel/) { print $i; exit }
    }')
fi
[ -n "$IFACE" ] || { echo "pd-vxlan-lab-digi: no vxlan iface" >&2; exit 1; }

$VPP set interface l2 bridge "$IFACE" "$LAB_BD" 2>/dev/null || true
$VPP set interface state "$IFACE" up 2>/dev/null || true
$VPP set interface mtu packet "$VXLAN_MTU" "$IFACE" 2>/dev/null || true
$VPP set interface mtu packet "$VXLAN_MTU" "$LAB_LOOP" 2>/dev/null || true

# Static neigh toward VPS VXLAN MAC
$VPP set ip neighbor "$LAB_LOOP" "$LAB_VPS" "$LAB_VPS_MAC" static 2>/dev/null || true

printf '%s\n' "$SRC" > /run/pd-vxlan-lab-vtep.txt
printf 'LAB_IFACE=%s\nLAB_SRC=%s\nLAB_DST=%s\n' "$IFACE" "$SRC" "$DST" > /run/pd-vxlan-lab.env

echo "pd-vxlan-lab-digi: OK iface=$IFACE bvi=$LAB_LOOP $LAB_DIGI/30 (GRE untouched)"
$VPP show vxlan tunnel 2>/dev/null | head -20
$VPP show bridge-domain "$LAB_BD" detail 2>/dev/null | head -30
$VPP ping "$LAB_VPS" repeat 3 2>&1 | tail -8 || true
