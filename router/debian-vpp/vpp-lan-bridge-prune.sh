#!/bin/sh
# Keep carrier-down X520 ports out of BD10 (L2 flood → tx-error + latency spikes).
set -eu
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
for iface in x520extra0 x520extra1; do
  link=$($VPP show hardware-interfaces "$iface" 2>/dev/null | tr -d '\r')
  echo "$link" | grep -q 'carrier up' && continue
  # Move to L3 (removes from bridge), then admin-down
  $VPP set interface l3 "$iface" 2>/dev/null || true
  $VPP set interface state "$iface" down 2>/dev/null || true
done
