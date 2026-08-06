#!/bin/bash
# Cutover PD to Digi PPPoE underlay — VXLAN only (no GRE).
# Safety rules (VPP crash avoidance):
#   - NEVER create host-interface / af_packet on enp36s0
#   - NEVER restart VPP or PPPoE here
#   - Soft cutover: create NEW vxlan instance first, switch route, THEN delete old
#   - Keep Proximus Linux (Tailscale) untouched except NAT rules for old tap
set -euo pipefail
. /etc/pd/pd-vxlan-lab.conf 2>/dev/null || . "$(dirname "$0")/pd-vxlan-lab.conf"
. /etc/pd/pd-gre.conf 2>/dev/null || true
. /etc/default/vpp-pppoe-mode 2>/dev/null || true

# Linux pppd owns Digi GUA on ppp0 — VPP cannot source VXLAN from it.
# Use Linux VXLAN + tap30 hairpin (symmetric with VPS classic VXLAN).
if [ "${VPP_PPPOE_MODE:-}" = "linux" ] || [ "${VPP_PPPOE_MODE:-}" = "kernel" ]; then
  if [ ! -x /usr/local/sbin/pd-linux-vxlan-digi-activate.sh ] && \
     [ ! -x "$(dirname "$0")/pd-linux-vxlan-digi-activate.sh" ]; then
    echo "pd-vpp-digi-vxlan-cutover: linux PPPoE mode needs pd-linux-vxlan-digi-activate.sh" >&2
    exit 1
  fi
  echo "pd-vpp-digi-vxlan-cutover: VPP_PPPOE_MODE=linux — dispatching to Linux VXLAN activate"
  if [ -x /usr/local/sbin/pd-linux-vxlan-digi-activate.sh ]; then
    exec /usr/local/sbin/pd-linux-vxlan-digi-activate.sh
  fi
  exec "$(dirname "$0")/pd-linux-vxlan-digi-activate.sh"
fi

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
OLD_INST="${LAB_VXLAN_INSTANCE:-208}"
# New instance so we do not delete the live tunnel before the replacement exists
NEW_INST="${DIGI_VXLAN_INSTANCE:-209}"
DST="${PD_VTEP:-2a0e:97c0:4c1::60}"

$VPP show version >/dev/null
if ! $VPP show plugins 2>/dev/null | grep -q vxlan_plugin; then
  echo "pd-vpp-digi-vxlan-cutover: vxlan_plugin not loaded" >&2
  exit 1
fi

# Hard refuse af_packet misuse
if $VPP show interface 2>/dev/null | grep -qE '^host-enp36s0[[:space:]]'; then
  echo "pd-vpp-digi-vxlan-cutover: refusing — host-enp36s0 present (af_packet crash risk). delete it first." >&2
  exit 1
fi

SRC=$($VPP show pppoe client detail 2>/dev/null | sed -n 's/.*wan-ipv6 observed \([^ /]*\).*/\1/p' | tr -d '\r' | head -1)
SRC=${SRC%%/*}
if [ -z "$SRC" ] || [ "$SRC" = "<none>" ]; then
  SRC=$($VPP show interface addr digi 2>/dev/null | awk '/L3 2a/{gsub(/\/.*/,"",$2); print $2; exit}')
fi
if [ -z "$SRC" ]; then
  SRC=$($VPP show interface addr 2>/dev/null | awk '/L3 2a01:4700:/{gsub(/\/.*/,"",$2); print $2; exit}')
fi
[ -n "$SRC" ] || { echo "pd-vpp-digi-vxlan-cutover: no Digi global IPv6 yet — wait, do not force" >&2; exit 1; }

echo "pd-vpp-digi-vxlan-cutover: soft cutover Digi VTEP $SRC -> $DST (new inst $NEW_INST, keep old $OLD_INST until switched)"

# Ensure BD + BVI already exist (do not recreate if present)
$VPP create bridge-domain "$LAB_BD" 2>/dev/null || true
if ! $VPP show interface 2>/dev/null | awk -v n="$LAB_LOOP" '$1==n{f=1} END{exit !f}'; then
  $VPP create loopback interface instance "$LAB_BD" 2>/dev/null || true
  $VPP set interface mac address "$LAB_LOOP" "$LAB_DIGI_MAC" 2>/dev/null || true
  $VPP set interface l2 bridge "$LAB_LOOP" "$LAB_BD" bvi 2>/dev/null || true
  $VPP set interface state "$LAB_LOOP" up
fi
if ! $VPP show interface addr "$LAB_LOOP" 2>/dev/null | grep -q "${LAB_DIGI}/30"; then
  $VPP set interface ip address "$LAB_LOOP" "${LAB_DIGI}/30" 2>/dev/null || true
fi
$VPP set ip neighbor "$LAB_LOOP" "$LAB_VPS" "$LAB_VPS_MAC" static 2>/dev/null || true

# 1) Create NEW Digi-underlay tunnel (leave Proximus tunnel running)
NEW_IFACE="vxlan_tunnel${NEW_INST}"
if ! $VPP show interface 2>/dev/null | awk -v n="$NEW_IFACE" '$1==n{f=1} END{exit !f}'; then
  OUT=$($VPP create vxlan tunnel src "$SRC" dst "$DST" vni "$VXLAN_VNI" instance "$NEW_INST" dst_port "$VXLAN_PORT" 2>&1) || true
  echo "pd-vpp-digi-vxlan-cutover: create new: $OUT"
fi
$VPP set interface l2 bridge "$NEW_IFACE" "$LAB_BD" 2>/dev/null || true
$VPP set interface state "$NEW_IFACE" up
$VPP set interface mtu packet "$VXLAN_MTU" "$NEW_IFACE" 2>/dev/null || true
$VPP set interface mtu packet "$VXLAN_MTU" "$LAB_LOOP" 2>/dev/null || true

# 2) Point table 81 at BVI (same next-hop; both tunnels in same BD — Digi path preferred once VPS peers Digi)
$VPP ip route del table "$PBR_TABLE" 0.0.0.0/0 2>/dev/null || true
$VPP ip route add table "$PBR_TABLE" 0.0.0.0/0 via "$LAB_VPS" "$LAB_LOOP"

/usr/local/sbin/pd-vpp-vxlan-mss.sh 2>/dev/null || true

echo "pd-vpp-digi-vxlan-cutover: NEW tunnel up. Update VPS NOW, then re-run with PD_CUTOVER_TEAR_OLD=1 to drop Proximus tunnel/tap."
echo "  DIGI_VTEP=$SRC /usr/local/sbin/pd-vpp-digi-vxlan-vps.sh"

# 3) Optional tear of old Proximus path — only when explicitly requested after VPS is updated
if [ "${PD_CUTOVER_TEAR_OLD:-0}" = "1" ]; then
  echo "pd-vpp-digi-vxlan-cutover: tearing old Proximus vxlan/tap (PD_CUTOVER_TEAR_OLD=1)"
  OLD_IFACE="vxlan_tunnel${OLD_INST}"
  $VPP create vxlan tunnel src 10.255.36.1 dst 77.90.4.48 vni "$VXLAN_VNI" instance "$OLD_INST" del 2>/dev/null || true
  # Prefer leaving tap36 in place if still referenced; only delete when idle
  if ! $VPP show ip fib 2>/dev/null | grep -q tap36; then
    $VPP delete tap id "${PROX_TAP_ID:-36}" 2>/dev/null || true
    ip link del "${PROX_TAP_HOST_IF:-vpp-prox}" 2>/dev/null || true
  fi
  iptables -t nat -D POSTROUTING -s 10.255.36.1/32 -o enp36s0 -j SNAT --to-source 192.168.129.8 2>/dev/null || true
  iptables -t nat -D PREROUTING -i enp36s0 -p udp --dport "$VXLAN_PORT" -j DNAT --to-destination 10.255.36.1 2>/dev/null || true
fi

cat >/etc/default/pd-underlay <<EOF
# Digi VXLAN-only PD (GRE retired). Soft cutover.
PD_UNDERLAY=digi-vxlan
PD_TRANSPORT=vxlan
PD_GRE=0
PD_PPPOE=1
DIGI_VTEP=$SRC
DIGI_VXLAN_INSTANCE=$NEW_INST
PD_ALLOW_VPP_RESTART=0
PD_ALLOW_PPPOE_RESTART=0
EOF
printf '%s\n' "$SRC" > /run/pd-vxlan-digi-vtep.txt

$VPP show vxlan tunnel
$VPP ping "$LAB_VPS" repeat 3 2>&1 | tail -8 || true
