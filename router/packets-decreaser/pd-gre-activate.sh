#!/bin/sh
# PD GRE primary path — all LAN egress/ingress via gre0 (dedicated IP).
# Digi sticky outbound is abandoned (unstable VPP classify/tap on this box).
set -eu
. /etc/pd/pd-gre.conf
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
LAN_BD="${LAN_BD:-10}"
LAN_GW="${LAN_GW:-79.172.242.1}"
LAN_PREFIX="${LAN_PREFIX:-79.172.242.0/24}"
# Known LAN hosts (ip:mac). Default MAC = PVE vmbr on AS219084.
LAN_HOSTS="${LAN_HOSTS:-79.172.242.2:c4:62:37:0d:2f:96 79.172.242.3:c4:62:37:0d:2f:96 79.172.242.10:c4:62:37:0d:2f:96}"

# Digi VTEP = pppoeclient "wan-ipv6 observed" (807f/817f/…).
# Reject synthetic 80ff / <none> — outbound-ok but not inbound from PD/Internet.
pick_digi_vtep() {
  obs=$($VPP show pppoe client detail 2>/dev/null | sed -n 's/.*wan-ipv6 observed \([^ /]*\).*/\1/p' | tr -d '\r' | head -1)
  case "$obs" in
    ""|"<none>"|none|2a01:4700:80ff:*) obs="" ;;
  esac
  if [ -n "$obs" ]; then
    printf '%s\n' "$obs"
    return 0
  fi
  $VPP show interface addr digi 2>/dev/null | awk '
    /L3 2a01:4700:80ff:/{next}
    /L3 2a01:4700:/{gsub(/\/.*/,"",$2); print $2; exit}
  '
}

# Anti-ARP-storm LAN FIB: never "LAN_PREFIX via loop10" (glean floods LAN).
install_lan_fib() {
  for t in 0 "$PBR_TABLE" 82 83; do
    $VPP ip route del table "$t" "$LAN_PREFIX" via loop10 2>/dev/null || true
    $VPP ip route del table "$t" "$LAN_PREFIX" 2>/dev/null || true
  done
  $VPP ip route del "$LAN_PREFIX" via loop10 2>/dev/null || true
  $VPP ip route del "$LAN_PREFIX" 2>/dev/null || true

  for entry in $LAN_HOSTS; do
    ip="${entry%%:*}"
    mac=""
    case "$entry" in
      *:*) mac="${entry#*:}" ;;
    esac
    [ -n "$mac" ] && $VPP set ip neighbor loop10 "$ip" "$mac" static 2>/dev/null || true
    $VPP ip route del table "$PBR_TABLE" "${ip}/32" 2>/dev/null || true
    $VPP ip route add table "$PBR_TABLE" "${ip}/32" via "$ip" loop10 2>/dev/null || true
    $VPP ip route del table 0 "${ip}/32" 2>/dev/null || true
    $VPP ip route add table 0 "${ip}/32" via ip4-lookup-in-table "$PBR_TABLE" 2>/dev/null || true
  done

  $VPP ip route add table "$PBR_TABLE" "$LAN_PREFIX" via drop 2>/dev/null || true
  $VPP ip route add table 0 "$LAN_PREFIX" via ip4-lookup-in-table "$PBR_TABLE" 2>/dev/null || true
  $VPP ip route del table 0 "${LAN_GW}/32" 2>/dev/null || true
  $VPP ip route add table 0 "${LAN_GW}/32" via ip4-lookup-in-table "$PBR_TABLE" 2>/dev/null || true
}

strip_sticky_classify() {
  # Detach leftover Digi-sticky inacl if present (PD-only path needs none).
  old_sport=$(sed -n 's/^sport_table=//p' /etc/pd/sticky-digi 2>/dev/null | head -1 || true)
  if [ -n "${old_sport:-}" ]; then
    $VPP set interface input acl intfc loop10 ip4-table "$old_sport" del 2>/dev/null || true
  fi
  $VPP set interface input acl intfc loop10 ip4-table 0 del 2>/dev/null || true
}

SRC=""
i=0
# Keep this short: systemd ExecStartPost shares TimeoutStartSec with pppoe.
# Watchdog retries when Digi has not published a real global yet.
while [ $i -lt 15 ]; do
  if $VPP show version >/dev/null 2>&1; then
    SRC=$(pick_digi_vtep)
    [ -n "$SRC" ] && break
  fi
  i=$((i+1))
  sleep 2
done
[ -n "$SRC" ] || { echo "pd-gre: no Digi observed WAN IPv6 yet (reject 80ff/<none>) — watchdog will retry"; exit 0; }

case "$SRC" in
  ""|"<none>"|none|2a01:4700:80ff:*)
    echo "pd-gre: refusing bad VTEP '$SRC'"; exit 1 ;;
esac

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
if ! $VPP show interface 2>/dev/null | grep -q '^loop10'; then
  $VPP create loopback interface instance 10 2>/dev/null || true
fi
for iface in x520lan x520extra0 x520extra1; do
  $VPP set interface l2 bridge "$iface" "$LAN_BD" 2>/dev/null || true
  $VPP set interface state "$iface" up 2>/dev/null || true
done
$VPP set interface l2 bridge loop10 "$LAN_BD" bvi 2>/dev/null || true
$VPP set interface state loop10 up 2>/dev/null || true

if [ -x /usr/local/sbin/vpp-lan-bridge-prune.sh ]; then
  /usr/local/sbin/vpp-lan-bridge-prune.sh || true
fi

NEED_GRE=0
CUR_SRC=""
if ! $VPP show interface gre0 >/dev/null 2>&1; then
  NEED_GRE=1
else
  CUR_SRC=$($VPP show gre tunnel 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  case "$CUR_SRC" in
    ""|"<none>") NEED_GRE=1 ;;
  esac
  $VPP show gre tunnel 2>/dev/null | grep -q "$PD_VTEP" || NEED_GRE=1
  [ -n "$CUR_SRC" ] && [ "$CUR_SRC" != "$SRC" ] && NEED_GRE=1
  [ -n "$OLD" ] && [ "$OLD" != "$SRC" ] && [ "$OLD" != "<none>" ] && NEED_GRE=1
fi

if [ "$NEED_GRE" = 1 ]; then
  if [ -n "$CUR_SRC" ] && [ "$CUR_SRC" != "<none>" ]; then
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

# PD-only: clear Digi sticky classify leftovers
strip_sticky_classify
rm -f /etc/pd/sticky-digi

# GW /32 on loop10 / PBR table (never /24 connected glean)
# Prefer lan-prepare helper (avoids needless del-all when already correct)
if [ -x /usr/local/sbin/pd-lan-prepare.sh ]; then
  /usr/local/sbin/pd-lan-prepare.sh >/dev/null || true
else
  $VPP set interface ip address del loop10 "${LAN_GW}/24" 2>/dev/null || true
  $VPP set interface ip address del loop10 all 2>/dev/null || true
  $VPP set interface ip table loop10 "$PBR_TABLE" 2>/dev/null || true
  $VPP set interface ip address loop10 "${LAN_GW}/32" 2>/dev/null || true
fi
$VPP set interface state loop10 up 2>/dev/null || true
$VPP set interface tcp-mss-clamp loop10 ip4 disable ip6 disable 2>/dev/null || true
$VPP set interface l2-mss-clamp loop10 disable 2>/dev/null || true
$VPP set interface tcp-mss-clamp x520lan ip4 disable ip6 disable 2>/dev/null || true
$VPP set interface l2-mss-clamp x520lan disable 2>/dev/null || true

$VPP ip route del table "$PBR_TABLE" 0.0.0.0/0 2>/dev/null || true
$VPP ip route add table "$PBR_TABLE" 0.0.0.0/0 via "$INNER_PEER" gre0 2>/dev/null || true
install_lan_fib

if [ "$OLD" != "$SRC" ] || [ "${PD_FORCE_SYNC:-0}" = 1 ]; then
  echo "pd-gre: syncing VTEP $SRC -> VPS"
  ssh -i "$PD_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=12 \
    "$PD_VPS_SSH" "/usr/local/sbin/pd-gre-set-vtep.sh $SRC" || echo "pd-gre: VPS sync failed (will retry via watchdog)"
else
  ssh -i "$PD_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 \
    "$PD_VPS_SSH" "/usr/local/sbin/pd-gre-to-digi.sh" >/dev/null 2>&1 || true
fi

# ICMPv6-only hide (echo-request + time-exceeded). Skip with PD_SKIP_HARDEN=1.
if [ "${PD_SKIP_HARDEN:-0}" != 1 ] && [ -x /usr/local/sbin/pd-gre-harden.sh ]; then
  /usr/local/sbin/pd-gre-harden.sh || echo "pd-gre: harden failed (non-fatal)"
fi

# Explicit opt-in only — Digi sticky is abandoned by default
if [ "${PD_ENABLE_STICKY:-0}" = 1 ] && [ -x /usr/local/sbin/digi-sticky-outbound.sh ]; then
  /usr/local/sbin/digi-sticky-outbound.sh || echo "pd-gre: sticky reapply failed (non-fatal)"
fi

echo "pd-gre ready src=$SRC dst=$PD_VTEP mode=pd-only gw=${LAN_GW}/32"
