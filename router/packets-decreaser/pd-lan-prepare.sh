#!/bin/sh
# LAN BVI + anti-ARP FIB only.
# Soft/idempotent: if loop10 already has GW /32 in table 81, do nothing.
# Avoids VPP SIGSEGV from repeated ip route del/add churn (Infrawire-stable mode).
set -eu
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
. /etc/pd/pd-gre.conf 2>/dev/null || true
LAN_BD="${LAN_BD:-10}"
PBR_TABLE="${PBR_TABLE:-81}"
LAN_GW="${LAN_GW:-79.172.242.1}"
LAN_PREFIX="${LAN_PREFIX:-79.172.242.0/24}"
LAN_HOSTS="${LAN_HOSTS:-79.172.242.2:c4:62:37:0d:2f:96 79.172.242.3:c4:62:37:0d:2f:96 79.172.242.10:c4:62:37:0d:2f:96}"

$VPP show version >/dev/null

# Host /32 is OK only if CLI route contributes a real forwarding chain.
# Adjacency-only entries can show "via" yet "forwarding: UNRESOLVED", and then
# traffic hits the covering ${LAN_PREFIX} drop (PVE looks "down" after Digi reboot).
host_route_ok() {
  ip="$1"
  fib=$($VPP show ip fib table "$PBR_TABLE" "${ip}/32" 2>/dev/null | tr -d '\r')
  echo "$fib" | grep -q 'CLI refs:.*contributing,active,' || return 1
  echo "$fib" | grep -q 'forwarding:   UNRESOLVED' && return 1
  echo "$fib" | grep -q 'dpo-load-balance' || return 1
  return 0
}

# Already correct → exit quietly (no FIB churn)
if $VPP show interface addr loop10 2>/dev/null | tr -d '\r' | grep -q "${LAN_GW}/32" \
  && $VPP show interface addr loop10 2>/dev/null | tr -d '\r' | grep -q "table-id ${PBR_TABLE}" \
  && ! $VPP show ip fib table 0 "$LAN_PREFIX" 2>/dev/null | tr -d '\r' | grep -q 'ipv4-glean'; then
  missing=0
  for entry in $LAN_HOSTS; do
    ip="${entry%%:*}"
    host_route_ok "$ip" || missing=1
  done
  if [ "$missing" = 0 ]; then
    echo "pd-lan-prepare: already OK — skip"
    exit 0
  fi
fi

# Idempotent create (ignore already-exists)
$VPP create bridge-domain "$LAN_BD" 2>/dev/null || true
if ! $VPP show interface 2>/dev/null | tr -d '\r' | awk '$1=="loop10"{found=1} END{exit !found}'; then
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

$VPP ip table add "$PBR_TABLE" 2>/dev/null || true
$VPP ip table add 82 2>/dev/null || true
$VPP ip table add 83 2>/dev/null || true

need_addr=1
if $VPP show interface addr loop10 2>/dev/null | tr -d '\r' | grep -q "${LAN_GW}/32" \
  && $VPP show interface addr loop10 2>/dev/null | tr -d '\r' | grep -q "table-id ${PBR_TABLE}"; then
  need_addr=0
fi
if [ "$need_addr" = 1 ]; then
  # Prefer not to del-all — only remove legacy /24 then set /32
  $VPP set interface ip address del loop10 "${LAN_GW}/24" 2>/dev/null || true
  $VPP set interface ip table loop10 "$PBR_TABLE" 2>/dev/null || true
  $VPP set interface ip address loop10 "${LAN_GW}/32" 2>/dev/null || true
fi

# Install host routes without blanket del of whole prefix tables when possible
for entry in $LAN_HOSTS; do
  ip="${entry%%:*}"
  mac=""
  case "$entry" in
    *:*) mac="${entry#*:}" ;;
  esac
  [ -n "$mac" ] && $VPP set ip neighbor loop10 "$ip" "$mac" static 2>/dev/null || true
  if ! host_route_ok "$ip"; then
    $VPP ip route del table "$PBR_TABLE" "${ip}/32" 2>/dev/null || true
    $VPP ip route add table "$PBR_TABLE" "${ip}/32" via "$ip" loop10 2>/dev/null || true
  fi
  if ! $VPP show ip fib table 0 "${ip}/32" 2>/dev/null | tr -d '\r' | grep -q 'ip4-lookup-in-table'; then
    $VPP ip route add table 0 "${ip}/32" via ip4-lookup-in-table "$PBR_TABLE" 2>/dev/null || true
  fi
done

# Drop leftover /24 glean if present
if $VPP show ip fib table 0 "$LAN_PREFIX" 2>/dev/null | tr -d '\r' | grep -q 'ipv4-glean'; then
  $VPP ip route del table 0 "$LAN_PREFIX" 2>/dev/null || true
fi
$VPP ip route add table "$PBR_TABLE" "$LAN_PREFIX" via drop 2>/dev/null || true
$VPP ip route add table 0 "$LAN_PREFIX" via ip4-lookup-in-table "$PBR_TABLE" 2>/dev/null || true
$VPP ip route add table 0 "${LAN_GW}/32" via ip4-lookup-in-table "$PBR_TABLE" 2>/dev/null || true

echo "pd-lan-prepare: GW ${LAN_GW}/32 table ${PBR_TABLE} (no /24 glean)"
