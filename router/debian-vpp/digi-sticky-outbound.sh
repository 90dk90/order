#!/bin/bash
# Digi sticky outbound — VPP-native (no ABF, no Linux L3).
#
# WHY NOT ABF: abf_plugin.so SIGSEGV on BVI loop10 under traffic (VPP 26.06).
#
# Design (mode=vpp-classify):
#   GW 79.172.242.1 on loop10 BVI / table 81 (default → gre0 / dedicated IP)
#   ip4-inacl classify on loop10:
#     TCP src_port ∈ SERVICE_PORTS → fib 81 (inbound service replies → GRE)
#     other TCP                   → fib 82 → tap80 ──L2 wire── tap81/table83
#                                   → NAT44 → digi (max BW)
#     UDP/ICMP/miss               → fib 81 → gre0
#
# Stickiness: all client TCP (ephemeral sport) stays on Digi; service sports
# stay on GRE so public inbound (SSH/HTTPS/…) keeps the dedicated IP.
#
# Linux only L2-bridges tap80↔tap81 (no IP, no iptables, no .1).
set -euo pipefail

VPP_BIN="${VPP_BIN:-/usr/bin/vppctl}"
VPP_SOCK="${VPP_SOCK:-/run/vpp/cli.sock}"
vpp() {
  # Strip CR from vppctl; never fail the script on pipe/close races
  "$VPP_BIN" -s "$VPP_SOCK" "$@" 2>&1 | tr -d '\r' || true
}

LAN_BD="${LAN_BD:-10}"
LAN_GW="${LAN_GW:-79.172.242.1}"
LAN_PREFIX="${LAN_PREFIX:-79.172.242.0/24}"
GRE_TABLE="${GRE_TABLE:-81}"
HAIRPIN_TABLE="${HAIRPIN_TABLE:-82}"
DIGI_TABLE="${DIGI_TABLE:-83}"
TAP_A_ID="${TAP_A_ID:-80}"
TAP_B_ID="${TAP_B_ID:-81}"
TAP_A_HOST="${TAP_A_HOST:-vpp-sticky-a}"
TAP_B_HOST="${TAP_B_HOST:-vpp-sticky-b}"
WIRE_BR="${WIRE_BR:-sticky-wire}"
HAIRPIN_A="10.254.90.1"
HAIRPIN_B="10.254.90.2"
# Inbound service source ports that must stay on GRE/dedicated IP
SERVICE_PORTS="${SERVICE_PORTS:-22 80 443 8006 25565 51820 7777 27015 3389 8080 8443}"
PPPOE_PEER="${PPPOE_PEER:-}"

LEGACY_STICKY=vpp-sticky
LEGACY_OUT=vpp-digi-out
LEGACY_GRE=vpp-gre-out

ensure_tap() {
  local id="$1" host="$2" rxq="$3" txq="$4" rings="$5"
  if ! vpp show interface | grep -q "tap${id}"; then
    vpp create tap id "$id" host-if-name "$host" host-mtu-size 1500 \
      num-rx-queues "$rxq" num-tx-queues "$txq" rx-ring-size "$rings" tx-ring-size "$rings" >/dev/null
  fi
}

ensure_loop10() {
  if ! vpp show interface | grep -q '^loop10'; then
    vpp create loopback interface instance 10 >/dev/null
  fi
  vpp set interface state loop10 up >/dev/null
  vpp set interface l2 bridge loop10 "$LAN_BD" bvi >/dev/null || true
  for iface in x520lan x520extra0 x520extra1; do
    vpp set interface l2 bridge "$iface" "$LAN_BD" >/dev/null || true
    vpp set interface state "$iface" up >/dev/null || true
  done
}

nat44_ei() {
  # VPP 26.06: "set interface nat44 ei in X out Y [del]"
  local in_if="$1" out_if="$2" op="${3:-add}"
  if [ "$op" = del ]; then
    vpp set interface nat44 ei in "$in_if" out "$out_if" del >/dev/null || true
  else
    vpp set interface nat44 ei in "$in_if" out "$out_if" del >/dev/null || true
    vpp set interface nat44 ei in "$in_if" out "$out_if" >/dev/null
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
  nat44_ei tap71 digi del
  vpp set interface ip address del tap70 all >/dev/null || true
  ip addr flush dev "$LEGACY_STICKY" 2>/dev/null || true
}

strip_abf() {
  # Never use ABF on this box — detach leftovers only
  vpp abf attach ip4 policy 42 del loop10 >/dev/null || true
  vpp abf attach ip4 policy 42 del tap70 >/dev/null || true
  vpp abf policy del id 42 via "$HAIRPIN_B" tap${TAP_A_ID} >/dev/null || true
  vpp abf policy del id 42 via 10.254.90.2 tap80 >/dev/null || true
}

strip_classify() {
  # Detach any prior inacl (index from flag file if present)
  local old_sport
  old_sport=$(sed -n 's/^sport_table=//p' /etc/pd/sticky-digi 2>/dev/null | head -1 || true)
  if [ -n "${old_sport:-}" ]; then
    vpp set interface input acl intfc loop10 ip4-table "$old_sport" del >/dev/null || true
  fi
  vpp set interface input acl intfc loop10 ip4-table 0 del >/dev/null || true
  local i
  for i in $(seq 0 64); do
    vpp classify table table "$i" del >/dev/null || true
  done
}

if [ -z "$PPPOE_PEER" ]; then
  PPPOE_PEER=$(vpp show pppoe client detail \
    | sed -n 's/.*ipv4 local [0-9.]* peer \([0-9.]*\).*/\1/p' | head -1)
fi
: "${PPPOE_PEER:?pppoe peer missing — start vpp-pppoe-native first}"

if ! vpp show version >/dev/null; then
  echo "digi-sticky: vpp cli not ready" >&2
  exit 1
fi

strip_linux_l3
strip_abf
strip_classify

vpp create bridge-domain "$LAN_BD" >/dev/null || true
ensure_loop10

# --- GW on VPP BVI / GRE default ---
vpp set interface ip address del loop10 all >/dev/null || true
vpp ip table add "$GRE_TABLE" >/dev/null || true
vpp set interface ip table loop10 "$GRE_TABLE" >/dev/null || true
vpp set interface ip address loop10 "${LAN_GW}/24" >/dev/null
vpp set interface state loop10 up >/dev/null
vpp ip route del table "$GRE_TABLE" 0.0.0.0/0 >/dev/null || true
vpp ip route add table "$GRE_TABLE" 0.0.0.0/0 via 172.16.207.1 gre0 >/dev/null
vpp ip route del "$LAN_PREFIX" >/dev/null || true
vpp ip route add "$LAN_PREFIX" via loop10 >/dev/null || true
vpp ip route del table "$GRE_TABLE" "$LAN_PREFIX" >/dev/null || true
vpp ip route add table "$GRE_TABLE" "$LAN_PREFIX" via loop10 >/dev/null || true

# --- Hairpin wire (L2 only on Linux) ---
ensure_tap "$TAP_A_ID" "$TAP_A_HOST" 4 4 4096
ensure_tap "$TAP_B_ID" "$TAP_B_HOST" 4 4 4096
vpp set interface state tap${TAP_A_ID} up >/dev/null
vpp set interface state tap${TAP_B_ID} up >/dev/null
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

vpp set interface ip address del tap${TAP_A_ID} all >/dev/null || true
vpp set interface ip address tap${TAP_A_ID} "${HAIRPIN_A}/30" >/dev/null

# table 82: classify target → hairpin out tap80
vpp ip table add "$HAIRPIN_TABLE" >/dev/null || true
vpp ip route del table "$HAIRPIN_TABLE" 0.0.0.0/0 >/dev/null || true
vpp ip route add table "$HAIRPIN_TABLE" 0.0.0.0/0 via "$HAIRPIN_B" tap${TAP_A_ID} >/dev/null
vpp ip route del table "$HAIRPIN_TABLE" "$LAN_PREFIX" >/dev/null || true
vpp ip route add table "$HAIRPIN_TABLE" "$LAN_PREFIX" via loop10 >/dev/null || true

# table 83: tap81 → NAT → digi
vpp ip table add "$DIGI_TABLE" >/dev/null || true
vpp set interface ip address del tap${TAP_B_ID} all >/dev/null || true
vpp set interface ip table tap${TAP_B_ID} "$DIGI_TABLE" >/dev/null || true
vpp set interface ip address tap${TAP_B_ID} "${HAIRPIN_B}/30" >/dev/null

MAC_A=$(vpp show hardware-interfaces tap${TAP_A_ID} | awk '/Ethernet address/{print $3; exit}')
MAC_B=$(vpp show hardware-interfaces tap${TAP_B_ID} | awk '/Ethernet address/{print $3; exit}')
: "${MAC_A:?tap${TAP_A_ID} mac missing}"
: "${MAC_B:?tap${TAP_B_ID} mac missing}"
vpp set ip neighbor tap${TAP_A_ID} "$HAIRPIN_B" "$MAC_B" static >/dev/null
vpp set ip neighbor tap${TAP_B_ID} "$HAIRPIN_A" "$MAC_A" static >/dev/null

vpp ip route del table "$DIGI_TABLE" 0.0.0.0/0 >/dev/null || true
vpp ip route add table "$DIGI_TABLE" 0.0.0.0/0 via "$PPPOE_PEER" digi >/dev/null
vpp ip route del table "$DIGI_TABLE" "$LAN_PREFIX" >/dev/null || true
vpp ip route add table "$DIGI_TABLE" "$LAN_PREFIX" via loop10 >/dev/null || true

vpp nat44 ei plugin enable sessions 131072 users 4096 inside-vrf "$DIGI_TABLE" outside-vrf 0 >/dev/null \
  || vpp nat44 ei plugin enable >/dev/null || true
DIGI_IP=$(vpp show interface address digi | awk '/L3 [0-9]+\./{gsub(/\/.*/,"",$2); print $2; exit}')
[ -n "${DIGI_IP:-}" ] && vpp nat44 ei add address "$DIGI_IP" >/dev/null || true
nat44_ei "tap${TAP_B_ID}" digi add
vpp nat44 ei forwarding disable >/dev/null || true
vpp nat44 ei mss-clamping 1452 >/dev/null || true

# --- classify chain: sport table → proto table ---
# Match buffers MUST include skip_n_vectors padding (16B per skip).
vpp classify table mask l3 ip4 proto buckets 64 memory-size 2M >/dev/null
PROTO_IDX=$(vpp show classify tables | awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/{print $1; exit}')
: "${PROTO_IDX:?proto classify table missing}"

vpp classify table mask l3 ip4 proto l4 src_port buckets 128 memory-size 4M next-table "$PROTO_IDX" >/dev/null
SPORT_IDX=$(vpp show classify tables | awk '
  /^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/{idx=$1}
  /ffff000000000000000000000000$/{print idx; exit}
')
: "${SPORT_IDX:?sport classify table missing}"

# proto 6 → fib 82 (skip1 pad + match1)
PROTO_MATCH="0000000000000000000000000000000000000000000000060000000000000000"
vpp classify session table-index "$PROTO_IDX" match hex "$PROTO_MATCH" action set-ip4-fib-id "$HAIRPIN_TABLE" >/dev/null

pad="00000000000000000000000000000000"
m1="00000000000000060000000000000000"
for port in $SERVICE_PORTS; do
  hp=$(printf '%04x' "$port")
  match="${pad}${m1}0000${hp}000000000000000000000000"
  vpp classify session table-index "$SPORT_IDX" match hex "$match" action set-ip4-fib-id "$GRE_TABLE" >/dev/null
done

vpp set interface input acl intfc loop10 ip4-table "$SPORT_IDX" >/dev/null

# Seed LAN neigh + GARP
for seed in 79.172.242.2 79.172.242.3 79.172.242.10; do
  vpp ping "$seed" repeat 1 >/dev/null || true
done
while read -r ip mac; do
  case "$ip" in
    79.172.242.*)
      [ "$ip" = "$LAN_GW" ] && continue
      [ "$ip" = "79.172.242.254" ] && continue
      [ -n "$mac" ] && [ "$mac" != "FAILED" ] && [ "$mac" != "INCOMPLETE" ] && \
        vpp set ip neighbor loop10 "$ip" "$mac" static >/dev/null || true
      ;;
  esac
done < <(ip neigh show 2>/dev/null | awk '/79\.172\.242\./ && /lladdr/{print $1,$5}')

vpp set interface ip address del loop10 "${LAN_GW}/24" >/dev/null || true
vpp set interface ip address loop10 "${LAN_GW}/24" >/dev/null
if command -v arping >/dev/null 2>&1; then
  for garp_if in x520lan "$LEGACY_STICKY" x520extra0; do
    ip link show "$garp_if" &>/dev/null || continue
    arping -c 2 -U -I "$garp_if" "$LAN_GW" >/dev/null 2>&1 || true
  done
fi

mkdir -p /etc/pd
printf 'enabled=1\nmode=vpp-classify\nproto_table=%s\nsport_table=%s\n' \
  "$PROTO_IDX" "$SPORT_IDX" > /etc/pd/sticky-digi

# Sanity
vpp show version >/dev/null
vpp ping "$HAIRPIN_B" repeat 1 >/dev/null
if ! vpp show interface features loop10 | grep -q ip4-inacl; then
  echo "digi-sticky: ip4-inacl not on loop10" >&2
  exit 1
fi
if ! vpp show interface features "tap${TAP_B_ID}" | grep -q nat44-ei-in2out; then
  echo "digi-sticky: NAT44 missing on tap${TAP_B_ID}" >&2
  exit 1
fi

echo "digi-sticky-outbound: VPP-classify GW ${LAN_GW}; TCP→fib${HAIRPIN_TABLE}→NAT→digi/${PPPOE_PEER}; service-sports+UDP/ICMP→GRE; tables sport=${SPORT_IDX} proto=${PROTO_IDX}"
