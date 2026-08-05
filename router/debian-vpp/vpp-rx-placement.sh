#!/bin/sh
# RX placement for Digi PD path (PPPoE-aware).
#
# Digi WAN is PPPoE (ethertype 0x8864): NIC RSS cannot see inner IPv6/UDP, so
# hardware multi-queue RX does not spread on x520wan. Prefer pd-rss-tune.sh
# (wan q0 polling; lan q0–q3 polling). This script is the bootstrap fallback.
set -eu

VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"

if [ -x /usr/local/sbin/pd-rss-tune.sh ]; then
  /usr/local/sbin/pd-rss-tune.sh
  exit 0
fi

QUEUES="0 1 2 3"

for iface in x520extra0 x520extra1; do
  $VPP set interface state "$iface" down 2>/dev/null || true
  for queue in $QUEUES; do
    $VPP set interface rx-mode "$iface" queue "$queue" interrupt 2>/dev/null || true
  done
done

for iface in x520wan x520lan; do
  $VPP set interface rss queues "$iface" list 0 1 2 3 2>/dev/null || true
done

# WAN: PPPoE lands on q0 only — poll q0, interrupt empty q1–3
$VPP set interface rx-mode x520wan queue 0 polling 2>/dev/null || true
for queue in 1 2 3; do
  $VPP set interface rx-mode x520wan queue "$queue" interrupt 2>/dev/null || true
done

# LAN: poll all queues — interrupt mode drops hashed /24 return frames
for queue in 0 1 2 3; do
  $VPP set interface rx-mode x520lan queue "$queue" polling 2>/dev/null || true
done

$VPP set interface rx-placement x520lan queue 0 worker 0 2>/dev/null || true
$VPP set interface rx-placement x520wan queue 0 worker 1 2>/dev/null || true
$VPP set interface rx-placement x520lan queue 1 worker 2 2>/dev/null || true
$VPP set interface rx-placement x520wan queue 1 worker 2 2>/dev/null || true
$VPP set interface rx-placement x520lan queue 2 worker 3 2>/dev/null || true
$VPP set interface rx-placement x520wan queue 2 worker 3 2>/dev/null || true
$VPP set interface rx-placement x520lan queue 3 worker 0 2>/dev/null || true
$VPP set interface rx-placement x520wan queue 3 worker 0 2>/dev/null || true
