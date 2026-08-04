#!/bin/bash
# Digi-only sticky max-BW egress (PVE stays on GW .1 — no PVE iptables/routes).
#
#   PVE → 79.172.242.1 (Linux on LAN bridge)
#     TCP SYN (client NEW)  → Digi PPPoE + NAT44 (10G)
#     else (SYN-ACK/UDP/ICMP, inbound service replies) → GRE/PD
#
# Why SYN-only → Digi: inbound GRE never hits Linux, so SYN-ACK looks
# NEW here; sending it Digi would break dedicated-IP SSH/game ports.
set -euo pipefail
VPP="${VPP:-/usr/bin/vppctl -s /run/vpp/cli.sock}"
LAN_BD="${LAN_BD:-10}"
LAN_GW="${LAN_GW:-79.172.242.1}"
STICKY_IF="${STICKY_IF:-vpp-sticky}"
STICKY_ID="${STICKY_ID:-70}"
OUT_IF="${OUT_IF:-vpp-digi-out}"
OUT_ID="${OUT_ID:-71}"
OUT_VPP="10.254.80.1"
OUT_HOST="10.254.80.2"
GRE_IF="${GRE_IF:-vpp-gre-out}"
GRE_ID="${GRE_ID:-72}"
GRE_VPP="10.254.81.1"
GRE_HOST="10.254.81.2"
DIGI_TABLE="${DIGI_TABLE:-82}"
GRE_TABLE_LINUX="${GRE_TABLE_LINUX:-81}"
DIGI_MARK="${DIGI_MARK:-42}"
PPPOE_PEER="${PPPOE_PEER:-}"

if [ -z "$PPPOE_PEER" ]; then
  PPPOE_PEER=$($VPP show pppoe client detail 2>/dev/null \
    | sed -n 's/.*ipv4 local [0-9.]* peer \([0-9.]*\).*/\1/p' | tr -d '\r' | head -1)
fi
: "${PPPOE_PEER:?pppoe peer missing}"

# --- LAN gateway tap (bridged): Linux owns .1 so all PVE L3 hits Digi policy ---
if ! $VPP show interface tap${STICKY_ID} >/dev/null 2>&1; then
  $VPP create tap id "$STICKY_ID" host-if-name "$STICKY_IF" host-mtu-size 1500 \
    num-rx-queues 4 num-tx-queues 4 rx-ring-size 4096 tx-ring-size 4096
fi
$VPP set interface state tap${STICKY_ID} up
$VPP set interface l2 bridge tap${STICKY_ID} "$LAN_BD" 2>/dev/null || true

# Move LAN GW off VPP BVI onto Linux (idempotent)
$VPP set interface ip address del loop10 "${LAN_GW}/24" 2>/dev/null || true
ip link set "$STICKY_IF" up
ip addr del 79.172.242.253/24 dev "$STICKY_IF" 2>/dev/null || true
ip addr replace "${LAN_GW}/24" dev "$STICKY_IF"

# --- Digi PPPoE out tap ---
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

# --- GRE inject tap (Linux → VPP table 81 → gre0) ---
if ! $VPP show interface tap${GRE_ID} >/dev/null 2>&1; then
  $VPP create tap id "$GRE_ID" host-if-name "$GRE_IF" host-mtu-size 1500 \
    num-rx-queues 2 num-tx-queues 2 rx-ring-size 2048 tx-ring-size 2048
fi
$VPP set interface state tap${GRE_ID} up
$VPP set interface ip table tap${GRE_ID} 81 2>/dev/null || true
$VPP set interface ip address del tap${GRE_ID} all 2>/dev/null || true
$VPP set interface ip address tap${GRE_ID} "${GRE_VPP}/30"
ip link set "$GRE_IF" up
ip addr replace "${GRE_HOST}/30" dev "$GRE_IF"

# NAT44 Digi path
$VPP nat44 ei plugin enable sessions 131072 users 4096 inside-vrf "$DIGI_TABLE" outside-vrf 0 2>/dev/null \
  || $VPP nat44 ei plugin enable 2>/dev/null || true
DIGI_IP=$($VPP show interface addr digi 2>/dev/null | awk '/L3 [0-9]+\./{gsub(/\/.*/,"",$2); print $2; exit}')
[ -n "${DIGI_IP:-}" ] && $VPP nat44 ei add address "$DIGI_IP" 2>/dev/null || \
  $VPP nat44 ei add interface address digi 2>/dev/null || true
$VPP set interface nat44 ei in tap${OUT_ID} out digi del 2>/dev/null || true
$VPP set interface nat44 ei in tap${OUT_ID} out digi
$VPP nat44 ei forwarding disable 2>/dev/null || true
$VPP nat44 ei mss-clamping 1452 2>/dev/null || true

$VPP ip route del table "$DIGI_TABLE" 0.0.0.0/0 2>/dev/null || true
$VPP ip route add table "$DIGI_TABLE" 0.0.0.0/0 via "$PPPOE_PEER" digi
$VPP set ip neighbor tap${OUT_ID} "$OUT_HOST" "$(cat /sys/class/net/$OUT_IF/address)" static 2>/dev/null || true
$VPP set ip neighbor tap${GRE_ID} "$GRE_HOST" "$(cat /sys/class/net/$GRE_IF/address)" static 2>/dev/null || true

$VPP ip route del table 81 0.0.0.0/0 2>/dev/null || true
$VPP ip route add table 81 0.0.0.0/0 via 172.16.207.1 gre0
# from GRE inject tap back to LAN hosts via bridge BVI path
$VPP ip route del table 81 79.172.242.0/24 2>/dev/null || true
$VPP ip route add table 81 79.172.242.0/24 via loop10 2>/dev/null || true

sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv4.conf.all.rp_filter=0
sysctl -q -w net.ipv4.conf."$STICKY_IF".rp_filter=0
sysctl -q -w net.ipv4.conf."$OUT_IF".rp_filter=0
sysctl -q -w net.ipv4.conf."$GRE_IF".rp_filter=0

# Policy: TCP SYN → Digi mark; sticky connmark; default → GRE
iptables -t mangle -N DIGI_STICKY 2>/dev/null || iptables -t mangle -F DIGI_STICKY
iptables -t mangle -C PREROUTING -i "$STICKY_IF" -j DIGI_STICKY 2>/dev/null || \
  iptables -t mangle -I PREROUTING 1 -i "$STICKY_IF" -j DIGI_STICKY
iptables -t mangle -A DIGI_STICKY -d 79.172.242.0/24 -j RETURN
iptables -t mangle -A DIGI_STICKY -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A DIGI_STICKY -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A DIGI_STICKY -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A DIGI_STICKY -j CONNMARK --restore-mark
iptables -t mangle -A DIGI_STICKY -m mark --mark "$DIGI_MARK" -j RETURN
# pure SYN only (not SYN+ACK) → Digi
iptables -t mangle -A DIGI_STICKY -p tcp --tcp-flags SYN,ACK,FIN,RST SYN \
  -m conntrack --ctstate NEW -j MARK --set-mark "$DIGI_MARK"
iptables -t mangle -A DIGI_STICKY -m mark --mark "$DIGI_MARK" -j CONNMARK --save-mark

ip rule del fwmark "$DIGI_MARK" table 82 2>/dev/null || true
ip rule add fwmark "$DIGI_MARK" table 82 priority 100
ip route replace default via "$OUT_VPP" table 82
ip route replace 79.172.242.0/24 dev "$STICKY_IF" table 82

# unmarked / GRE path from LAN
ip rule del iif "$STICKY_IF" table "$GRE_TABLE_LINUX" 2>/dev/null || true
ip rule add iif "$STICKY_IF" table "$GRE_TABLE_LINUX" priority 200
ip route replace default via "$GRE_VPP" table "$GRE_TABLE_LINUX"
ip route replace 79.172.242.0/24 dev "$STICKY_IF" table "$GRE_TABLE_LINUX"

# drop old blanket sticky→digi rule
ip rule del iif "$STICKY_IF" table 82 2>/dev/null || true

iptables -t nat -C POSTROUTING -o "$OUT_IF" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -I POSTROUTING 1 -o "$OUT_IF" -j MASQUERADE
# NEVER MASQ toward GRE — keep dedicated /24 source for inbound replies

iptables -C FORWARD -i "$STICKY_IF" -o "$OUT_IF" -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD 1 -i "$STICKY_IF" -o "$OUT_IF" -j ACCEPT
iptables -C FORWARD -i "$OUT_IF" -o "$STICKY_IF" -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD 1 -i "$OUT_IF" -o "$STICKY_IF" -j ACCEPT
iptables -C FORWARD -i "$STICKY_IF" -o "$GRE_IF" -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD 1 -i "$STICKY_IF" -o "$GRE_IF" -j ACCEPT
iptables -C FORWARD -i "$GRE_IF" -o "$STICKY_IF" -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD 1 -i "$GRE_IF" -o "$STICKY_IF" -j ACCEPT
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1452 2>/dev/null || \
  iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1452

echo "digi-sticky-outbound (Digi-only): GW ${LAN_GW}; TCP SYN→digi/${PPPOE_PEER}; else→GRE; PVE untouched"
