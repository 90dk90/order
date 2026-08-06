#!/bin/bash
# Keep Digi VPP ↔ PVE LAN (x520lan) from going fully idle.
#
# After ~60–120s idle, Digi delays L2/ICMP replies on the wire (ARP and ICMP
# both; staircase ~48ms steps, up to ~800ms). This is Digi VPP/DPDK LAN, NOT
# Linux pfifo_fast/fq (pfifo only fixed Digi WAN underlay pacing).
#
# ~50 pps ICMP is enough to keep the path warm without meaningful load.
set -euo pipefail
TARGET="${PVE_LAN_KEEPALIVE_TARGET:-79.172.242.1}"
INTERVAL="${PVE_LAN_KEEPALIVE_INTERVAL:-0.02}"
exec ping -i "$INTERVAL" -W 1 -n "$TARGET" >/dev/null
