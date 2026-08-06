#!/bin/bash
# Shape gre-pd DOWNLOAD with CAKE just under Digi capacity.
# Upload bufferbloat must be shaped on PVE (see pd-pve-upload-cake.sh) —
# VPS IFB is too late (Digi uplink already queued).
#
# /etc/pd-gre.env:
#   DIGI_DOWN_MBIT=2600
#   PD_SHAPE=1
# Disable: PD_SHAPE=0
set -euo pipefail
ENV=/etc/pd-gre.env
[ -f "$ENV" ] && . "$ENV"

PD_SHAPE="${PD_SHAPE:-0}"
DIGI_DOWN_MBIT="${DIGI_DOWN_MBIT:-2600}"
IFACE="${PD_SHAPE_IFACE:-gre-pd}"

if [ "$PD_SHAPE" = 0 ]; then
  tc qdisc del dev "$IFACE" root 2>/dev/null || true
  tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
  tc qdisc del dev ifb-pd root 2>/dev/null || true
  ip link del ifb-pd 2>/dev/null || true
  echo "pd-gre-shape: disabled"
  exit 0
fi

ip link show "$IFACE" >/dev/null 2>&1 || { echo "pd-gre-shape: $IFACE missing"; exit 0; }
modprobe sch_cake 2>/dev/null || true

# Drop any old IFB upload path (ineffective for Digi uplink bloat)
tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
tc qdisc del dev ifb-pd root 2>/dev/null || true
ip link del ifb-pd 2>/dev/null || true

# Download only: Internet → VPS → gre-pd → Digi
tc qdisc replace dev "$IFACE" root cake bandwidth "${DIGI_DOWN_MBIT}mbit" \
  besteffort dual-dsthost nat wash ack-filter

echo "pd-gre-shape: cake DOWNLOAD ${DIGI_DOWN_MBIT}mbit on $IFACE (upload=shape on PVE)"
