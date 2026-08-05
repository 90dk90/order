#!/bin/sh
# RX placement for Digi PD path.
# - Only busy-poll x520wan + x520lan (carry all GRE/LAN traffic).
# - x520extra* stay down + interrupt (no wasted poll on GRE's only RSS queue worker).
# - tap30 / digi LCP tun: interrupt mode (control-plane, low pps).
set -eu

VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
QUEUES="0 1 2 3"

# Unused dual-port leftovers — never busy-poll
for iface in x520extra0 x520extra1; do
  $VPP set interface state "$iface" down 2>/dev/null || true
  for queue in $QUEUES; do
    $VPP set interface rx-mode "$iface" queue "$queue" interrupt 2>/dev/null || true
  done
done

# Data path NICs — polling on workers 0-3
for iface in x520wan x520lan; do
  for queue in $QUEUES; do
    $VPP set interface rx-mode "$iface" queue "$queue" polling 2>/dev/null || true
    $VPP set interface rx-placement "$iface" queue "$queue" worker "$queue" 2>/dev/null || true
  done
done

# Legacy softpath tap (if present)
if $VPP show interface 2>/dev/null | grep -q '^tap20[[:space:]]'; then
  for queue in $QUEUES; do
    $VPP set interface rx-mode tap20 queue "$queue" interrupt 2>/dev/null || true
  done
done

# Admin / Digi LCP — interrupt, do not steal wk0 poll budget from GRE q0
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
