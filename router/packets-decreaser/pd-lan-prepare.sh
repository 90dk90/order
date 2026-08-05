#!/bin/sh
# LAN BVI + anti-ARP FIB only (no GRE / Digi IPv6 required).
# Safe to run while waiting for Digi global IPv6.
set -eu
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
. /etc/pd/pd-gre.conf 2>/dev/null || true
LAN_BD="${LAN_BD:-10}"
PBR_TABLE="${PBR_TABLE:-81}"
LAN_GW="${LAN_GW:-79.172.242.1}"
LAN_PREFIX="${LAN_PREFIX:-79.172.242.0/24}"
LAN_HOSTS="${LAN_HOSTS:-79.172.242.2:c4:62:37:0d:2f:96 79.172.242.3:c4:62:37:0d:2f:96 79.172.242.10:c4:62:37:0d:2f:96}"

$VPP show version >/dev/null

# Idempotent: ignore "already exists" style errors; never hard-fail the box.
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

# Prefer not to "del all" if already correct (/32 in PBR) — avoids VPP churn.
need_addr=1
if $VPP show interface addr loop10 2>/dev/null | tr -d '\r' | grep -q "${LAN_GW}/32" \
  && $VPP show interface addr loop10 2>/dev/null | tr -d '\r' | grep -q "table-id ${PBR_TABLE}"; then
  need_addr=0
fi
if [ "$need_addr" = 1 ]; then
  # Remove legacy /24 only, then bind VRF, then /32 — avoid "del all" when possible
  $VPP set interface ip address del loop10 "${LAN_GW}/24" 2>/dev/null || true
  $VPP set interface ip table loop10 "$PBR_TABLE" 2>/dev/null || true
  $VPP set interface ip address loop10 "${LAN_GW}/32" 2>/dev/null || true
fi

for t in 0 "$PBR_TABLE" 82 83; do
  $VPP ip route del table "$t" "$LAN_PREFIX" via loop10 2>/dev/null || true
  $VPP ip route del table "$t" "$LAN_PREFIX" 2>/dev/null || true
done
$VPP ip route del "$LAN_PREFIX" via loop10 2>/dev/null || true

for entry in $LAN_HOSTS; do
  ip="${entry%%:*}"
  mac=""
  case "$entry" in
    *:*) mac="${entry#*:}" ;;
  esac
  [ -n "$mac" ] && $VPP set ip neighbor loop10 "$ip" "$mac" static 2>/dev/null || true
  $VPP ip route add table "$PBR_TABLE" "${ip}/32" via "$ip" loop10 2>/dev/null || true
  $VPP ip route add table 0 "${ip}/32" via ip4-lookup-in-table "$PBR_TABLE" 2>/dev/null || true
done
$VPP ip route add table "$PBR_TABLE" "$LAN_PREFIX" via drop 2>/dev/null || true
$VPP ip route add table 0 "$LAN_PREFIX" via ip4-lookup-in-table "$PBR_TABLE" 2>/dev/null || true
$VPP ip route add table 0 "${LAN_GW}/32" via ip4-lookup-in-table "$PBR_TABLE" 2>/dev/null || true

echo "pd-lan-prepare: GW ${LAN_GW}/32 table ${PBR_TABLE} (no /24 glean)"
