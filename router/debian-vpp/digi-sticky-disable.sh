#!/bin/bash
# Disable Digi sticky hairpin — detach classify + NAT; leave taps (safe).
set -euo pipefail

VPP="${VPP_BIN:-/usr/bin/vppctl}"
SOCK="${VPP_SOCK:-/run/vpp/cli.sock}"
DIGI_IF="${DIGI_IF:-digi}"
TAP_B_ID="${TAP_B_ID:-81}"

old_sport=$(sed -n 's/^sport_table=//p' /etc/pd/sticky-digi 2>/dev/null | head -1 || true)
DIGI_IP=$(sed -n 's/^digi_ip=//p' /etc/pd/sticky-digi 2>/dev/null | head -1 || true)

if [ -n "${old_sport:-}" ]; then
  "$VPP" -s "$SOCK" set interface input acl intfc loop10 ip4-table "$old_sport" del 2>/dev/null || true
fi
"$VPP" -s "$SOCK" set interface input acl intfc loop10 ip4-table 0 del 2>/dev/null || true

"$VPP" -s "$SOCK" set interface nat44 ei in "tap${TAP_B_ID}" out "$DIGI_IF" del 2>/dev/null || true
"$VPP" -s "$SOCK" set interface nat44 ei in loop10 out "$DIGI_IF" output-feature del 2>/dev/null || true
"$VPP" -s "$SOCK" set interface nat44 ei in loop10 out "$DIGI_IF" del 2>/dev/null || true
if [ -n "${DIGI_IP:-}" ]; then
  "$VPP" -s "$SOCK" nat44 ei add address "$DIGI_IP" del 2>/dev/null || true
fi
"$VPP" -s "$SOCK" clear nat44 ei sessions 2>/dev/null || true

rm -f /run/vpp-prefer-digi-snat /etc/pd/sticky-digi

if ! "$VPP" -s "$SOCK" show version 2>/dev/null | grep -q vpp; then
  echo "digi-sticky-disable: VPP not responding" >&2
  exit 1
fi
echo "digi-sticky-disable: classify/NAT detached (taps left in place)"
