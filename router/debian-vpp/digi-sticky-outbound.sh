#!/bin/bash
# Digi sticky max-BW egress:
#   PVE NEW outbound → 79.172.242.253 (Linux vpp-sticky, L2)
#   Linux → VPP tap-out → digi PPPoE + NAT44 (X520 10G)
#   Inbound replies stay on 79.172.242.1 / table81 → GRE/PD
set -euo pipefail
VPP="${VPP:-/usr/bin/vppctl -s /run/vpp/cli.sock}"
LAN_BD="${LAN_BD:-10}"
DIGI_GW="${DIGI_GW:-79.172.242.253}"
STICKY_IF="${STICKY_IF:-vpp-sticky}"
STICKY_ID="${STICKY_ID:-70}"
OUT_IF="${OUT_IF:-vpp-digi-out}"
OUT_ID="${OUT_ID:-71}"
OUT_VPP="10.254.80.1"
OUT_HOST="10.254.80.2"
DIGI_TABLE="${DIGI_TABLE:-82}"
PPPOE_PEER="${PPPOE_PEER:-}"

if [ -z "$PPPOE_PEER" ]; then
  PPPOE_PEER=$($VPP show pppoe client detail 2>/dev/null \
    | sed -n 's/.*ipv4 local [0-9.]* peer \([0-9.]*\).*/\1/p' | tr -d '\r' | head -1)
fi
: "${PPPOE_PEER:?pppoe peer missing}"

# --- LAN sticky gateway tap (bridged) ---
if ! $VPP show interface tap${STICKY_ID} >/dev/null 2>&1; then
  $VPP create tap id "$STICKY_ID" host-if-name "$STICKY_IF" host-mtu-size 1500 \
    num-rx-queues 4 num-tx-queues 4 rx-ring-size 4096 tx-ring-size 4096
fi
$VPP set interface state tap${STICKY_ID} up
$VPP set interface l2 bridge tap${STICKY_ID} "$LAN_BD" 2>/dev/null || true
ip link set "$STICKY_IF" up
ip addr replace "${DIGI_GW}/24" dev "$STICKY_IF"

# --- VPP digi-out tap (L3 to PPPoE) ---
if ! $VPP show interface tap${OUT_ID} >/dev/null 2>&1; then
  $VPP create tap id "$OUT_ID" host-if-name "$OUT_IF" host-mtu-size 1500 \
    num-rx-queues 4 num-tx-queues 4 rx-ring-size 4096 tx-ring-size 4096
fi
$VPP set interface state tap${OUT_ID} up
$VPP ip table add "$DIGI_TABLE" 2>/dev/null || true
$VPP set interface ip table tap${OUT_ID} "$DIGI_TABLE" 2>/dev/null || true
$VPP set interface ip address del tap${OUT_ID} all 2>/dev/null || true
$VPP set interface ip address tap${OUT_ID} "${OUT_VPP}/30"

ip link set "$OUT_IF" up
ip addr replace "${OUT_HOST}/30" dev "$OUT_IF"

# NAT44 on digi path (inside = Digi table / tap-out)
# NOTE: VPP 26.x uses `nat44 ei` show/set (not plain `nat44`).
# Do NOT enable forwarding — it bypasses translations when sessions fail.
$VPP nat44 ei plugin enable sessions 131072 users 4096 inside-vrf "$DIGI_TABLE" outside-vrf 0 2>/dev/null \
  || $VPP nat44 ei plugin enable 2>/dev/null || true
$VPP nat44 ei add address "$($VPP show interface addr digi 2>/dev/null | awk '/L3 [0-9]+\./{gsub(/\/.*/,"",$2); print $2; exit}')" 2>/dev/null \
  || $VPP nat44 ei add interface address digi 2>/dev/null || true
$VPP set interface nat44 ei in tap${OUT_ID} out digi del 2>/dev/null || true
$VPP set interface nat44 ei in tap${OUT_ID} out digi
$VPP nat44 ei forwarding disable 2>/dev/null || true
$VPP nat44 ei mss-clamping 1452 2>/dev/null || true

$VPP ip route del table "$DIGI_TABLE" 0.0.0.0/0 2>/dev/null || true
$VPP ip route add table "$DIGI_TABLE" 0.0.0.0/0 via "$PPPOE_PEER" digi
# return path to Linux host for NAT replies
$VPP ip route del table "$DIGI_TABLE" "${OUT_HOST}/32" 2>/dev/null || true
$VPP ip route add table "$DIGI_TABLE" "${OUT_HOST}/32" via tap${OUT_ID} 2>/dev/null \
  || $VPP set ip neighbor tap${OUT_ID} "$OUT_HOST" "$(cat /sys/class/net/$OUT_IF/address)" static

# Linux forward: sticky LAN → digi-out → VPP NAT44 → Digi PPPoE
# MASQ on digi-out is required: without it, VPP o2i returns via loop10
# bridge and sticky reverse path stays empty (smoke tests hang).
sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv4.conf.all.rp_filter=0
sysctl -q -w net.ipv4.conf."$STICKY_IF".rp_filter=0
sysctl -q -w net.ipv4.conf."$OUT_IF".rp_filter=0

iptables -t nat -D POSTROUTING -s 79.172.242.0/24 -o enp36s0 -j MASQUERADE 2>/dev/null || true
iptables -t nat -C POSTROUTING -o "$OUT_IF" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -I POSTROUTING 1 -o "$OUT_IF" -j MASQUERADE

ip route replace default via "$OUT_VPP" table 82
ip rule del iif "$STICKY_IF" table 82 2>/dev/null || true
ip rule add iif "$STICKY_IF" table 82 priority 100
ip route replace 79.172.242.0/24 dev "$STICKY_IF" table 82

iptables -C FORWARD -i "$STICKY_IF" -o "$OUT_IF" -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD 1 -i "$STICKY_IF" -o "$OUT_IF" -j ACCEPT
iptables -C FORWARD -i "$OUT_IF" -o "$STICKY_IF" -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD 1 -i "$OUT_IF" -o "$STICKY_IF" -j ACCEPT
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1452 2>/dev/null || \
  iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1452

# GRE path untouched
$VPP ip route del table 81 0.0.0.0/0 2>/dev/null || true
$VPP ip route add table 81 0.0.0.0/0 via 172.16.207.1 gre0

# drop experimental loop0 Digi-NAT if still around
if $VPP show interface loop0 >/dev/null 2>&1; then
  $VPP set interface nat44 ei in loop0 out digi output-feature del 2>/dev/null || true
  $VPP set interface ip address del loop0 all 2>/dev/null || true
  $VPP set interface state loop0 down 2>/dev/null || true
fi

echo "digi-sticky-outbound: ${DIGI_GW}→${OUT_IF}→digi/${PPPOE_PEER}+NAT44 (10G); GRE .1 ok"
