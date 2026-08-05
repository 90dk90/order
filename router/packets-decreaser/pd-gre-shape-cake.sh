#!/bin/bash
# Shape gre-pd with CAKE just under Digi PPPoE capacity to kill Digi bufferbloat.
# VPS TX (gre-pd root)  = download toward Digi/PVE
# VPS RX via ifb-pd     = upload from Digi/PVE
#
# Set in /etc/pd-gre.env (Mbit/s, ~85–95% of Digi speedtest without tunnel):
#   DIGI_DOWN_MBIT=850
#   DIGI_UP_MBIT=80
# Disable: PD_SHAPE=0
set -euo pipefail
ENV=/etc/pd-gre.env
[ -f "$ENV" ] && . "$ENV"

PD_SHAPE="${PD_SHAPE:-0}"
DIGI_DOWN_MBIT="${DIGI_DOWN_MBIT:-850}"
DIGI_UP_MBIT="${DIGI_UP_MBIT:-80}"
IFACE="${PD_SHAPE_IFACE:-gre-pd}"
IFB="${PD_SHAPE_IFB:-ifb-pd}"

# Default OFF — max Digi throughput. Opt-in only when trading ~5% rate for latency.

if [ "$PD_SHAPE" = 0 ]; then
  tc qdisc del dev "$IFACE" root 2>/dev/null || true
  tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
  tc qdisc del dev "$IFB" root 2>/dev/null || true
  ip link del "$IFB" 2>/dev/null || true
  echo "pd-gre-shape: disabled"
  exit 0
fi

ip link show "$IFACE" >/dev/null 2>&1 || { echo "pd-gre-shape: $IFACE missing"; exit 0; }
modprobe sch_cake 2>/dev/null || true
modprobe ifb 2>/dev/null || true
modprobe sch_ingress 2>/dev/null || true

# Download path: Internet → VPS → gre-pd → Digi (fills Digi downlink buffer if uncapped)
tc qdisc replace dev "$IFACE" root cake bandwidth "${DIGI_DOWN_MBIT}mbit" \
  besteffort dual-dsthost nat wash ack-filter

# Upload path: Digi → gre-pd RX → redirect IFB → CAKE
ip link add "$IFB" type ifb 2>/dev/null || true
ip link set "$IFB" up
tc qdisc replace dev "$IFACE" handle ffff: ingress
tc filter del dev "$IFACE" parent ffff: 2>/dev/null || true
tc filter add dev "$IFACE" parent ffff: protocol all u32 match u32 0 0 \
  action mirred egress redirect dev "$IFB"
tc qdisc replace dev "$IFB" root cake bandwidth "${DIGI_UP_MBIT}mbit" \
  besteffort dual-srchost nat wash ack-filter

echo "pd-gre-shape: cake down=${DIGI_DOWN_MBIT}mbit up=${DIGI_UP_MBIT}mbit on $IFACE/$IFB"
