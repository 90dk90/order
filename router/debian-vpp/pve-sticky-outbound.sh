#!/bin/bash
# REMOVE PVE sticky (Digi-only mode: PVE keeps plain GW .1, no marks).
# Safe to run even if sticky was never installed.
set -euo pipefail
GRE_GW="${GRE_GW:-79.172.242.1}"
DIGI_GW="${DIGI_GW:-79.172.242.253}"
TABLE="${TABLE:-42}"
MARK="${MARK:-42}"
IF="${IF:-vmbr0}"

iptables -t mangle -D OUTPUT -j PVE_STICKY 2>/dev/null || true
iptables -t mangle -F PVE_STICKY 2>/dev/null || true
iptables -t mangle -X PVE_STICKY 2>/dev/null || true

ip rule del fwmark "$MARK" table "$TABLE" 2>/dev/null || true
ip route flush table "$TABLE" 2>/dev/null || true
ip route del "${DIGI_GW}/32" dev "$IF" 2>/dev/null || true
ip route replace default via "$GRE_GW" dev "$IF" onlink 2>/dev/null || \
  ip route replace default via "$GRE_GW" dev "$IF"

echo "pve-sticky removed: default via ${GRE_GW} only (Digi-only sticky on router)"
