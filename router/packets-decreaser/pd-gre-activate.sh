#!/bin/sh
set -eu
. /etc/pd/pd-gre.conf
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
LAN_BD="${LAN_BD:-10}"

# Digi VTEP = pppoeclient "wan-ipv6 observed" (currently 807f/...).
# Do NOT use synthetic 2a01:4700:80ff:... that vpp-pppoe-native may also install —
# that prefix is outbound-ok but NOT inbound-reachable from the internet/PD.
pick_digi_vtep() {
  obs=$($VPP show pppoe client detail 2>/dev/null | sed -n 's/.*wan-ipv6 observed \([^ /]*\).*/\1/p' | tr -d '\r' | head -1)
  if [ -n "$obs" ]; then
    printf '%s\n' "$obs"
    return 0
  fi
  # Fallback: prefer 807f on digi, then any Digi 2a01:4700 except 80ff
  $VPP show interface addr digi 2>/dev/null | awk '
    /L3 2a01:4700:807f:/{gsub(/\/.*/,"",$2); print $2; exit}
  '
}

SRC=""
i=0
while [ $i -lt 90 ]; do
  if $VPP show version >/dev/null 2>&1; then
    SRC=$(pick_digi_vtep)
    [ -n "$SRC" ] && break
  fi
  i=$((i+1))
  sleep 2
done
[ -n "$SRC" ] || { echo "pd-gre: no Digi observed WAN IPv6 yet"; exit 1; }

OLD=$(cat /run/pd-vtep-live.txt 2>/dev/null || true)
printf '%s\n' "$SRC" > /run/pd-vtep-live.txt
printf 'SRC_VTEP=%s\nDST_VTEP=%s\nINNER_LOCAL=%s\nINNER_PEER=%s\nMODE=packets-decreaser\n' \
  "$SRC" "$PD_VTEP" "$INNER_LOCAL" "$INNER_PEER" > /run/pd-gre-endpoint.env

$VPP ip table add "$PBR_TABLE" 2>/dev/null || true
$VPP ip route del ::/0 2>/dev/null || true
$VPP ip route add ::/0 via fe80::1 digi 2>/dev/null || true
$VPP ip route del "$PD_VTEP/128" 2>/dev/null || true
$VPP ip route add "$PD_VTEP/128" via fe80::1 digi 2>/dev/null || true

$VPP create bridge-domain "$LAN_BD" 2>/dev/null || true
if ! $VPP show interface loop10 >/dev/null 2>&1; then
  $VPP create loopback interface instance 10 >/dev/null 2>&1 || true
fi
for iface in x520lan x520extra0 x520extra1; do
  $VPP set interface l2 bridge "$iface" "$LAN_BD" 2>/dev/null || true
  $VPP set interface state "$iface" up 2>/dev/null || true
done
# Ensure loop10 exists then attach as BVI (VPP 26.x)
if ! $VPP show interface loop10 >/dev/null 2>&1; then
  $VPP create loopback interface instance 10 2>/dev/null || true
fi
$VPP set interface l2 bridge loop10 "$LAN_BD" bvi 2>/dev/null || true
$VPP set interface state loop10 up 2>/dev/null || true

NEED_GRE=0
CUR_SRC=""
if ! $VPP show interface gre0 >/dev/null 2>&1; then
  NEED_GRE=1
else
  CUR_SRC=$($VPP show gre tunnel 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  $VPP show gre tunnel 2>/dev/null | grep -q "$PD_VTEP" || NEED_GRE=1
  [ -n "$CUR_SRC" ] && [ "$CUR_SRC" != "$SRC" ] && NEED_GRE=1
  [ -n "$OLD" ] && [ "$OLD" != "$SRC" ] && NEED_GRE=1
fi

if [ "$NEED_GRE" = 1 ]; then
  if [ -n "$CUR_SRC" ]; then
    $VPP create gre tunnel src "$CUR_SRC" dst "$PD_VTEP" del 2>/dev/null || true
  fi
  $VPP create gre tunnel src "$SRC" dst "$PD_VTEP" del 2>/dev/null || true
  $VPP create gre tunnel src "$SRC" dst "$PD_VTEP" instance 0 2>/dev/null || \
    $VPP create gre tunnel src "$SRC" dst "$PD_VTEP" 2>/dev/null || true
fi

$VPP set interface state gre0 up 2>/dev/null || true
$VPP set interface mtu packet 1448 gre0 2>/dev/null || true
$VPP set interface ip address del gre0 "$INNER_LOCAL" 2>/dev/null || true
$VPP set interface ip address gre0 "$INNER_LOCAL" 2>/dev/null || true
$VPP set interface tcp-mss-clamp gre0 ip4 disable ip6 disable 2>/dev/null || true
$VPP set interface l2-mss-clamp gre0 disable 2>/dev/null || true

$VPP set interface ip address del loop10 79.172.242.1/24 2>/dev/null || true
$VPP set interface ip table loop10 "$PBR_TABLE" 2>/dev/null || true
$VPP set interface ip address loop10 79.172.242.1/24 2>/dev/null || true
$VPP set interface state loop10 up 2>/dev/null || true
$VPP set interface tcp-mss-clamp loop10 ip4 disable ip6 disable 2>/dev/null || true
$VPP set interface l2-mss-clamp loop10 disable 2>/dev/null || true
$VPP set interface tcp-mss-clamp x520lan ip4 disable ip6 disable 2>/dev/null || true
$VPP set interface l2-mss-clamp x520lan disable 2>/dev/null || true

$VPP ip route del table "$PBR_TABLE" 0.0.0.0/0 2>/dev/null || true
$VPP ip route add table "$PBR_TABLE" 0.0.0.0/0 via "$INNER_PEER" gre0 2>/dev/null || true
$VPP ip route del 79.172.242.0/24 2>/dev/null || true
$VPP ip route add 79.172.242.0/24 via loop10 2>/dev/null || true
$VPP ip route del 79.172.242.2/32 2>/dev/null || true
$VPP ip route add 79.172.242.2/32 via 79.172.242.2 loop10 2>/dev/null || true
$VPP ip route del 79.172.242.1/32 2>/dev/null || true
$VPP ip route add 79.172.242.1/32 via ip4-lookup-in-table "$PBR_TABLE" 2>/dev/null || true

if [ "$OLD" != "$SRC" ] || [ "${PD_FORCE_SYNC:-0}" = 1 ]; then
  echo "pd-gre: syncing VTEP $SRC -> VPS"
  ssh -i "$PD_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=12 \
    "$PD_VPS_SSH" "/usr/local/sbin/pd-gre-set-vtep.sh $SRC" || echo "pd-gre: VPS sync failed (will retry via watchdog)"
else
  ssh -i "$PD_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 \
    "$PD_VPS_SSH" "/usr/local/sbin/pd-gre-to-digi.sh" >/dev/null 2>&1 || true
fi

# Hide Digi WAN VTEP / LAN IPv6 / ICMP leaks (idempotent)
if [ -x /usr/local/sbin/pd-gre-harden.sh ]; then
  /usr/local/sbin/pd-gre-harden.sh || echo "pd-gre: harden failed (non-fatal)"
fi

echo "pd-gre ready src=$SRC dst=$PD_VTEP"
