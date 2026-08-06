#!/bin/bash
# Digi Linux-PPPoE mode: Linux VXLAN underlay + VPP table-81 hairpin via tap30.
#
# Why not VPP VXLAN here:
#   Digi GUA lives on Linux ppp0 (pppd). VPP cannot source VXLAN from that
#   address without a fragile GUA inject + inbound redirect. VPS already peers
#   with classic Linux VXLAN — match that on Digi while WAN is Linux PPPoE.
#
# Safety:
#   - Never af_packet / host-interface on enp36s0
#   - Never restart VPP or PPPoE
#   - Reuse existing tap30/vpp6-host (do not create new taps by default)
set -eu
. /etc/pd/pd-vxlan-lab.conf 2>/dev/null || . "$(dirname "$0")/pd-vxlan-lab.conf"
. /etc/default/vpp-pppoe-mode 2>/dev/null || true

VPP="${VPP:-/usr/bin/vppctl}"
# VPP CLI replies are CRLF — strip CR before parsing
vpp_out() { $VPP "$@" 2>/dev/null | tr -d '\r'; }
PBR_TABLE="${PBR_TABLE:-81}"
VXLAN_VNI="${VXLAN_VNI:-100}"
VXLAN_PORT="${VXLAN_PORT:-4789}"
VXLAN_MTU="${VXLAN_MTU:-1400}"
LAB_DIGI="${LAB_DIGI:-172.16.208.2}"
LAB_VPS="${LAB_VPS:-172.16.208.1}"
LAB_DIGI_MAC="${LAB_DIGI_MAC:-de:ad:00:00:00:d1}"
LAB_VPS_MAC="${LAB_VPS_MAC:-de:ad:00:00:00:d2}"
DST="${PD_VTEP:-2a0e:97c0:4c1::60}"
IFACE="${DIGI_LINUX_VXLAN_IF:-vxlan-digi}"
RT_TABLE="${DIGI_LINUX_VXLAN_RT:-209}"
LAN_PREFIX="${LAN_PREFIX:-79.172.242.0/24}"
EXIT_TAP="${EXIT_TAP:-vpp6-host}"
EXIT_TAP_ID="${EXIT_TAP_ID:-30}"
EXIT_VPP_IP="${EXIT_VPP_IP:-10.254.207.1/30}"
EXIT_LINUX_IP="${EXIT_LINUX_IP:-10.254.207.2/30}"
INST="${DIGI_VXLAN_INSTANCE:-209}"

pick_src() {
  if [ -n "${DIGI_VTEP:-}" ]; then
    printf '%s\n' "$DIGI_VTEP"
    return 0
  fi
  if [ -f /run/pd-digi-vtep.txt ]; then
    tr -d ' \r\n' </run/pd-digi-vtep.txt
    return 0
  fi
  if [ -f /run/pd-vxlan-digi-vtep.txt ]; then
    tr -d ' \r\n' </run/pd-vxlan-digi-vtep.txt
    return 0
  fi
  ip -6 -o addr show dev ppp0 scope global 2>/dev/null | awk '
    /2a01:4700:(807f|817f|80ff):ffff:/{
      gsub(/\/.*/, "", $4); print $4; exit
    }'
}

SRC=$(pick_src)
SRC=${SRC%%/*}
[ -n "$SRC" ] || {
  echo "pd-linux-vxlan-digi: no Digi GUA on ppp0 /run/pd-digi-vtep.txt" >&2
  exit 1
}

$VPP show version >/dev/null

# Softpath reachability check (Digi GUA → VPS)
if ! ping -6 -c1 -W3 -I "$SRC" "$DST" >/dev/null 2>&1; then
  echo "pd-linux-vxlan-digi: Digi GUA $SRC cannot reach $DST yet" >&2
  exit 1
fi

modprobe vxlan
ip6tables -C INPUT -p udp --dport "$VXLAN_PORT" -j ACCEPT 2>/dev/null || \
  ip6tables -I INPUT 1 -p udp --dport "$VXLAN_PORT" -j ACCEPT

# Recreate only when local/remote/vni drift
need_rebuild=1
if ip link show "$IFACE" >/dev/null 2>&1; then
  cur=$(ip -d link show "$IFACE" 2>/dev/null || true)
  echo "$cur" | grep -q "remote $DST" \
    && echo "$cur" | grep -q "local $SRC" \
    && echo "$cur" | grep -q "id $VXLAN_VNI" \
    && need_rebuild=0 || true
fi
if [ "$need_rebuild" = 1 ]; then
  ip link del "$IFACE" 2>/dev/null || true
  ip link add "$IFACE" type vxlan id "$VXLAN_VNI" \
    local "$SRC" remote "$DST" dstport "$VXLAN_PORT" \
    nolearning ttl 64 udp6zerocsumtx udp6zerocsumrx
fi
ip link set "$IFACE" address "$LAB_DIGI_MAC"
ip addr replace "${LAB_DIGI}/30" dev "$IFACE"
ip link set "$IFACE" mtu "$VXLAN_MTU" up
ip neigh replace "$LAB_VPS" lladdr "$LAB_VPS_MAC" nud permanent dev "$IFACE"

# Reuse tap30/vpp6-host — never create unless explicitly allowed
tap_if="tap${EXIT_TAP_ID}"
if ! vpp_out show interface | awk -v t="$tap_if" '$1==t{f=1} END{exit !f}'; then
  if [ "${PD_EXIT_TAP_CREATE:-0}" = "1" ]; then
    $VPP create tap id "$EXIT_TAP_ID" host-if-name "$EXIT_TAP" host-mtu-size 1500 \
      num-rx-queues 1 num-tx-queues 1 rx-ring-size 1024 tx-ring-size 1024
  else
    echo "pd-linux-vxlan-digi: missing $tap_if/$EXIT_TAP (set PD_EXIT_TAP_CREATE=1 to create)" >&2
    exit 1
  fi
fi
host_if=$(vpp_out show tap | awk -v id="$EXIT_TAP_ID" '
  $1=="Interface:" && $2==("tap" id) {want=1}
  want && /name "/ { gsub(/"/,"",$2); print $2; exit }
')
[ -n "$host_if" ] && EXIT_TAP="$host_if"

$VPP set interface state "$tap_if" up 2>/dev/null || true
ip link set "$EXIT_TAP" up 2>/dev/null || true
if ! vpp_out show interface addr "$tap_if" | grep -q "${EXIT_VPP_IP%/*}"; then
  $VPP set interface ip address del "$tap_if" all 2>/dev/null || true
  $VPP set interface ip address "$tap_if" "$EXIT_VPP_IP" 2>/dev/null || true
fi
ip addr replace "$EXIT_LINUX_IP" dev "$EXIT_TAP" 2>/dev/null || true

linux_peer=${EXIT_LINUX_IP%/*}
vpp_peer=${EXIT_VPP_IP%/*}
HOST_MAC=$(ip -o link show "$EXIT_TAP" 2>/dev/null | awk '{print $17}')
VPP_MAC=$(vpp_out show hardware-interfaces "$tap_if" | awk '/Ethernet address/{print $3; exit}')
[ -n "$HOST_MAC" ] && $VPP set ip neighbor "$tap_if" "$linux_peer" "$HOST_MAC" static 2>/dev/null || true
[ -n "$VPP_MAC" ] && ip neigh replace "$vpp_peer" lladdr "$VPP_MAC" nud permanent dev "$EXIT_TAP"

# Table 81 → Linux → VXLAN (replace SNAT/tap50 or stale loop208 default)
$VPP ip table add "$PBR_TABLE" 2>/dev/null || true
$VPP ip route del table "$PBR_TABLE" 0.0.0.0/0 2>/dev/null || true
$VPP ip route add table "$PBR_TABLE" 0.0.0.0/0 via "$linux_peer" "$tap_if"

sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv4.conf.all.rp_filter=0
sysctl -q -w "net.ipv4.conf.${IFACE}.rp_filter=0" 2>/dev/null || true
sysctl -q -w "net.ipv4.conf.${EXIT_TAP}.rp_filter=0" 2>/dev/null || true

ip route replace default via "$LAB_VPS" dev "$IFACE" table "$RT_TABLE"
ip route replace "$LAN_PREFIX" via "$vpp_peer" dev "$EXIT_TAP"
ip route replace "${EXIT_VPP_IP%/*}/30" dev "$EXIT_TAP" table "$RT_TABLE" 2>/dev/null || true
ip rule del from "$LAN_PREFIX" table "$RT_TABLE" 2>/dev/null || true
ip rule add from "$LAN_PREFIX" table "$RT_TABLE" priority 90
ip rule del iif "$EXIT_TAP" table "$RT_TABLE" 2>/dev/null || true
ip rule add iif "$EXIT_TAP" table "$RT_TABLE" priority 100

iptables -C FORWARD -i "$IFACE" -o "$EXIT_TAP" -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD 1 -i "$IFACE" -o "$EXIT_TAP" -j ACCEPT
iptables -C FORWARD -i "$EXIT_TAP" -o "$IFACE" -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD 1 -i "$EXIT_TAP" -o "$IFACE" -j ACCEPT

# Tear VPP Digi VXLAN for this VNI — Linux owns the underlay in this mode
while read -r old_src old_dst old_inst; do
  [ -n "$old_src" ] || continue
  echo "pd-linux-vxlan-digi: deleting VPP vxlan inst=${old_inst:-$INST} src=$old_src (linux owns underlay)"
  $VPP create vxlan tunnel src "$old_src" dst "${old_dst:-$DST}" vni "$VXLAN_VNI" \
    instance "${old_inst:-$INST}" del 2>/dev/null || true
done <<EOF
$(vpp_out show vxlan tunnel | awk -v v="$VXLAN_VNI" '
  $0 ~ ("vni " v) {
    src=""; dst=""; inst="";
    for (i=1;i<=NF;i++) {
      if ($i=="src") src=$(i+1);
      if ($i=="dst") dst=$(i+1);
      if ($i=="instance") inst=$(i+1);
    }
    if (src!="") print src, dst, inst;
  }')
EOF

printf '%s\n' "$SRC" >/run/pd-digi-vtep.txt
printf '%s\n' "$SRC" >/run/pd-vxlan-digi-vtep.txt

cat >/etc/default/pd-underlay <<EOF
# Digi Linux-PPPoE + Linux VXLAN underlay (VPP owns LAN/PBR only)
PD_UNDERLAY=digi-linux-vxlan
PD_TRANSPORT=vxlan
PD_GRE=0
PD_PPPOE=1
VPP_PPPOE_MODE=linux
DIGI_VTEP=$SRC
DIGI_LINUX_VXLAN_IF=$IFACE
DIGI_VXLAN_INSTANCE=$INST
PD_ALLOW_VPP_RESTART=0
PD_ALLOW_PPPOE_RESTART=0
EOF

# Best-effort VPS peer refresh
if [ -r /root/.ssh/id_ed25519_pd_vps ]; then
  ssh -i /root/.ssh/id_ed25519_pd_vps -o BatchMode=yes -o ConnectTimeout=8 \
    root@77.90.4.48 "DIGI_VTEP=$SRC /usr/local/sbin/pd-vpp-digi-vxlan-vps.sh" \
    >/tmp/pd-linux-vxlan-vps.out 2>&1 || \
    echo "pd-linux-vxlan-digi: VPS sync failed (will retry) — see /tmp/pd-linux-vxlan-vps.out"
fi

echo "pd-linux-vxlan-digi: READY if=$IFACE src=$SRC dst=$DST inner=${LAB_DIGI}/30 via $EXIT_TAP"
ping -c 2 -W 2 "$LAB_VPS" 2>&1 | tail -5 || true
$VPP ping "$LAB_VPS" source loop10 table-id "$PBR_TABLE" repeat 2 2>&1 | tail -6 || true
