#!/bin/bash
# Cutover PD to Digi PPPoE underlay — VXLAN only (no GRE).
# Preconditions:
#   - Digi PPPoE up with global IPv6 on digi / wan
#   - vxlan_plugin loaded
#   - VPS reachable on PD_VTEP (IPv6)
# Does NOT re-enable GRE.
set -euo pipefail
. /etc/pd/pd-vxlan-lab.conf 2>/dev/null || . "$(dirname "$0")/pd-vxlan-lab.conf"
. /etc/pd/pd-gre.conf 2>/dev/null || true

VPP="${VPP:-/usr/bin/vppctl}"
PBR_TABLE="${PBR_TABLE:-81}"
VXLAN_VNI="${VXLAN_VNI:-100}"
VXLAN_PORT="${VXLAN_PORT:-4789}"
VXLAN_MTU="${VXLAN_MTU:-1400}"
LAB_BD="${LAB_BD:-208}"
LAB_LOOP="${LAB_LOOP:-loop208}"
LAB_DIGI="${LAB_DIGI:-172.16.208.2}"
LAB_VPS="${LAB_VPS:-172.16.208.1}"
LAB_DIGI_MAC="${LAB_DIGI_MAC:-de:ad:00:00:00:d1}"
LAB_VPS_MAC="${LAB_VPS_MAC:-de:ad:00:00:00:d2}"
LAB_VXLAN_INSTANCE="${LAB_VXLAN_INSTANCE:-208}"
DST="${PD_VTEP:-2a0e:97c0:4c1::60}"

$VPP show version >/dev/null
if ! $VPP show vxlan tunnel >/dev/null 2>&1; then
  echo "pd-vpp-digi-vxlan-cutover: vxlan_plugin not loaded" >&2
  exit 1
fi

# Resolve Digi WAN IPv6 (native PPPoE client or digi iface)
SRC=$($VPP show pppoe client detail 2>/dev/null | sed -n 's/.*wan-ipv6 observed \([^ /]*\).*/\1/p' | tr -d '\r' | head -1)
SRC=${SRC%%/*}
if [ -z "$SRC" ] || [ "$SRC" = "<none>" ]; then
  SRC=$($VPP show interface addr digi 2>/dev/null | awk '/L3 2a/{gsub(/\/.*/,"",$2); print $2; exit}')
fi
if [ -z "$SRC" ]; then
  SRC=$($VPP show interface addr 2>/dev/null | awk '/L3 2a01:4700:/{gsub(/\/.*/,"",$2); print $2; exit}')
fi
[ -n "$SRC" ] || { echo "pd-vpp-digi-vxlan-cutover: no Digi global IPv6 yet" >&2; exit 1; }

echo "pd-vpp-digi-vxlan-cutover: Digi VTEP $SRC -> $DST vni $VXLAN_VNI (VXLAN only, no GRE)"

# Tear Proximus interim underlay pieces (keep enp36s0 Linux for Tailscale)
$VPP ip route del table "$PBR_TABLE" 0.0.0.0/0 via "$LAB_VPS" "$LAB_LOOP" 2>/dev/null || true
IFACE_OLD="vxlan_tunnel${LAB_VXLAN_INSTANCE}"
$VPP create vxlan tunnel src 10.255.36.1 dst 77.90.4.48 vni "$VXLAN_VNI" instance "$LAB_VXLAN_INSTANCE" del 2>/dev/null || true
$VPP delete tap id "${PROX_TAP_ID:-36}" 2>/dev/null || true
ip link del "${PROX_TAP_HOST_IF:-vpp-prox}" 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 10.255.36.1/32 -o enp36s0 -j SNAT --to-source 192.168.129.8 2>/dev/null || true
iptables -t nat -D PREROUTING -i enp36s0 -p udp --dport "$VXLAN_PORT" -j DNAT --to-destination 10.255.36.1 2>/dev/null || true

# Ensure BD + BVI
$VPP create bridge-domain "$LAB_BD" 2>/dev/null || true
if ! $VPP show interface 2>/dev/null | awk -v n="$LAB_LOOP" '$1==n{f=1} END{exit !f}'; then
  $VPP create loopback interface instance "$LAB_BD" 2>/dev/null || true
fi
$VPP set interface mac address "$LAB_LOOP" "$LAB_DIGI_MAC" 2>/dev/null || true
$VPP set interface l2 bridge "$LAB_LOOP" "$LAB_BD" bvi 2>/dev/null || true
$VPP set interface state "$LAB_LOOP" up
if ! $VPP show interface addr "$LAB_LOOP" 2>/dev/null | grep -q "${LAB_DIGI}/30"; then
  $VPP set interface ip address "$LAB_LOOP" "${LAB_DIGI}/30" 2>/dev/null || true
fi

OUT=$($VPP create vxlan tunnel src "$SRC" dst "$DST" vni "$VXLAN_VNI" instance "$LAB_VXLAN_INSTANCE" dst_port "$VXLAN_PORT" 2>&1) || true
echo "pd-vpp-digi-vxlan-cutover: create: $OUT"
IFACE="vxlan_tunnel${LAB_VXLAN_INSTANCE}"
$VPP set interface l2 bridge "$IFACE" "$LAB_BD" 2>/dev/null || true
$VPP set interface state "$IFACE" up
$VPP set interface mtu packet "$VXLAN_MTU" "$IFACE" 2>/dev/null || true
$VPP set interface mtu packet "$VXLAN_MTU" "$LAB_LOOP" 2>/dev/null || true
$VPP set ip neighbor "$LAB_LOOP" "$LAB_VPS" "$LAB_VPS_MAC" static 2>/dev/null || true
$VPP ip route add table "$PBR_TABLE" 0.0.0.0/0 via "$LAB_VPS" "$LAB_LOOP"

/usr/local/sbin/pd-vpp-vxlan-mss.sh 2>/dev/null || true

# Mode flags — VXLAN only forever
cat >/etc/default/pd-underlay <<EOF
# Digi VXLAN-only PD (GRE retired).
PD_UNDERLAY=digi-vxlan
PD_TRANSPORT=vxlan
PD_GRE=0
PD_PPPOE=1
DIGI_VTEP=$SRC
EOF

printf '%s\n' "$SRC" > /run/pd-vxlan-digi-vtep.txt
echo "pd-vpp-digi-vxlan-cutover: OK — update VPS: DIGI_VTEP=$SRC /usr/local/sbin/pd-vpp-digi-vxlan-vps.sh"
$VPP show vxlan tunnel
$VPP ping "$LAB_VPS" repeat 3 2>&1 | tail -8 || true
