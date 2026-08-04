#!/bin/sh
set -eu

VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
# Workers are corelist 2-5 => worker ids 0-3. Keep DPDK/tap queues on those workers only.
DPDK_IFS="x520wan x520lan x520extra0 x520extra1"
QUEUES="0 1 2 3"

for iface in $DPDK_IFS; do
  $VPP set interface rss queues "$iface" 0-3 >/dev/null 2>&1 || true
  for queue in $QUEUES; do
    $VPP set interface rx-mode "$iface" queue "$queue" polling >/dev/null 2>&1 || true
    $VPP set interface rx-placement "$iface" queue "$queue" worker "$queue" >/dev/null 2>&1 || true
  done
done

if $VPP show interface | /bin/grep -q '^tap20[[:space:]]'; then
  for queue in $QUEUES; do
    $VPP set interface rx-mode tap20 queue "$queue" polling >/dev/null 2>&1 || true
    $VPP set interface rx-placement tap20 queue "$queue" worker "$queue" >/dev/null 2>&1 || true
  done
fi

if $VPP show interface | /bin/grep -q '^tap30[[:space:]]'; then
  for queue in $QUEUES; do
    $VPP set interface rx-mode tap30 queue "$queue" polling >/dev/null 2>&1 || true
    $VPP set interface rx-placement tap30 queue "$queue" worker "$queue" >/dev/null 2>&1 || true
  done
fi
