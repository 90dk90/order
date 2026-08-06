# Keep Digi VPP ↔ PVE LAN warm (optional insurance).
#
# Primary fix for Digi↔PVE spikes: kernel.sched_rt_runtime_us=-1 on Digi
# (router/debian-vpp/99-vpp-rt.conf). Enable this unit only if needed.
set -euo pipefail
TARGET="${PVE_LAN_KEEPALIVE_TARGET:-79.172.242.1}"
INTERVAL="${PVE_LAN_KEEPALIVE_INTERVAL:-0.02}"
exec ping -i "$INTERVAL" -W 1 -n "$TARGET" >/dev/null
