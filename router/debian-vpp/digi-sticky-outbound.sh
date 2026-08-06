#!/bin/bash
# Digi sticky outbound — hairpin taps + classify (additive; no LAN FIB deletes).
# Opt-in: PD_ENABLE_STICKY=1 OR --force
#
# loop10 classify:
#   TCP service sports → fib 81 (PD VXLAN /24)
#   other TCP          → fib 82 → tap80 ──L2── tap81/table83 → NAT → digi
#   UDP/ICMP           → fib 81 (PD)
#
# NEVER delete LAN routes / change loop10 IP table / del loop10 addresses
# (those SIGSEGV VPP 26.06).
set -euo pipefail

if [ "${PD_ENABLE_STICKY:-0}" != 1 ] && [ "${1:-}" != "--force" ]; then
  echo "digi-sticky-outbound: disabled. Pass --force or PD_ENABLE_STICKY=1." >&2
  exit 0
fi

VPP="${VPP_BIN:-/usr/bin/vppctl}"
SOCK="${VPP_SOCK:-/run/vpp/cli.sock}"
vc() { "$VPP" -s "$SOCK" "$@" 2>/dev/null || true; }
vo() { "$VPP" -s "$SOCK" "$@" 2>/dev/null | tr -d '\r' || true; }

# shellcheck disable=SC1091
[ -r /etc/default/pd-underlay ] && . /etc/default/pd-underlay

PD_TABLE="${PD_TABLE:-81}"
HAIRPIN_TABLE="${HAIRPIN_TABLE:-82}"
DIGI_TABLE="${DIGI_TABLE:-83}"
TAP_A_ID="${TAP_A_ID:-80}"
TAP_B_ID="${TAP_B_ID:-81}"
TAP_A_HOST="${TAP_A_HOST:-vpp-sticky-a}"
TAP_B_HOST="${TAP_B_HOST:-vpp-sticky-b}"
WIRE_BR="${WIRE_BR:-sticky-wire}"
HAIRPIN_A="10.254.90.1"
HAIRPIN_B="10.254.90.2"
DIGI_IF="${DIGI_IF:-digi}"

SERVICE_PORTS_BASE="${SERVICE_PORTS_BASE:-22 80 443 2022 3306 8006 8080 8443 9090 9108 3389 51820 7777 25565 19132 27015 27016 30110 30120 40120 9987}"
SERVICE_PORT_RANGES="${SERVICE_PORT_RANGES:-25500-25800 30000-30150}"

PPPOE_PEER="${PPPOE_PEER:-}"
[ -z "$PPPOE_PEER" ] && PPPOE_PEER=$(vo show pppoe client detail \
  | sed -n 's/.*ipv4 local [0-9.]* peer \([0-9.]*\).*/\1/p' | head -1)
: "${PPPOE_PEER:?pppoe peer missing}"

DIGI_IP=$(vo show interface address "$DIGI_IF" \
  | awk '/L3 [0-9]+\./{gsub(/\/.*/,"",$2); print $2; exit}')
: "${DIGI_IP:?digi IPv4 missing}"

alive() { vo show version | grep -q vpp; }
alive || { echo "digi-sticky: vpp down" >&2; exit 1; }

# Detach prior classify only
old_sport=$(sed -n 's/^sport_table=//p' /etc/pd/sticky-digi 2>/dev/null | head -1 || true)
if [ -n "${old_sport:-}" ]; then
  vc set interface input acl intfc loop10 ip4-table "$old_sport" del
fi
vc set interface input acl intfc loop10 ip4-table 0 del

# Strip prior NAT on loop10 (broken BVI order)
vc set interface nat44 ei in loop10 out "$DIGI_IF" output-feature del
vc set interface nat44 ei in loop10 out "$DIGI_IF" del

# --- hairpin taps (small rings) ---
ensure_tap() {
  local id="$1" host="$2"
  if ! vo show interface | grep -q "tap${id}"; then
    vc create tap id "$id" host-if-name "$host" host-mtu-size 1500 \
      num-rx-queues 2 num-tx-queues 2 rx-ring-size 1024 tx-ring-size 1024
  fi
  local i
  for i in $(seq 1 50); do
    ip link show "$host" &>/dev/null && return 0
    sleep 0.1
  done
  echo "digi-sticky: host tap $host missing" >&2
  return 1
}

ensure_tap "$TAP_A_ID" "$TAP_A_HOST"
ensure_tap "$TAP_B_ID" "$TAP_B_HOST"
alive || { echo "digi-sticky: vpp died after tap create" >&2; exit 1; }

vc set interface state "tap${TAP_A_ID}" up
vc set interface state "tap${TAP_B_ID}" up

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
sysctl -q -w "net.ipv6.conf.${WIRE_BR}.disable_ipv6=1" 2>/dev/null || true
sysctl -q -w "net.ipv6.conf.${TAP_A_HOST}.disable_ipv6=1" 2>/dev/null || true
sysctl -q -w "net.ipv6.conf.${TAP_B_HOST}.disable_ipv6=1" 2>/dev/null || true

vc ip table add "$HAIRPIN_TABLE"
vc ip table add "$DIGI_TABLE"

vc set interface ip address del "tap${TAP_A_ID}" all
vc set interface ip address "tap${TAP_A_ID}" "${HAIRPIN_A}/30"

# table 82 → hairpin out
vc ip route add table "$HAIRPIN_TABLE" 0.0.0.0/0 via "$HAIRPIN_B" "tap${TAP_A_ID}"
# return to LAN via existing table 81 (additive — do not del)
vc ip route add table "$HAIRPIN_TABLE" 79.172.242.0/24 via ip4-lookup-in-table "$PD_TABLE"
vc ip route add table "$HAIRPIN_TABLE" 79.172.242.2/32 via ip4-lookup-in-table "$PD_TABLE"

vc set interface ip address del "tap${TAP_B_ID}" all
vc set interface ip table "tap${TAP_B_ID}" "$DIGI_TABLE"
vc set interface ip address "tap${TAP_B_ID}" "${HAIRPIN_B}/30"

MAC_A=$(vo show hardware-interfaces "tap${TAP_A_ID}" | awk '/Ethernet address/{print $3; exit}')
MAC_B=$(vo show hardware-interfaces "tap${TAP_B_ID}" | awk '/Ethernet address/{print $3; exit}')
: "${MAC_A:?tapA mac}"; : "${MAC_B:?tapB mac}"
vc set ip neighbor "tap${TAP_A_ID}" "$HAIRPIN_B" "$MAC_B" static
vc set ip neighbor "tap${TAP_B_ID}" "$HAIRPIN_A" "$MAC_A" static

vc ip route add table "$DIGI_TABLE" 0.0.0.0/0 via "$PPPOE_PEER" "$DIGI_IF"
vc ip route add table "$DIGI_TABLE" 79.172.242.0/24 via ip4-lookup-in-table "$PD_TABLE"
vc ip route add table "$DIGI_TABLE" 79.172.242.2/32 via ip4-lookup-in-table "$PD_TABLE"

# NAT on tap81 → digi (not on loop10 BVI)
vc nat44 ei plugin enable sessions 131072 users 4096 inside-vrf "$DIGI_TABLE" outside-vrf 0
vc nat44 ei plugin enable
vc nat44 ei add address "$DIGI_IP"
vc set interface nat44 ei in "tap${TAP_B_ID}" out "$DIGI_IF" del
vc set interface nat44 ei in "tap${TAP_B_ID}" out "$DIGI_IF"
vc nat44 ei mss-clamping 1452

alive || { echo "digi-sticky: vpp died after NAT" >&2; exit 1; }

# ping hairpin
vc ping "$HAIRPIN_B" repeat 1

# classify
vc classify table mask l3 ip4 proto buckets 64 memory-size 2M
PROTO_IDX=$(vo show classify tables | awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/{print $1; exit}')
: "${PROTO_IDX:?proto idx}"

vc classify table mask l3 ip4 proto l4 src_port buckets 256 memory-size 8M next-table "$PROTO_IDX"
SPORT_IDX=$(vo show classify tables | awk '
  /^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/{idx=$1}
  /ffff000000000000000000000000$/{print idx; exit}
')
: "${SPORT_IDX:?sport idx}"

PROTO_MATCH="0000000000000000000000000000000000000000000000060000000000000000"
vc classify session table-index "$PROTO_IDX" match hex "$PROTO_MATCH" \
  action set-ip4-fib-id "$HAIRPIN_TABLE"

SERVICE_PORTS="$SERVICE_PORTS_BASE"
for p in $SERVICE_PORT_RANGES; do
  a="${p%-*}"; b="${p#*-}"
  while [ "$a" -le "$b" ]; do
    SERVICE_PORTS="$SERVICE_PORTS $a"
    a=$((a + 1))
  done
done

pad="00000000000000000000000000000000"
m1="00000000000000060000000000000000"
for port in $SERVICE_PORTS; do
  hp=$(printf '%04x' "$port")
  match="${pad}${m1}0000${hp}000000000000000000000000"
  vc classify session table-index "$SPORT_IDX" match hex "$match" \
    action set-ip4-fib-id "$PD_TABLE"
done

vc set interface input acl intfc loop10 ip4-table "$SPORT_IDX"

alive || { echo "digi-sticky: vpp died after classify" >&2; exit 1; }

if ! vo show interface features loop10 | grep -q ip4-inacl; then
  echo "digi-sticky: ip4-inacl missing" >&2
  exit 1
fi
if ! vo show interface features "tap${TAP_B_ID}" | grep -q nat44-ei-in2out; then
  echo "digi-sticky: NAT missing on tap${TAP_B_ID}" >&2
  exit 1
fi

# Confirm PD default untouched
if ! vo show ip fib table "$PD_TABLE" | grep -q loop208; then
  echo "digi-sticky: WARN table ${PD_TABLE} default not via loop208" >&2
fi

mkdir -p /etc/pd
nports=$(echo "$SERVICE_PORTS" | wc -w)
printf 'enabled=1\nmode=vpp-classify-hairpin\nproto_table=%s\nsport_table=%s\npd_table=%s\nhairpin_table=%s\ndigi_table=%s\ndigi_ip=%s\nports=%s\n' \
  "$PROTO_IDX" "$SPORT_IDX" "$PD_TABLE" "$HAIRPIN_TABLE" "$DIGI_TABLE" "$DIGI_IP" "$nports" \
  > /etc/pd/sticky-digi

echo "digi-sticky-outbound: OK hairpin; Digi SNAT ${DIGI_IP} via tap${TAP_B_ID}; ${nports} TCP sports→PD; UDP→PD; peer=${PPPOE_PEER}"
