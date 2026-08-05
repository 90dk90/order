#!/bin/sh
# RX placement for Digi PD path.
# GRE/IPv6 outer 5-tuple is constant → NIC RSS pins almost all traffic to queue 0.
# Put lan-q0 and wan-q0 on DIFFERENT workers so upload + download don't share one core.
# x520extra* stay down + interrupt; taps interrupt (no poll tax).
set -eu

VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
QUEUES="0 1 2 3"

for iface in x520extra0 x520extra1; do
  $VPP set interface state "$iface" down 2>/dev/null || true
  for queue in $QUEUES; do
    $VPP set interface rx-mode "$iface" queue "$queue" interrupt 2>/dev/null || true
  done
done

for iface in x520wan x520lan; do
  for queue in $QUEUES; do
    $VPP set interface rx-mode "$iface" queue "$queue" polling 2>/dev/null || true
  done
done

# Hot queues (RSS q0): split across workers
$VPP set interface rx-placement x520lan queue 0 worker 0 2>/dev/null || true
$VPP set interface rx-placement x520wan queue 0 worker 1 2>/dev/null || true
# Cold queues (rarely used for GRE) — spread remainder
$VPP set interface rx-placement x520lan queue 1 worker 2 2>/dev/null || true
$VPP set interface rx-placement x520wan queue 1 worker 2 2>/dev/null || true
$VPP set interface rx-placement x520lan queue 2 worker 3 2>/dev/null || true
$VPP set interface rx-placement x520wan queue 2 worker 3 2>/dev/null || true
$VPP set interface rx-placement x520lan queue 3 worker 3 2>/dev/null || true
$VPP set interface rx-placement x520wan queue 3 worker 0 2>/dev/null || true

if $VPP show interface 2>/dev/null | grep -q '^tap20[[:space:]]'; then
  for queue in $QUEUES; do
    $VPP set interface rx-mode tap20 queue "$queue" interrupt 2>/dev/null || true
  done
fi
if $VPP show interface 2>/dev/null | grep -q '^tap30[[:space:]]'; then
  for queue in $QUEUES; do
    $VPP set interface rx-mode tap30 queue "$queue" interrupt 2>/dev/null || true
  done
fi
if $VPP show interface 2>/dev/null | grep -q '^tun4096[[:space:]]'; then
  for queue in $QUEUES; do
    $VPP set interface rx-mode tun4096 queue "$queue" interrupt 2>/dev/null || true
  done
fi
