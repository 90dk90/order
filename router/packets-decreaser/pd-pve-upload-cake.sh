#!/bin/bash
# PVE: shape UPLOAD toward Digi BEFORE Digi uplink buffers fill.
# VPS CAKE only fixes DOWNLOAD (VPS→Digi). Upload must be shaped here.
#
# ~95% of PVE upload peak via PD (uncapped was ~3168 Mbps).
# Usage:
#   DIGI_UP_MBIT=2800 IFACE=enp16s0 /usr/local/sbin/pd-pve-upload-cake.sh
# Disable:
#   PD_SHAPE=0 /usr/local/sbin/pd-pve-upload-cake.sh
set -euo pipefail

PD_SHAPE="${PD_SHAPE:-1}"
DIGI_UP_MBIT="${DIGI_UP_MBIT:-2800}"
# Digi-facing NIC (override if needed)
IFACE="${IFACE:-enp16s0}"

if [ "$PD_SHAPE" = 0 ]; then
  # restore mq+pfifo from pve-nic-tune if present
  if [ -x /usr/local/sbin/pve-nic-tune.sh ]; then
    /usr/local/sbin/pve-nic-tune.sh || true
  else
    tc qdisc del dev "$IFACE" root 2>/dev/null || true
  fi
  echo "pd-pve-upload-cake: disabled on $IFACE"
  exit 0
fi

ip link show "$IFACE" >/dev/null
modprobe sch_cake 2>/dev/null || true

# Single cake root — limits what Digi ever sees on uplink via GRE
tc qdisc replace dev "$IFACE" root cake bandwidth "${DIGI_UP_MBIT}mbit" \
  besteffort dual-srchost nat wash ack-filter

echo "pd-pve-upload-cake: $IFACE up=${DIGI_UP_MBIT}mbit (shapes Digi uplink before bufferbloat)"
tc -s qdisc show dev "$IFACE" | head -6
