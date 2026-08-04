#!/bin/bash
# Digi sticky outbound — VPP-native (Linux off L3 datapath).
#
#   GW 79.172.242.1 on VPP loop10 / table 81 (default → GRE/PD)
#   TCP SYN + ACL permit+reflect session stickiness
#     → ABF → tap80 ──Linux L2 bridge── tap81 → NAT44 → digi
#   else → FIB table 81 → gre0 (dedicated IP)
#
# Linux only bridges tap80↔tap81 (no IP, no iptables, no .1).
# Fallback: digi-sticky-outbound-linux.sh
set -euo pipefail
VPP="${VPP:-/usr/bin/vppctl -s /run/vpp/cli.sock}"
LAN_BD="${LAN_BD:-10}"
LAN_GW="${LAN_GW:-79.172.242.1}"
LAN_PREFIX="${LAN_PREFIX:-79.172.242.0/24}"
PBR_TABLE="${PBR_TABLE:-81}"
DIGI_TABLE="${DIGI_TABLE:-82}"
ACL_IDX="${ACL_IDX:-100}"
ABF_ID="${ABF_ID:-42}"
TAP_A_ID="${TAP_A_ID:-80}"
TAP_B_ID="${TAP_B_ID:-81}"
TAP_A_HOST="${TAP_A_HOST:-vpp-sticky-a}"
TAP_B_HOST="${TAP_B_HOST:-vpp-sticky-b}"
WIRE_BR="${WIRE_BR:-sticky-wire}"
HAIRPIN_A="10.254.90.1"
HAIRPIN_B="10.254.90.2"
PPPOE_PEER="${PPPOE_PEER:-}"

# Legacy Linux-sticky names
LEGACY_STICKY=vpp-sticky
LEGACY_OUT=vpp-digi-out
LEGACY_GRE=vpp-gre-out

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

nat44_ei_set() {
  # VPP 26.06: "set interface nat44 ei in X out Y [del]" — del is silent on success
  local in_if="$1" out_if="$2" op="${3:-add}"
  if [ "$op" = del ]; then
    $VPP set interface nat44 ei in "$in_if" out "$out_if" del 2>/dev/null || true
  else
    $VPP set interface nat44 ei in "$in_if" out "$out_if" del 2>/dev/null || true
    $VPP set interface nat44 ei in "$in_if" out "$out_if"
  fi
}

strip_linux_l3() {
  iptables -t mangle -D PREROUTING -i "$LEGACY_STICKY" -j DIGI_STICKY 2>/dev/null || true
  iptables -t mangle -F DIGI_STICKY 2>/dev/null || true
  iptables -t mangle -X DIGI_STICKY 2>/dev/null || true
  ip rule del fwmark 42 table 82 2>/dev/null || true
  ip rule del iif "$LEGACY_STICKY" table 81 2>/dev/null || true
  ip route flush table 82 2>/dev/null || true
  ip route flush table 81 2>/dev/null || true
  iptables -t nat -D POSTROUTING -o "$LEGACY_OUT" -j MASQUERADE 2>/dev/null || true
  # iptables-nft may reject -S/-D on nat; clear via nft when present
  if command -v nft >/dev/null 2>&1; then
    nft delete rule ip nat POSTROUTING oifname "$LEGACY_OUT" masquerade 2>/dev/null || true
  fi
  for pair in \
    "-i $LEGACY_STICKY -o $LEGACY_OUT" \
    "-i $LEGACY_OUT -o $LEGACY_STICKY" \
    "-i $LEGACY_STICKY -o $LEGACY_GRE" \
    "-i $LEGACY_GRE -o $LEGACY_STICKY"; do
    # shellcheck disable=SC2086
    iptables -D FORWARD $pair -j ACCEPT 2>/dev/null || true
  done
  for ifc in "$LEGACY_STICKY" "$LEGACY_OUT" "$LEGACY_GRE"; do
    ip addr flush dev "$ifc" 2>/dev/null || true
  done
  nat44_ei_set tap71 digi del
  # Legacy LAN tap: stay in BD for L2 only, no IP (avoid ARP fight with loop10 .1)
  $VPP set interface ip address del tap70 all 2>/dev/null || true
  ip addr flush dev "$LEGACY_STICKY" 2>/dev/null || true
}

strip_abf_nat_experiment() {
  $VPP abf attach ip4 policy "$ABF_ID" del loop10 2>/dev/null || true
  $VPP abf attach ip4 policy "$ABF_ID" del tap70 2>/dev/null || true
  for via in "via ip4-lookup-in-table $DIGI_TABLE" "via 10.254.90.2 tap80" "via 10.254.90.2 tap${TAP_A_ID}"; do
    $VPP abf policy del id "$ABF_ID" $via 2>/dev/null || true
  done
  # Clear any leftover digi-as-inside NAT
  nat44_ei_set digi digi del
  nat44_ei_set loop10 digi del
  nat44_ei_set tap81 digi del
  nat44_ei_set tap${TAP_B_ID} digi del
}

if [ -z "$PPPOE_PEER" ]; then
  PPPOE_PEER=$($VPP show pppoe client detail 2>/dev/null \
    | sed -n 's/.*ipv4 local [0-9.]* peer \([0-9.]*\).*/\1/p' | tr -d '\r' | head -1)
fi
: "${PPPOE_PEER:?pppoe peer missing}"

if ! $VPP show plugins 2>/dev/null | grep -q abf_plugin; then
  echo "digi-sticky: abf_plugin not loaded" >&2
  exit 1
fi

strip_linux_l3
strip_abf_nat_experiment

$VPP create bridge-domain "$LAN_BD" 2>/dev/null || true
ensure_loop10

# --- GW on VPP BVI ---
$VPP set interface ip address del loop10 all 2>/dev/null || true
$VPP ip table add "$PBR_TABLE" 2>/dev/null || true
$VPP set interface ip table loop10 "$PBR_TABLE" 2>/dev/null || true
$VPP set interface ip address loop10 "${LAN_GW}/24"
$VPP set interface state loop10 up
$VPP ip route del table "$PBR_TABLE" 0.0.0.0/0 2>/dev/null || true
$VPP ip route add table "$PBR_TABLE" 0.0.0.0/0 via 172.16.207.1 gre0
$VPP ip route del "$LAN_PREFIX" 2>/dev/null || true
$VPP ip route add "$LAN_PREFIX" via loop10 2>/dev/null || true
$VPP ip route del table "$PBR_TABLE" "$LAN_PREFIX" 2>/dev/null || true
$VPP ip route add table "$PBR_TABLE" "$LAN_PREFIX" via loop10 2>/dev/null || true

# --- Hairpin wire (L2 only on Linux) ---
ensure_tap "$TAP_A_ID" "$TAP_A_HOST" 4 4 4096
ensure_tap "$TAP_B_ID" "$TAP_B_HOST" 4 4 4096
$VPP set interface state tap${TAP_A_ID} up
$VPP set interface state tap${TAP_B_ID} up
if ! ip link show "$WIRE_BR" &>/dev/null; then
  ip link add "$WIRE_BR" type bridge
fi
ip link set "$TAP_A_HOST" nomaster 2>/dev/null || true
ip link set "$TAP_B_HOST" nomaster 2>/dev/null || true
ip addr flush dev "$TAP_A_HOST" 2>/dev/null || true
ip addr flush dev "$TAP_B_HOST" 2>/dev/null || true
ip addr flush dev "$WIRE_BR" 2>/dev/null || true
ip link set "$TAP_A_HOST" master "$WIRE_BR"
ip link set "$TAP_B_HOST" master "$WIRE_BR"
ip link set "$WIRE_BR" up
ip link set "$TAP_A_HOST" up
ip link set "$TAP_B_HOST" up
sysctl -q -w net.ipv6.conf."$WIRE_BR".disable_ipv6=1 2>/dev/null || true
sysctl -q -w net.ipv6.conf."$TAP_A_HOST".disable_ipv6=1 2>/dev/null || true
sysctl -q -w net.ipv6.conf."$TAP_B_HOST".disable_ipv6=1 2>/dev/null || true

$VPP set interface ip address del tap${TAP_A_ID} all 2>/dev/null || true
$VPP set interface ip address tap${TAP_A_ID} "${HAIRPIN_A}/30"
$VPP ip table add "$DIGI_TABLE" 2>/dev/null || true
$VPP set interface ip address del tap${TAP_B_ID} all 2>/dev/null || true
$VPP set interface ip table tap${TAP_B_ID} "$DIGI_TABLE" 2>/dev/null || true
$VPP set interface ip address tap${TAP_B_ID} "${HAIRPIN_B}/30"

MAC_A=$($VPP show hardware-interfaces tap${TAP_A_ID} 2>/dev/null | awk '/Ethernet address/{print $3; exit}')
MAC_B=$($VPP show hardware-interfaces tap${TAP_B_ID} 2>/dev/null | awk '/Ethernet address/{print $3; exit}')
: "${MAC_A:?tap${TAP_A_ID} mac missing}"
: "${MAC_B:?tap${TAP_B_ID} mac missing}"
$VPP set ip neighbor tap${TAP_A_ID} "$HAIRPIN_B" "$MAC_B" static
$VPP set ip neighbor tap${TAP_B_ID} "$HAIRPIN_A" "$MAC_A" static

$VPP ip route del table "$DIGI_TABLE" 0.0.0.0/0 2>/dev/null || true
$VPP ip route add table "$DIGI_TABLE" 0.0.0.0/0 via "$PPPOE_PEER" digi
$VPP ip route del table "$DIGI_TABLE" "$LAN_PREFIX" 2>/dev/null || true
$VPP ip route add table "$DIGI_TABLE" "$LAN_PREFIX" via loop10 2>/dev/null || true

$VPP nat44 ei plugin enable sessions 131072 users 4096 inside-vrf "$DIGI_TABLE" outside-vrf 0 2>/dev/null \
  || $VPP nat44 ei plugin enable 2>/dev/null || true
DIGI_IP=$($VPP show interface address digi 2>/dev/null | awk '/L3 [0-9]+\./{gsub(/\/.*/,"",$2); print $2; exit}')
[ -n "${DIGI_IP:-}" ] && $VPP nat44 ei add address "$DIGI_IP" 2>/dev/null || true
nat44_ei_set "tap${TAP_B_ID}" digi add
$VPP nat44 ei forwarding disable 2>/dev/null || true
$VPP nat44 ei mss-clamping 1452 2>/dev/null || true

# ACL: pure SYN (tcpflags SYN=2, mask SYN|ACK=18) + reflect for sticky Digi path.
# Deny ACEs = no ABF redirect (normal FIB → GRE). Do not use "tcp flags syn syn"
# alone as mask=syn also matches SYN-ACK.
ACL_OUT=$($VPP set acl-plugin acl index "$ACL_IDX" tag digi-sticky-syn \
  deny src 0.0.0.0/0 dst 79.172.242.0/24, \
  deny src 0.0.0.0/0 dst 10.0.0.0/8, \
  deny src 0.0.0.0/0 dst 172.16.0.0/12, \
  deny src 0.0.0.0/0 dst 192.168.0.0/16, \
  deny src 0.0.0.0/0 dst 100.64.0.0/10, \
  permit+reflect src 79.172.242.0/24 dst 0.0.0.0/0 proto 6 tcpflags 2 mask 18, \
  deny src 0.0.0.0/0 dst 0.0.0.0/0)
echo "digi-sticky: acl ${ACL_OUT:-index $ACL_IDX}"

$VPP abf policy del id "$ABF_ID" via "$HAIRPIN_B" tap${TAP_A_ID} 2>/dev/null || true
$VPP abf policy add id "$ABF_ID" acl "$ACL_IDX" via "$HAIRPIN_B" tap${TAP_A_ID}
$VPP abf attach ip4 policy "$ABF_ID" loop10

# Seed LAN neigh on BVI for gre0→LAN
for seed in 79.172.242.2 79.172.242.3 79.172.242.10; do
  $VPP ping "$seed" repeat 1 2>/dev/null || true
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

# Bounce .1 + GARP so LAN hosts (PVE) drop stale Linux-tap MAC
$VPP set interface ip address del loop10 "${LAN_GW}/24" 2>/dev/null || true
$VPP set interface ip address loop10 "${LAN_GW}/24"
if command -v arping >/dev/null 2>&1; then
  for garp_if in x520lan "$LEGACY_STICKY" x520extra0; do
    ip link show "$garp_if" &>/dev/null || continue
    arping -c 2 -U -I "$garp_if" "$LAN_GW" >/dev/null 2>&1 || true
  done
fi

mkdir -p /etc/pd
printf 'enabled=1\nmode=vpp-abf-hairpin\n' > /etc/pd/sticky-digi

# Sanity: hairpin L3 + ABF feature + NAT on tap81
$VPP show version >/dev/null
$VPP ping "$HAIRPIN_B" repeat 1 >/dev/null
if ! $VPP show interface features loop10 2>/dev/null | grep -q abf-input-ip4; then
  echo "digi-sticky: ABF not attached on loop10" >&2
  exit 1
fi
if ! $VPP show interface features "tap${TAP_B_ID}" 2>/dev/null | grep -q nat44-ei-in2out; then
  echo "digi-sticky: NAT44 missing on tap${TAP_B_ID}" >&2
  exit 1
fi
echo "digi-sticky-outbound: VPP-native GW ${LAN_GW} on loop10; TCP SYN+session→tap${TAP_A_ID}→NAT→digi/${PPPOE_PEER}; else→GRE"
