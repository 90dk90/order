#!/bin/sh
# LAN BVI + cover /24 via PVE (no per-DIP /32, no /24 glean).
# Soft/idempotent: if cover route already via PVE in table 81, do nothing.
set -eu
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
. /etc/pd/pd-gre.conf 2>/dev/null || true
LAN_BD="${LAN_BD:-10}"
PBR_TABLE="${PBR_TABLE:-81}"
LAN_GW="${LAN_GW:-79.172.242.1}"
LAN_PREFIX="${LAN_PREFIX:-79.172.242.0/24}"
LAN_PVE="${LAN_PVE_IP:-79.172.242.2}"
LAN_PVE_MAC="${LAN_HOST_MAC:-c4:62:37:0d:2f:96}"

$VPP show version >/dev/null

cover_ok() {
  fib=$($VPP show ip fib table "$PBR_TABLE" "$LAN_PREFIX" 2>/dev/null | tr -d '\r')
  echo "$fib" | grep -q 'CLI refs:.*contributing,active,' || return 1
  echo "$fib" | grep -q 'forwarding:   UNRESOLVED' && return 1
  echo "$fib" | grep -q "via ${LAN_PVE} loop10" || return 1
  echo "$fib" | grep -q 'dpo-load-balance' || return 1
  return 0
}

# Already correct → exit quietly (no FIB churn)
if $VPP show interface addr loop10 2>/dev/null | tr -d '\r' | grep -q "${LAN_GW}/32" \
  && $VPP show interface addr loop10 2>/dev/null | tr -d '\r' | grep -q "table-id ${PBR_TABLE}" \
  && ! $VPP show ip fib table 0 "$LAN_PREFIX" 2>/dev/null | tr -d '\r' | grep -q 'ipv4-glean' \
  && cover_ok; then
  echo "pd-lan-prepare: already OK — skip"
  exit 0
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
  $VPP set interface ip address del loop10 "${LAN_GW}/24" 2>/dev/null || true
  $VPP set interface ip table loop10 "$PBR_TABLE" 2>/dev/null || true
  $VPP set interface ip address loop10 "${LAN_GW}/32" 2>/dev/null || true
fi

# One neighbor (PVE) + cover /24 — any DIP on vmbr0 is reachable without /32 churn
$VPP set ip neighbor loop10 "$LAN_PVE" "$LAN_PVE_MAC" static 2>/dev/null || true
$VPP ip route del table "$PBR_TABLE" "$LAN_PREFIX" 2>/dev/null || true
$VPP ip route add table "$PBR_TABLE" "$LAN_PREFIX" via "$LAN_PVE" loop10 2>/dev/null || true

# Drop leftover /24 glean if present
if $VPP show ip fib table 0 "$LAN_PREFIX" 2>/dev/null | tr -d '\r' | grep -q 'ipv4-glean'; then
  $VPP ip route del table 0 "$LAN_PREFIX" 2>/dev/null || true
fi
$VPP ip route add table 0 "$LAN_PREFIX" via ip4-lookup-in-table "$PBR_TABLE" 2>/dev/null || true
$VPP ip route add table 0 "${LAN_GW}/32" via ip4-lookup-in-table "$PBR_TABLE" 2>/dev/null || true

echo "pd-lan-prepare: GW ${LAN_GW}/32 table ${PBR_TABLE}; ${LAN_PREFIX} via ${LAN_PVE} (cover24)"
