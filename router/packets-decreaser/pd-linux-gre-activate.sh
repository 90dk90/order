#!/bin/sh
# PD GRE on Linux (not VPP) — Proximus IPv4 primary underlay, Digi IPv6 backup.
# VPP keeps LAN only; table 81 exits via tap vpp-pd-exit → Linux → gre-pd → VPS.
set -eu
. /etc/pd/pd-gre.conf

PROX_IF="${PROX_IF:-enp36s0}"
EXIT_TAP="${EXIT_TAP:-vpp-pd-exit}"
EXIT_TAP_ID="${EXIT_TAP_ID:-40}"
EXIT_VPP_IP="${EXIT_VPP_IP:-10.254.207.1/30}"
EXIT_LINUX_IP="${EXIT_LINUX_IP:-10.254.207.2/30}"
EXIT_LINUX_PEER="${EXIT_LINUX_PEER:-10.254.207.1}"
INNER_LOCAL="${INNER_LOCAL:-172.16.207.2/30}"
INNER_PEER="${INNER_PEER:-172.16.207.1}"
PBR_TABLE="${PBR_TABLE:-81}"
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
GRE_NAME="${GRE_NAME:-gre-pd}"
MTU="${GRE_MTU:-1448}"

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

pick_underlay() {
  # 1) Prefer Digi global 807f/817f on ppp0 (backup when Proximus down)
  digi6=$(ip -6 -o addr show ppp0 2>/dev/null | awk '/2a01:4700:807f:|2a01:4700:817f:/{gsub(/\/.*/,"",$4); print $4; exit}')
  # 2) Proximus IPv4 path to VPS (primary)
  prox4=$(ip -4 route get 77.90.4.48 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  pub4=$(curl -4 -s --max-time 4 ifconfig.me 2>/dev/null || true)

  mode="${PD_UNDERLAY:-auto}"
  case "$mode" in
    digi)
      [ -n "$digi6" ] || { echo "pd-linux-gre: no Digi 807f/817f on ppp0"; return 1; }
      printf '%s\n' "$digi6"; return 0 ;;
    proximus|prox)
      [ -n "$prox4" ] || { echo "pd-linux-gre: no Proximus IPv4"; return 1; }
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
  if ! $VPP show interface 2>/dev/null | grep -q "^${EXIT_TAP_NAME:-tap${EXIT_TAP_ID}}\\|^tap${EXIT_TAP_ID}"; then
    if ! $VPP show interface 2>/dev/null | grep -q "^tap${EXIT_TAP_ID}"; then
      $VPP create tap id "$EXIT_TAP_ID" host-if-name "$EXIT_TAP" host-mtu-size 1500 \
        num-rx-queues 2 num-tx-queues 2 rx-ring-size 1024 tx-ring-size 1024 2>/dev/null || true
    fi
  fi
  $VPP set interface state "tap${EXIT_TAP_ID}" up 2>/dev/null || true
  # Prefer named host IF
  ip link set "$EXIT_TAP" up 2>/dev/null || true

  # Address on VPP tap
  if ! $VPP show interface address "tap${EXIT_TAP_ID}" 2>/dev/null | grep -q "${EXIT_VPP_IP%/*}"; then
    $VPP set interface ip address "tap${EXIT_TAP_ID}" "$EXIT_VPP_IP" 2>/dev/null || true
  fi
  # Linux side
  ip addr replace "$EXIT_LINUX_IP" dev "$EXIT_TAP" 2>/dev/null || true
  ip link set "$EXIT_TAP" up 2>/dev/null || true

  linux_peer=${EXIT_LINUX_IP%/*}
  vpp_peer=${EXIT_VPP_IP%/*}

  # LAN egress via Linux
  $VPP ip table add "$PBR_TABLE" 2>/dev/null || true
  $VPP ip route del table "$PBR_TABLE" 0.0.0.0/0 2>/dev/null || true
  $VPP ip route add table "$PBR_TABLE" 0.0.0.0/0 via "$linux_peer" "tap${EXIT_TAP_ID}" 2>/dev/null || true

  # Return path LAN via VPP
  ip route replace 79.172.242.0/24 via "$vpp_peer" dev "$EXIT_TAP" 2>/dev/null || true

  # Policy: traffic from VPP exit → GRE (do not steal host default/Proximus/Tailscale)
  ip rule del iif "$EXIT_TAP" lookup 100 2>/dev/null || true
  ip rule add iif "$EXIT_TAP" lookup 100 priority 100
  ip route replace default via "$INNER_PEER" dev "$GRE_NAME" table 100 2>/dev/null || true
  ip route replace "${vpp_peer}/30" dev "$EXIT_TAP" table 100 2>/dev/null || true
}

build_gre() {
  local_ip=$1
  remote_for_vps=$2

  modprobe gre 2>/dev/null || true
  modprobe ip_gre 2>/dev/null || true
  modprobe ip6_gre 2>/dev/null || true

  ip link del "$GRE_NAME" 2>/dev/null || true
  ip -6 tunnel del "$GRE_NAME" 2>/dev/null || true
  ip tunnel del "$GRE_NAME" 2>/dev/null || true

  if is_v4 "$local_ip"; then
    ip tunnel add "$GRE_NAME" mode gre local "$local_ip" remote "$PD_VTEP_V4" ttl 64
  else
    # Digi IPv6 underlay → VPS IPv6 VTEP
    ip -6 tunnel add "$GRE_NAME" mode ip6gre local "$local_ip" remote "$PD_VTEP" ttl 64 encaplimit none
  fi
  ip addr replace "$INNER_LOCAL" dev "$GRE_NAME"
  ip link set "$GRE_NAME" mtu "$MTU" up
  sysctl -q -w net.ipv4.conf."$GRE_NAME".rp_filter=0 2>/dev/null || true

  printf '%s\n' "$local_ip" > /run/pd-vtep-live.txt
  printf 'SRC_VTEP=%s\nREMOTE_FOR_VPS=%s\nINNER_LOCAL=%s\nINNER_PEER=%s\nMODE=linux-gre\n' \
    "$local_ip" "$remote_for_vps" "$INNER_LOCAL" "$INNER_PEER" > /run/pd-gre-endpoint.env

  # Sync VPS remote to what it must dial back to
  ssh -i "$PD_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=12 \
    "$PD_VPS_SSH" "/usr/local/sbin/pd-gre-set-vtep.sh $remote_for_vps" || \
    echo "pd-linux-gre: VPS sync failed (will retry)"
}

# PD VPS IPv4 endpoint for GRE when underlay is Proximus
PD_VTEP_V4="${PD_VTEP_V4:-77.90.4.48}"

sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv4.conf.all.rp_filter=0
sysctl -q -w net.ipv4.conf.default.rp_filter=0

if [ -x /usr/local/sbin/pd-lan-prepare.sh ]; then
  /usr/local/sbin/pd-lan-prepare.sh >/dev/null || true
fi

LOCAL=$(pick_underlay) || exit 1
REMOTE_FOR_VPS=$LOCAL
if is_v4 "$LOCAL" && is_priv_v4 "$LOCAL"; then
  # Behind Proximus NAT: VPS must target the public IP Digi box NATs as
  PUB=$(curl -4 -s --max-time 4 ifconfig.me 2>/dev/null || true)
  if [ -n "$PUB" ]; then
    REMOTE_FOR_VPS=$PUB
    echo "pd-linux-gre: local=$LOCAL (private) VPS remote=$PUB — enable Proximus hôte ponté if inbound GRE fails"
  fi
fi

build_gre "$LOCAL" "$REMOTE_FOR_VPS"

# VPP exit tap is optional: creating taps has crashed this VPP under load.
# Enable with PD_ENABLE_EXIT_TAP=1 once VPP is stable.
if [ "${PD_ENABLE_EXIT_TAP:-0}" = 1 ]; then
  ensure_exit_tap
  iptables -C FORWARD -i "$EXIT_TAP" -o "$GRE_NAME" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD -i "$EXIT_TAP" -o "$GRE_NAME" -j ACCEPT
  iptables -C FORWARD -i "$GRE_NAME" -o "$EXIT_TAP" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD -i "$GRE_NAME" -o "$EXIT_TAP" -j ACCEPT
fi

# Sanity: inner peer
if ping -c 2 -W 3 "$INNER_PEER" >/dev/null 2>&1; then
  echo "pd-linux-gre: READY local=$LOCAL vps_remote=$REMOTE_FOR_VPS inner_ok=1"
else
  echo "pd-linux-gre: UP local=$LOCAL vps_remote=$REMOTE_FOR_VPS inner_ok=0 (check Proximus hôte ponté for GRE inbound)"
fi
