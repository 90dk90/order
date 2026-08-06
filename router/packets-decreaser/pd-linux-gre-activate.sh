#!/bin/sh
# PD GRE on Linux (not VPP) — Proximus IPv4 primary underlay, Digi IPv6 backup.
# Behind Proximus NAT, raw GRE (proto 47) outbound is dropped by the box; use
# GRE-over-UDP (FOU) so the tunnel passes like normal UDP. Digi IPv6 keeps
# native ip6gre (no FOU).
# VPP = LAN only; table 81 exits via existing tap (default tap30/vpp6-host)
# → Linux → gre-pd → VPS. Do not create new taps on this box (past SIGSEGV).
set -eu
. /etc/pd/pd-gre.conf

PROX_IF="${PROX_IF:-enp36s0}"
# Reuse pre-existing VPP tap — never create unless PD_EXIT_TAP_CREATE=1
EXIT_TAP="${EXIT_TAP:-vpp6-host}"
EXIT_TAP_ID="${EXIT_TAP_ID:-30}"
EXIT_VPP_IP="${EXIT_VPP_IP:-10.254.207.1/30}"
EXIT_LINUX_IP="${EXIT_LINUX_IP:-10.254.207.2/30}"
EXIT_LINUX_PEER="${EXIT_LINUX_PEER:-10.254.207.1}"
INNER_LOCAL="${INNER_LOCAL:-172.16.207.2/30}"
INNER_PEER="${INNER_PEER:-172.16.207.1}"
PBR_TABLE="${PBR_TABLE:-81}"
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
# VPP CLI replies are CRLF — strip CR before parsing
vpp_out() { $VPP "$@" 2>/dev/null | tr -d "\r"; }
GRE_NAME="${GRE_NAME:-gre-pd}"
FOU_PORT="${FOU_PORT:-4754}"
# FOU MTU must leave room for UDP+FOU overhead
MTU="${GRE_MTU:-1400}"

is_v4() {
  case "$1" in
    *:* ) return 1 ;;
    * ) return 0 ;;
  esac
}
is_priv_v4() {
  case "$1" in
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|100.64.*|100.6[0-9].*|100.7[0-9].*|100.8[0-9].*|100.9[0-9].*|100.10[0-9].*|100.11[0-9].*|100.12[0-7].*) return 0 ;;
    *) return 1 ;;
  esac
}

# Prefer primary Proximus LAN address (first global inet). Dual-DHCP secondary
# (.42) breaks inbound demux: NAT delivers GRE/UDP to .7 only.
prox_local() {
  if [ -n "${PD_PROX_LOCAL:-}" ]; then
    printf '%s\n' "$PD_PROX_LOCAL"
    return 0
  fi
  ip -4 -o addr show dev "$PROX_IF" scope global 2>/dev/null | awk 'NR==1 {
    gsub(/\/.*/, "", $4); print $4; exit
  }'
}

pick_underlay() {
  digi6=$(ip -6 -o addr show ppp0 2>/dev/null | awk '/2a01:4700:807f:|2a01:4700:817f:/{gsub(/\/.*/,"",$4); print $4; exit}')
  prox4=$(prox_local)

  mode="${PD_UNDERLAY:-auto}"
  case "$mode" in
    digi)
      [ -n "$digi6" ] || { echo "pd-linux-gre: no Digi 807f/817f on ppp0"; return 1; }
      printf '%s\n' "$digi6"; return 0 ;;
    proximus|prox)
      [ -n "$prox4" ] || { echo "pd-linux-gre: no Proximus IPv4 on $PROX_IF"; return 1; }
      printf '%s\n' "$prox4"; return 0 ;;
  esac

  # auto: Proximus if we can reach VPS via it; else Digi IPv6
  if [ -n "$prox4" ] && ping -c 1 -W 2 77.90.4.48 >/dev/null 2>&1; then
    printf '%s\n' "$prox4"
    return 0
  fi
  if [ -n "$digi6" ]; then
    printf '%s\n' "$digi6"
    return 0
  fi
  echo "pd-linux-gre: no usable underlay (Proximus/Digi)" >&2
  return 1
}

ensure_exit_tap() {
  tap_if="tap${EXIT_TAP_ID}"
  # show interface pads names with spaces — never match ^tapN
  if ! vpp_out show interface | awk -v t="$tap_if" '$1==t{found=1} END{exit !found}'; then
    if [ "${PD_EXIT_TAP_CREATE:-0}" = 1 ]; then
      $VPP create tap id "$EXIT_TAP_ID" host-if-name "$EXIT_TAP" host-mtu-size 1500 \
        num-rx-queues 1 num-tx-queues 1 rx-ring-size 1024 tx-ring-size 1024 2>/dev/null || true
    else
      echo "pd-linux-gre: exit tap ${tap_if}/${EXIT_TAP} missing — refuse create (set PD_EXIT_TAP_CREATE=1 to override)" >&2
      return 1
    fi
  fi
  # Resolve host IF name from VPP (tap30 → vpp6-host)
  host_if=$(vpp_out show tap | awk -v id="$EXIT_TAP_ID" '
    $1=="Interface:" && $2==("tap" id) {want=1}
    want && /name "/ { gsub(/"/,"",$2); print $2; exit }
  ')
  [ -n "$host_if" ] && EXIT_TAP="$host_if"
  $VPP set interface state "$tap_if" up 2>/dev/null || true
  ip link set "$EXIT_TAP" up 2>/dev/null || true

  if ! $VPP show interface address "$tap_if" 2>/dev/null | grep -q "${EXIT_VPP_IP%/*}"; then
    $VPP set interface ip address del "$tap_if" all 2>/dev/null || true
    $VPP set interface ip address "$tap_if" "$EXIT_VPP_IP" 2>/dev/null || true
  fi
  ip addr replace "$EXIT_LINUX_IP" dev "$EXIT_TAP" 2>/dev/null || true
  ip link set "$EXIT_TAP" up 2>/dev/null || true
  sysctl -q -w "net.ipv4.conf.${EXIT_TAP}.rp_filter=0" 2>/dev/null || true

  linux_peer=${EXIT_LINUX_IP%/*}
  vpp_peer=${EXIT_VPP_IP%/*}
  tap_net=$(printf '%s\n' "$EXIT_VPP_IP" | awk -F'[./]' '{printf "%s.%s.%s.0/%s\n",$1,$2,$3,$5}')

  $VPP ip table add "$PBR_TABLE" 2>/dev/null || true
  $VPP ip route del table "$PBR_TABLE" 0.0.0.0/0 2>/dev/null || true
  $VPP ip route add table "$PBR_TABLE" 0.0.0.0/0 via "$linux_peer" "$tap_if" 2>/dev/null || true

  ip route replace 79.172.242.0/24 via "$vpp_peer" dev "$EXIT_TAP" 2>/dev/null || true

  # Detached leftover rule from old vpp-pd-exit name
  ip rule del iif vpp-pd-exit lookup 100 2>/dev/null || true
  ip rule del iif "$EXIT_TAP" lookup 100 2>/dev/null || true
  ip rule add iif "$EXIT_TAP" lookup 100 priority 100
  ip route replace default via "$INNER_PEER" dev "$GRE_NAME" table 100 2>/dev/null || true
  ip route replace "$tap_net" dev "$EXIT_TAP" table 100 2>/dev/null || true

  iptables -C FORWARD -i "$EXIT_TAP" -o "$GRE_NAME" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -i "$EXIT_TAP" -o "$GRE_NAME" -j ACCEPT
  iptables -C FORWARD -i "$GRE_NAME" -o "$EXIT_TAP" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -i "$GRE_NAME" -o "$EXIT_TAP" -j ACCEPT
}

ensure_fou_recv() {
  modprobe fou 2>/dev/null || true
  ip fou del port "$FOU_PORT" 2>/dev/null || true
  ip fou add port "$FOU_PORT" ipproto 47
  iptables -C INPUT -p udp --dport "$FOU_PORT" -s "$PD_VTEP_V4" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 1 -p udp --dport "$FOU_PORT" -s "$PD_VTEP_V4" -j ACCEPT
}

build_gre() {
  local_ip=$1
  remote_for_vps=$2
  use_fou=$3

  modprobe gre 2>/dev/null || true
  modprobe ip_gre 2>/dev/null || true
  modprobe ip6_gre 2>/dev/null || true

  ip link del "$GRE_NAME" 2>/dev/null || true
  ip -6 tunnel del "$GRE_NAME" 2>/dev/null || true
  ip tunnel del "$GRE_NAME" 2>/dev/null || true

  if is_v4 "$local_ip"; then
    if [ "$use_fou" = 1 ]; then
      ensure_fou_recv
      # ip link add (not ip tunnel) required for FOU encap attrs
      ip link add "$GRE_NAME" type gre local "$local_ip" remote "$PD_VTEP_V4" ttl 64 \
        encap fou encap-sport "$FOU_PORT" encap-dport "$FOU_PORT"
    else
      ip tunnel add "$GRE_NAME" mode gre local "$local_ip" remote "$PD_VTEP_V4" ttl 64
    fi
  else
    # Digi IPv6 underlay → VPS IPv6 VTEP (raw ip6gre)
    ip -6 tunnel add "$GRE_NAME" mode ip6gre local "$local_ip" remote "$PD_VTEP" ttl 64 encaplimit none
  fi
  ip addr replace "$INNER_LOCAL" dev "$GRE_NAME"
  ip link set "$GRE_NAME" mtu "$MTU" up
  sysctl -q -w net.ipv4.conf."$GRE_NAME".rp_filter=0 2>/dev/null || true

  printf '%s\n' "$local_ip" > /run/pd-vtep-live.txt
  printf 'SRC_VTEP=%s\nREMOTE_FOR_VPS=%s\nINNER_LOCAL=%s\nINNER_PEER=%s\nMODE=linux-gre\nGRE_FOU=%s\nFOU_PORT=%s\n' \
    "$local_ip" "$remote_for_vps" "$INNER_LOCAL" "$INNER_PEER" "$use_fou" "$FOU_PORT" \
    > /run/pd-gre-endpoint.env

  # Sync VPS remote + FOU mode
  ssh -i "$PD_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=12 \
    "$PD_VPS_SSH" "GRE_FOU=$use_fou FOU_PORT=$FOU_PORT /usr/local/sbin/pd-gre-set-vtep.sh $remote_for_vps" || \
    echo "pd-linux-gre: VPS sync failed (will retry)"
}

PD_VTEP_V4="${PD_VTEP_V4:-77.90.4.48}"

sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv4.conf.all.rp_filter=0
sysctl -q -w net.ipv4.conf.default.rp_filter=0

if [ -x /usr/local/sbin/pd-lan-prepare.sh ]; then
  /usr/local/sbin/pd-lan-prepare.sh >/dev/null || true
fi

# lan-prepare has crashed VPP under churn — wait before exit-tap checks
i=0
while [ "$i" -lt 15 ]; do
  if $VPP show version >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 1
done

LOCAL=$(pick_underlay) || exit 1
REMOTE_FOR_VPS=$LOCAL
USE_FOU=0
if is_v4 "$LOCAL" && is_priv_v4 "$LOCAL"; then
  PUB=$(curl -4 -s --max-time 4 ifconfig.me 2>/dev/null || true)
  if [ -n "$PUB" ]; then
    REMOTE_FOR_VPS=$PUB
  fi
  case "${PD_GRE_FOU:-auto}" in
    0|no|off|false) USE_FOU=0 ;;
    *) USE_FOU=1 ;;
  esac
  echo "pd-linux-gre: local=$LOCAL (private) VPS remote=$REMOTE_FOR_VPS fou=$USE_FOU port=$FOU_PORT"
elif is_v4 "$LOCAL"; then
  case "${PD_GRE_FOU:-0}" in
    1|yes|on|true) USE_FOU=1 ;;
    *) USE_FOU=0 ;;
  esac
fi

# Avoid tearing a healthy FOU GRE (VPS sync + link del flaps the path / stressed VPP).
gre_ok=0
if ip link show "$GRE_NAME" >/dev/null 2>&1 \
  && ip -d link show "$GRE_NAME" 2>/dev/null | grep -q "local $LOCAL" \
  && { [ "$USE_FOU" != 1 ] || ip -d link show "$GRE_NAME" 2>/dev/null | grep -q 'encap fou'; } \
  && ping -c 1 -W 2 "$INNER_PEER" >/dev/null 2>&1; then
  gre_ok=1
  echo "pd-linux-gre: keep existing gre-pd (inner ok)"
fi
if [ "$gre_ok" = 0 ]; then
  build_gre "$LOCAL" "$REMOTE_FOR_VPS" "$USE_FOU"
fi

EXIT_OK=0
if [ "${PD_ENABLE_EXIT_TAP:-1}" = 1 ]; then
  if ensure_exit_tap; then
    EXIT_OK=1
  else
    echo "pd-linux-gre: exit tap wire failed" >&2
  fi
fi

LAN_OK=0
if ping -c 1 -W 2 79.172.242.1 >/dev/null 2>&1; then
  LAN_OK=1
fi

if ping -c 2 -W 3 "$INNER_PEER" >/dev/null 2>&1; then
  echo "pd-linux-gre: READY local=$LOCAL vps_remote=$REMOTE_FOR_VPS fou=$USE_FOU inner_ok=1 exit=$EXIT_OK lan_gw=$LAN_OK"
else
  echo "pd-linux-gre: UP local=$LOCAL vps_remote=$REMOTE_FOR_VPS fou=$USE_FOU inner_ok=0 exit=$EXIT_OK lan_gw=$LAN_OK"
fi
