#!/bin/sh
set -eu
. /etc/pd/pd-gre.conf
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"

# Wait for digi + IPv6
SRC=""
i=0
while [ $i -lt 90 ]; do
  if $VPP show version >/dev/null 2>&1; then
    SRC=$($VPP show interface addr digi 2>/dev/null | awk '/L3 2a01:/{gsub(/\/.*/,"",$2); print $2; exit}')
    [ -n "$SRC" ] && break
  fi
  i=$((i+1))
  sleep 2
done
[ -n "$SRC" ] || { echo "pd-gre: no Digi IPv6 yet"; exit 1; }

OLD=$(cat /run/pd-vtep-live.txt 2>/dev/null || true)
printf '%s\n' "$SRC" > /run/infrawire-vtep.txt
printf '%s\n' "$SRC" > /run/pd-vtep-live.txt
printf 'SRC_VTEP=%s\nDST_VTEP=%s\nINNER_LOCAL=%s\nINNER_PEER=%s\nMODE=packets-decreaser\n' \
  "$SRC" "$PD_VTEP" "$INNER_LOCAL" "$INNER_PEER" > /run/pd-gre-endpoint.env

# Keep Infrawire down
birdc disable ebgp_as210699 >/dev/null 2>&1 || true

$VPP ip table add "$PBR_TABLE" 2>/dev/null || true
$VPP ip route del ::/0 2>/dev/null || true
$VPP ip route add ::/0 via fe80::1 digi 2>/dev/null || true
$VPP ip route del "$PD_VTEP/128" 2>/dev/null || true
$VPP ip route add "$PD_VTEP/128" via fe80::1 digi 2>/dev/null || true

# Recreate GRE if peer/src changed or missing
NEED_GRE=0
if ! $VPP show interface gre0 >/dev/null 2>&1; then
  NEED_GRE=1
elif ! $VPP show gre tunnel 2>/dev/null | grep -q "$PD_VTEP"; then
  NEED_GRE=1
elif [ -n "$OLD" ] && [ "$OLD" != "$SRC" ]; then
  NEED_GRE=1
fi

if [ "$NEED_GRE" = 1 ]; then
  # Best-effort delete old
  $VPP delete gre tunnel gre0 2>/dev/null || true
  $VPP create gre tunnel src "$SRC" dst "$PD_VTEP" instance 0 2>/dev/null || \
    $VPP create gre tunnel src "$SRC" dst "$PD_VTEP" 2>/dev/null || true
fi
$VPP set interface state gre0 up 2>/dev/null || true
$VPP set interface ip address del gre0 "$INNER_LOCAL" 2>/dev/null || true
$VPP set interface ip address gre0 "$INNER_LOCAL" 2>/dev/null || true
# No per-packet MSS features
$VPP set interface tcp-mss-clamp gre0 ip4 disable ip6 disable 2>/dev/null || true
$VPP set interface l2-mss-clamp gre0 disable 2>/dev/null || true

# loop10 in table 81
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

# Push VTEP to VPS (idempotent)
if [ "$OLD" != "$SRC" ] || [ "${PD_FORCE_SYNC:-0}" = 1 ]; then
  echo "pd-gre: syncing VTEP $SRC -> VPS"
  ssh -i "$PD_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=12 \
    "$PD_VPS_SSH" "/usr/local/sbin/pd-gre-set-vtep.sh $SRC" || echo "pd-gre: VPS sync failed (will retry via watchdog)"
else
  # Still ensure VPS gre healthy
  ssh -i "$PD_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 \
    "$PD_VPS_SSH" "/usr/local/sbin/pd-gre-to-digi.sh" >/dev/null 2>&1 || true
fi

echo "pd-gre ready src=$SRC dst=$PD_VTEP"
