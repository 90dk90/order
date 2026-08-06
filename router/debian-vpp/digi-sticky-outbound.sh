#!/bin/bash
# Digi sticky outbound — hairpin + classify + user whitelist exceptions.
# Opt-in: PD_ENABLE_STICKY=1 OR --force
# Reload exceptions only: --reload-except
#
# Default: TCP sport >= 32768 → Digi SNAT; else PD.
# Whitelist /etc/pd/digi-sticky-except.conf → force PD:
#   src <ip> | dst <ip> | domain <fqdn>
set -euo pipefail

if [ "${PD_ENABLE_STICKY:-0}" != 1 ] && [ "${1:-}" != "--force" ] && [ "${1:-}" != "--reload-except" ]; then
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

EXCEPT_CONF="${EXCEPT_CONF:-/etc/pd/digi-sticky-except.conf}"
EXCEPT_STATE="${EXCEPT_STATE:-/etc/pd/digi-sticky-except.state}"
STICKY_STATE="${STICKY_STATE:-/etc/pd/sticky-digi}"

PAD16="00000000000000000000000000000000"

alive() { vo show version | grep -q vpp; }
classify_indices() {
  vo show classify tables | awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/{print $1}'
}
new_classify_idx() {
  local before="$1" idx
  for idx in $(classify_indices); do
    case " $before " in *" $idx "*) ;; *) echo "$idx"; return 0 ;; esac
  done
  return 1
}
ip_to_hex() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  printf '%02x%02x%02x%02x' "$a" "$b" "$c" "$d"
}

ensure_except_conf() {
  if [ ! -f "$EXCEPT_CONF" ]; then
    mkdir -p "$(dirname "$EXCEPT_CONF")"
    cat >"$EXCEPT_CONF" <<'EOF'
# Digi sticky exceptions — stay on PD (/24), never Digi SNAT.
# Reload: /usr/local/sbin/digi-sticky-except-reload.sh
#
# src <ipv4>     FROM this IP → PD
# dst <ipv4>     TO this IP → PD
# domain <fqdn>  resolve A → dst (refreshed on reload)

domain api.lumenvm.cloud
src 79.172.242.3
src 79.172.242.10
EOF
  fi
}

parse_except() {
  SRC_LIST=""
  DST_LIST=""
  local kind val ips ip
  [ -f "$EXCEPT_CONF" ] || return 0
  while read -r kind val _; do
    case "$kind" in
      \#*|"") continue ;;
      src) case "$val" in *.*.*.*) SRC_LIST="$SRC_LIST $val" ;; esac ;;
      dst) case "$val" in *.*.*.*) DST_LIST="$DST_LIST $val" ;; esac ;;
      domain)
        [ -n "${val:-}" ] || continue
        ips=$(getent ahostsv4 "$val" 2>/dev/null | awk '{print $1}' | sort -u)
        [ -z "$ips" ] && ips=$(dig +short A "$val" 2>/dev/null | grep -E '^[0-9.]+$' | sort -u || true)
        for ip in $ips; do DST_LIST="$DST_LIST $ip"; done
        ;;
    esac
  done <"$EXCEPT_CONF"
  SRC_LIST=$(echo "$SRC_LIST" | tr ' ' '\n' | awk 'NF && !s[$0]++' | tr '\n' ' ')
  DST_LIST=$(echo "$DST_LIST" | tr ' ' '\n' | awk 'NF && !s[$0]++' | tr '\n' ' ')
}

detach_classify() {
  local old
  old=$(sed -n 's/^attach_table=//p' "$STICKY_STATE" 2>/dev/null | head -1 || true)
  [ -z "$old" ] && old=$(sed -n 's/^sport_table=//p' "$STICKY_STATE" 2>/dev/null | head -1 || true)
  [ -n "${old:-}" ] && vc set interface input acl intfc loop10 ip4-table "$old" del
  vc set interface input acl intfc loop10 ip4-table 0 del
}

# Build chain: [src except →] [dst except →] ephemeral→Digi
# Prints attach table index.
install_classify_chain() {
  parse_except
  local before eph_idx dst_idx src_idx next hx ip m1 m2

  before=$(classify_indices | tr '\n' ' ')
  # Ephemeral: TCP sport & 0x8000 → hairpin/Digi
  vc classify table mask hex 00000000000000ff000000000000000000008000000000000000000000000000 \
    buckets 64 skip 1 match 2 memory-size 2M
  eph_idx=$(new_classify_idx "$before")
  : "${eph_idx:?eph table}"
  vc classify session table-index "$eph_idx" match hex \
    "${PAD16}0000000000000006000000000000000000008000000000000000000000000000" \
    action set-ip4-fib-id "$HAIRPIN_TABLE"
  next=$eph_idx

  dst_idx=""
  if [ -n "$(echo "$DST_LIST" | tr -d ' ')" ]; then
    before=$(classify_indices | tr '\n' ' ')
    # mask l3 ip4 dst → skip1 match2, IP at match offset 14
    vc classify table mask l3 ip4 dst buckets 64 memory-size 2M next-table "$next"
    dst_idx=$(new_classify_idx "$before")
    : "${dst_idx:?dst table}"
    for ip in $DST_LIST; do
      hx=$(ip_to_hex "$ip")
      # 14 zero bytes + IPv4 + 14 zero bytes (32B match) after PAD16
      m1="0000000000000000000000000000${hx:0:4}"
      m2="${hx:4:4}0000000000000000000000000000"
      vc classify session table-index "$dst_idx" match hex "${PAD16}${m1}${m2}" \
        action set-ip4-fib-id "$PD_TABLE"
    done
    next=$dst_idx
  fi

  src_idx=""
  if [ -n "$(echo "$SRC_LIST" | tr -d ' ')" ]; then
    before=$(classify_indices | tr '\n' ' ')
    # mask l3 ip4 src → skip1 match1, IP at match offset 10
    vc classify table mask l3 ip4 src buckets 64 memory-size 2M next-table "$next"
    src_idx=$(new_classify_idx "$before")
    : "${src_idx:?src table}"
    for ip in $SRC_LIST; do
      hx=$(ip_to_hex "$ip")
      m1="00000000000000000000${hx}0000"
      vc classify session table-index "$src_idx" match hex "${PAD16}${m1}" \
        action set-ip4-fib-id "$PD_TABLE"
    done
    next=$src_idx
  fi

  vc set interface input acl intfc loop10 ip4-table "$next"

  mkdir -p /etc/pd
  {
    echo "src_list=$SRC_LIST"
    echo "dst_list=$DST_LIST"
    echo "src_table=${src_idx}"
    echo "dst_table=${dst_idx}"
    echo "eph_table=$eph_idx"
    echo "attach_table=$next"
  } >"$EXCEPT_STATE"
  echo "$next"
}

RELOAD_ONLY=0
[ "${1:-}" = "--reload-except" ] && RELOAD_ONLY=1
ensure_except_conf

if [ "$RELOAD_ONLY" = 1 ]; then
  alive || { echo "digi-sticky: vpp down" >&2; exit 1; }
  [ -f "$STICKY_STATE" ] || { echo "digi-sticky: not enabled — run with --force first" >&2; exit 1; }
  detach_classify
  ATTACH=$(install_classify_chain)
  grep -vE '^(attach_table|sport_table|src_table|dst_table|eph_table|src_list|dst_list)=' "$STICKY_STATE" \
    >"${STICKY_STATE}.tmp" || true
  cat "$EXCEPT_STATE" >>"${STICKY_STATE}.tmp"
  echo "attach_table=$ATTACH" >>"${STICKY_STATE}.tmp"
  echo "sport_table=$ATTACH" >>"${STICKY_STATE}.tmp"
  mv "${STICKY_STATE}.tmp" "$STICKY_STATE"
  vo show interface features loop10 | grep -q ip4-inacl || { echo "reload failed" >&2; exit 1; }
  echo "digi-sticky-except-reload: OK attach=$ATTACH"
  echo "  src=[$(sed -n 's/^src_list=//p' "$EXCEPT_STATE")]"
  echo "  dst=[$(sed -n 's/^dst_list=//p' "$EXCEPT_STATE")]"
  exit 0
fi

# ---- full enable ----
PPPOE_PEER="${PPPOE_PEER:-}"
[ -z "$PPPOE_PEER" ] && PPPOE_PEER=$(vo show pppoe client detail \
  | sed -n 's/.*ipv4 local [0-9.]* peer \([0-9.]*\).*/\1/p' | head -1)
: "${PPPOE_PEER:?pppoe peer missing}"
DIGI_IP=$(vo show interface address "$DIGI_IF" \
  | awk '/L3 [0-9]+\./{gsub(/\/.*/,"",$2); print $2; exit}')
: "${DIGI_IP:?digi IPv4 missing}"
alive || { echo "digi-sticky: vpp down" >&2; exit 1; }

detach_classify
vc set interface nat44 ei in loop10 out "$DIGI_IF" output-feature del
vc set interface nat44 ei in loop10 out "$DIGI_IF" del

ensure_tap() {
  local id="$1" host="$2" i
  if ! vo show interface | grep -q "tap${id}"; then
    vc create tap id "$id" host-if-name "$host" host-mtu-size 1500 \
      num-rx-queues 2 num-tx-queues 2 rx-ring-size 1024 tx-ring-size 1024
  fi
  for i in $(seq 1 50); do
    ip link show "$host" &>/dev/null && return 0
    sleep 0.1
  done
  echo "digi-sticky: host tap $host missing" >&2
  return 1
}

ensure_tap "$TAP_A_ID" "$TAP_A_HOST"
ensure_tap "$TAP_B_ID" "$TAP_B_HOST"
alive || { echo "digi-sticky: died after tap" >&2; exit 1; }
vc set interface state "tap${TAP_A_ID}" up
vc set interface state "tap${TAP_B_ID}" up

if ! ip link show "$WIRE_BR" &>/dev/null; then ip link add "$WIRE_BR" type bridge; fi
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

vc ip table add "$HAIRPIN_TABLE"
vc ip table add "$DIGI_TABLE"
vc set interface ip address del "tap${TAP_A_ID}" all
vc set interface ip address "tap${TAP_A_ID}" "${HAIRPIN_A}/30"
vc ip route add table "$HAIRPIN_TABLE" 0.0.0.0/0 via "$HAIRPIN_B" "tap${TAP_A_ID}"
vc ip route add table "$HAIRPIN_TABLE" 79.172.242.0/24 via ip4-lookup-in-table "$PD_TABLE"
vc ip route add table "$HAIRPIN_TABLE" 79.172.242.2/32 via ip4-lookup-in-table "$PD_TABLE"
vc set interface ip address del "tap${TAP_B_ID}" all
vc set interface ip table "tap${TAP_B_ID}" "$DIGI_TABLE"
vc set interface ip address "tap${TAP_B_ID}" "${HAIRPIN_B}/30"
MAC_A=$(vo show hardware-interfaces "tap${TAP_A_ID}" | awk '/Ethernet address/{print $3; exit}')
MAC_B=$(vo show hardware-interfaces "tap${TAP_B_ID}" | awk '/Ethernet address/{print $3; exit}')
vc set ip neighbor "tap${TAP_A_ID}" "$HAIRPIN_B" "$MAC_B" static
vc set ip neighbor "tap${TAP_B_ID}" "$HAIRPIN_A" "$MAC_A" static
vc ip route add table "$DIGI_TABLE" 0.0.0.0/0 via "$PPPOE_PEER" "$DIGI_IF"
vc ip route add table "$DIGI_TABLE" 79.172.242.0/24 via ip4-lookup-in-table "$PD_TABLE"
vc ip route add table "$DIGI_TABLE" 79.172.242.2/32 via ip4-lookup-in-table "$PD_TABLE"

vc nat44 ei plugin enable sessions 131072 users 4096 inside-vrf "$DIGI_TABLE" outside-vrf 0
vc nat44 ei plugin enable
vc nat44 ei add address "$DIGI_IP"
vc set interface nat44 ei in "tap${TAP_B_ID}" out "$DIGI_IF" del
vc set interface nat44 ei in "tap${TAP_B_ID}" out "$DIGI_IF"
vc nat44 ei mss-clamping 1452
vc ping "$HAIRPIN_B" repeat 1

ATTACH=$(install_classify_chain)
alive || { echo "digi-sticky: died after classify" >&2; exit 1; }
vo show interface features loop10 | grep -q ip4-inacl || { echo "inacl missing" >&2; exit 1; }
vo show interface features "tap${TAP_B_ID}" | grep -q nat44-ei-in2out || { echo "NAT missing" >&2; exit 1; }

{
  echo "enabled=1"
  echo "mode=vpp-classify-ephemeral+except"
  echo "digi_ip=$DIGI_IP"
  echo "pd_table=$PD_TABLE"
  echo "hairpin_table=$HAIRPIN_TABLE"
  echo "digi_table=$DIGI_TABLE"
  echo "except_conf=$EXCEPT_CONF"
  echo "attach_table=$ATTACH"
  echo "sport_table=$ATTACH"
  cat "$EXCEPT_STATE"
} >"$STICKY_STATE"

echo "digi-sticky-outbound: OK Digi=${DIGI_IP} attach=$ATTACH except=$EXCEPT_CONF"
echo "  whitelist: edit $EXCEPT_CONF && digi-sticky-except-reload.sh"
