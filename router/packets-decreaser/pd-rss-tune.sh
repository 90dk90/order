#!/bin/bash
# Digi X520 RSS tune for PPPoE + VXLAN reality (no VPP/PPPoE restart).
#
# Findings (82599 + native pppoeclient):
#   - x520wan RX is ethertype 0x8864 (PPPoE). NIC classifies L2 only → rss=0x0
#     → ALL Digi WAN RX lands on queue 0. VXLAN UDP sport entropy is invisible
#     to hardware RSS until AFTER PPPoE decap (too late for NIC multi-queue).
#   - `set interface rss queues … list 0 1 2 3` updates VPP bitmap; ixgbe RETA
#     still does not spread on this box (lan also stays on q0 under multi-flow).
#   - Polling empty q1–q3 burns worker cycles without moving packets.
#
# This script:
#   1) best-effort programs RSS queue list (harmless if RETA no-ops)
#   2) polls ONLY queue 0 on x520wan/x520lan; q1–q3 → interrupt
#   3) pins wan-q0 and lan-q0 on DIFFERENT workers
set -euo pipefail

VPP="${VPP:-/usr/bin/vppctl}"

$VPP show version >/dev/null

for iface in x520wan x520lan; do
  $VPP set interface rss queues "$iface" list 0 1 2 3 2>/dev/null || \
    $VPP set interface rss queues "$iface" list 0 1 2>/dev/null || true
  $VPP set interface rx-mode "$iface" queue 0 polling 2>/dev/null || true
  for q in 1 2 3; do
    $VPP set interface rx-mode "$iface" queue "$q" interrupt 2>/dev/null || true
  done
done

# Hot queues on separate cores (upload vs download)
$VPP set interface rx-placement x520lan queue 0 worker 0 2>/dev/null || true
$VPP set interface rx-placement x520wan queue 0 worker 1 2>/dev/null || true
# Cold (interrupt) queues — park on remaining workers
$VPP set interface rx-placement x520lan queue 1 worker 2 2>/dev/null || true
$VPP set interface rx-placement x520wan queue 1 worker 2 2>/dev/null || true
$VPP set interface rx-placement x520lan queue 2 worker 3 2>/dev/null || true
$VPP set interface rx-placement x520wan queue 2 worker 3 2>/dev/null || true
$VPP set interface rx-placement x520lan queue 3 worker 3 2>/dev/null || true
$VPP set interface rx-placement x520wan queue 3 worker 0 2>/dev/null || true

# Keep unused X520 ports quiet
for iface in x520extra0 x520extra1; do
  $VPP set interface state "$iface" down 2>/dev/null || true
  for q in 0 1 2 3; do
    $VPP set interface rx-mode "$iface" queue "$q" interrupt 2>/dev/null || true
  done
done

echo "pd-rss-tune: wan/lan q0=polling (dedicated workers); q1-3=interrupt; RSS list best-effort"
echo "  NOTE: Digi PPPoE prevents NIC multi-queue RX spread — expect rx_q0≈100% on x520wan."
$VPP show hardware-interfaces x520wan 2>/dev/null | grep -E 'RSS queues|rss active|rx_q' | head -12 || true
$VPP show interface rx-placement 2>/dev/null | grep -E 'x520wan|x520lan|Thread' || true
