#!/bin/bash
# Research notes + prototype for Digi VPP-native sticky (Aug 2026).
# Production path: digi-sticky-outbound.sh (mode=vpp-abf-hairpin).
# Fallback:      digi-sticky-outbound-linux.sh (mode=linux).
#
# Architecture (VPP-native):
#   .1 on loop10 BVI / table 81 → default GRE
#   ABF permit+reflect SYN (tcpflags 2 mask 18) → tap80 ──L2 bridge── tap81 → NAT44 → digi
#   else → FIB → gre0
#
# =============================================================================
# GOAL
#   TCP SYN (client NEW) → Digi PPPoE + NAT44 (max BW)
#   else (SYN-ACK/UDP/ICMP/inbound replies) → GRE/PD (dedicated IP)
#   Linux off the L3 data path (no iptables / no .1 on Linux)
#
# =============================================================================
# WHAT WORKS ON THIS BOX (VPP 26.06-release)
#
# 1) Linux hairpin sticky (PRODUCTION)
#    - .1 on vpp-sticky (tap70) in BD10
#    - iptables DIGI_STICKY: SYN+NEW → mark → Digi VRF tap71+NAT
#    - else → GRE via tap72
#    - CONNMARK provides flow stickiness (critical)
#
# 2) ABF attach on BVI loop10 — CAN work when VPP is clean
#    Earlier segfaults were NOT a hard "ABF×BVI impossible"; they correlated
#    with dirty state (NAT output-feature misuse, dual GW ARP, restart races).
#    Clean repro: abf policy + abf attach ip4 policy N loop10 → survived.
#
# 3) ACL plugin + classify/inacl on BVI loop10 — stable (no crash)
#    classify session ... action set-ip4-fib-id <vrf>  = PBR without ABF
#
# 4) ABF on non-BVI tap70 — stable
# 5) Hairpin tap80↔Linux-bridge↔tap81 with VPP-side MACs — ICMP OK
# 6) ABF via <pppoe-peer> digi — parses; empty path was missing peer IP
# 7) ABF via ip4-lookup-in-table 82 — works
# 8) ABF via 10.254.90.2 tap80 (hairpin) — works
#
# =============================================================================
# HARD CONSTRAINTS DISCOVERED
#
# A) Stickiness REQUIRES session state
#    SYN-only match without follow-up for the 5-tuple sends later ACKs via GRE
#    and breaks Digi NAT. Linux CONNMARK / ACL permit+reflect is mandatory.
#    Server SYN-ACK vs client ACK cannot be told apart by flags alone.
#
# B) Non-BVI tap owning .1 is NOT IRB
#    Packets with dst MAC=tap but IP≠local are not L3-routed. GW must be BVI
#    (loop10) or Linux in the bridge.
#
# C) GW cutover needs ARP/GARP
#    Moving .1 loop10↔Linux without GARP leaves PVE neigh on the old MAC →
#    inbound/.2 "dead" even though VPP fib/neigh look fine.
#
# D) NAT digi as in+out output-feature breaks return path
#    Do NOT set "nat44 ei in digi out digi output-feature".
#    Safe pattern: nat44 ei in tap81 out digi (hairpin inside-vrf 82).
#
# E) Plugins on disk but NOT loaded (need VPP restart to enable)
#    memif_plugin, l3xc_plugin, ip_session_redirect_plugin,
#    cnat_plugin, pnat_plugin, svs_plugin
#    ip_session_redirect = manual 5-tuple classify redirect (no auto-SYN sticky)
#    l3xc = redirect ALL L3 from an iface (possible mid-hop before ABF)
#    memif = in-VPP wire (replace Linux sticky-wire bridge)
#
# =============================================================================
# RECOMMENDED NEXT VPP-NATIVE PROTOTYPE (ordered)
#
#   1. Quiet window: detach ABF, ensure single GW (.1 on loop10 only).
#   2. GARP/ARP refresh on PVE (or arping -U from Digi after cutover).
#   3. Hairpin: tap80/81 + bridge (or memif after plugin enable).
#   4. NAT: in tap81 out digi, table 82 default via pppoe peer digi.
#   5. ACL permit+reflect SYN-only from 79.172.242.0/24 (deny private dst).
#   6. abf policy via 10.254.90.2 tap80 ; abf attach on loop10.
#   7. Verify: public ping .2, PVE curl ipify → Digi CGNAT, UDP/game via GRE.
#   8. Persist in digi-sticky-outbound.sh + pd-gre-activate (.1 stays on loop10).
#
# FALLBACK: always re-run Linux digi-sticky-outbound.sh + arping -U .1
#
# =============================================================================
set -euo pipefail
echo "See header comments in $0 — production path is digi-sticky-outbound.sh"
exit 0
