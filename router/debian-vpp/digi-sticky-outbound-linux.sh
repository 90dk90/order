#!/bin/bash
# Digi-only sticky max-BW egress (Linux L3 policy; PVE stays on GW .1).
#
#   Any host on 79.172.242.0/24 → GW 79.172.242.1 (Linux on LAN bridge)
#     TCP SYN (client NEW)  → Digi PPPoE + NAT44 (10G)
#     else (SYN-ACK/UDP/ICMP, inbound service replies) → GRE/PD
#
# VPP-native status (see vpp-native-sticky-research.sh):
#   - ABF-on-BVI can work when clean; crashes seen were dirty-state/NAT misuse
#   - classify set-ip4-fib-id and ACL-on-BVI are stable alternatives to ABF
#   - stickiness still needs permit+reflect / conntrack (SYN-only is not enough)
#   - non-BVI tap as .1 cannot IRB-route; GW cutover needs GARP
#   - production stays on this Linux hairpin until the prototype above is proven
set -euo pipefail
VPP="${VPP:-/usr/bin/vppctl -s /run/vpp/cli.sock}"
LAN_BD="${LAN_BD:-10}"
LAN_GW="${LAN_GW:-79.172.242.1}"
LAN_PREFIX="${LAN_PREFIX:-79.172.242.0/24}"
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

ensure_tap() {
  local id="$1" host="$2" rxq="$3" txq="$4" rings="$5"
  if ! $VPP show interface 2>/dev/null | grep -q "tap${id}"; then
    $VPP create tap id "$id" host-if-name "$host" host-mtu-size 1500 \
      num-rx-queues "$rxq" num-tx-queues "$txq" rx-ring-size "$rings" tx-ring-size "$rings"
  fi
}

ensure_loop10() {
  if ! $VPP show interface 2>/dev/null | grep -q '^loop10'; then
    $VPP create loopback interface instance 10
  fi
  $VPP set interface state loop10 up
  $VPP set interface l2 bridge loop10 "$LAN_BD" bvi 2>/dev/null || true
  for iface in x520lan x520extra0 x520extra1; do
    $VPP set interface l2 bridge "$iface" "$LAN_BD" 2>/dev/null || true
    $VPP set interface state "$iface" up 2>/dev/null || true
  done
}

if [ -z "$PPPOE_PEER" ]; then
  PPPOE_PEER=$($VPP show pppoe client detail 2>/dev/null \
    | sed -n 's/.*ipv4 local [0-9.]* peer \([0-9.]*\).*/\1/p' | tr -d '\r' | head -1)
fi
: "${PPPOE_PEER:?pppoe peer missing}"

$VPP create bridge-domain "$LAN_BD" 2>/dev/null || true
ensure_loop10

# --- LAN gateway on Linux (bridged tap) ---
ensure_tap "$STICKY_ID" "$STICKY_IF" 4 4 4096
$VPP set interface state tap${STICKY_ID} up
$VPP set interface l2 bridge tap${STICKY_ID} "$LAN_BD" 2>/dev/null || true
# VPP BVI keeps no .1 — Linux owns GW
$VPP set interface ip address del loop10 "${LAN_GW}/24" 2>/dev/null || true
# ARP source on BVI so gre0→LAN glean works (without this: "no source address for ARP")
$VPP set interface ip address del loop10 79.172.242.254/32 2>/dev/null || true
$VPP set interface ip address loop10 79.172.242.254/32 2>/dev/null || true
ip link set "$STICKY_IF" up
ip addr del 79.172.242.253/24 dev "$STICKY_IF" 2>/dev/null || true
ip addr replace "${LAN_GW}/24" dev "$STICKY_IF"
# Announce GW MAC so LAN hosts (PVE) drop stale neigh after cutovers
if command -v arping >/dev/null 2>&1; then
  arping -c 2 -U -I "$STICKY_IF" "$LAN_GW" >/dev/null 2>&1 || true
fi
sysctl -q -w net.ipv4.conf."$STICKY_IF".forwarding=1

ensure_tap "$OUT_ID" "$OUT_IF" 4 4 4096
$VPP set interface state tap${OUT_ID} up
$VPP ip table add "$DIGI_TABLE" 2>/dev/null || true
$VPP set interface ip address del tap${OUT_ID} all 2>/dev/null || true
$VPP set interface ip table tap${OUT_ID} "$DIGI_TABLE" 2>/dev/null || true
$VPP set interface ip address tap${OUT_ID} "${OUT_VPP}/30"
ip link set "$OUT_IF" up
ip addr replace "${OUT_HOST}/30" dev "$OUT_IF"

ensure_tap "$GRE_ID" "$GRE_IF" 2 2 2048
$VPP set interface state tap${GRE_ID} up
$VPP set interface ip address del tap${GRE_ID} all 2>/dev/null || true
$VPP set interface ip table tap${GRE_ID} 81 2>/dev/null || true
$VPP set interface ip address tap${GRE_ID} "${GRE_VPP}/30"
ip link set "$GRE_IF" up
ip addr replace "${GRE_HOST}/30" dev "$GRE_IF"

# Seed ARP for known LAN hosts (glean alone is slow / lossy right after apply)
for seed in 79.172.242.2 79.172.242.3 79.172.242.10 79.172.242.48; do
  ping -c 1 -W 1 "$seed" >/dev/null 2>&1 || true
done
while read -r ip mac; do
  case "$ip" in
    79.172.242.*)
      [ "$ip" = "$LAN_GW" ] && continue
      [ "$ip" = "79.172.242.254" ] && continue
      [ -n "$mac" ] && [ "$mac" != "FAILED" ] && [ "$mac" != "INCOMPLETE" ] && \
        $VPP set ip neighbor loop10 "$ip" "$mac" static 2>/dev/null || true
      ;;
  esac
done < <(ip neigh show 2>/dev/null | awk '/79\.172\.242\./ && /lladdr/{print $1,$5}')

$VPP nat44 ei plugin enable sessions 131072 users 4096 inside-vrf "$DIGI_TABLE" outside-vrf 0 2>/dev/null \
  || $VPP nat44 ei plugin enable 2>/dev/null || true
DIGI_IP=$($VPP show interface address digi 2>/dev/null | awk '/L3 [0-9]+\./{gsub(/\/.*/,"",$2); print $2; exit}')
[ -n "${DIGI_IP:-}" ] && $VPP nat44 ei add address "$DIGI_IP" 2>/dev/null || true
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
$VPP ip route del table 81 "$LAN_PREFIX" 2>/dev/null || true
$VPP ip route add table 81 "$LAN_PREFIX" via loop10 2>/dev/null || true
$VPP ip route del "$LAN_PREFIX" 2>/dev/null || true
$VPP ip route add "$LAN_PREFIX" via loop10 2>/dev/null || true

sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv4.conf.all.rp_filter=0
sysctl -q -w net.ipv4.conf."$STICKY_IF".rp_filter=0
sysctl -q -w net.ipv4.conf."$OUT_IF".rp_filter=0
sysctl -q -w net.ipv4.conf."$GRE_IF".rp_filter=0

iptables -t mangle -N DIGI_STICKY 2>/dev/null || iptables -t mangle -F DIGI_STICKY
iptables -t mangle -C PREROUTING -i "$STICKY_IF" -j DIGI_STICKY 2>/dev/null || \
  iptables -t mangle -I PREROUTING 1 -i "$STICKY_IF" -j DIGI_STICKY
iptables -t mangle -A DIGI_STICKY -d "$LAN_PREFIX" -j RETURN
iptables -t mangle -A DIGI_STICKY -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A DIGI_STICKY -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A DIGI_STICKY -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A DIGI_STICKY -j CONNMARK --restore-mark
iptables -t mangle -A DIGI_STICKY -m mark --mark "$DIGI_MARK" -j RETURN
iptables -t mangle -A DIGI_STICKY -p tcp --tcp-flags SYN,ACK,FIN,RST SYN \
  -m conntrack --ctstate NEW -j MARK --set-mark "$DIGI_MARK"
iptables -t mangle -A DIGI_STICKY -m mark --mark "$DIGI_MARK" -j CONNMARK --save-mark

ip rule del fwmark "$DIGI_MARK" table 82 2>/dev/null || true
ip rule add fwmark "$DIGI_MARK" table 82 priority 100
ip route replace default via "$OUT_VPP" table 82
ip route replace "$LAN_PREFIX" dev "$STICKY_IF" table 82

ip rule del iif "$STICKY_IF" table "$GRE_TABLE_LINUX" 2>/dev/null || true
ip rule add iif "$STICKY_IF" table "$GRE_TABLE_LINUX" priority 200
ip route replace default via "$GRE_VPP" table "$GRE_TABLE_LINUX"
ip route replace "$LAN_PREFIX" dev "$STICKY_IF" table "$GRE_TABLE_LINUX"
ip rule del iif "$STICKY_IF" table 82 2>/dev/null || true

iptables -t nat -C POSTROUTING -o "$OUT_IF" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -I POSTROUTING 1 -o "$OUT_IF" -j MASQUERADE

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

mkdir -p /etc/pd
printf 'enabled=1\nmode=linux\n' > /etc/pd/sticky-digi

echo "digi-sticky-outbound: GW ${LAN_GW} Linux; TCP SYN→digi/${PPPOE_PEER}+NAT; else→GRE"
