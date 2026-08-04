#!/bin/bash
# Research notes — Digi VPP-native sticky (Aug 2026).
# Production: digi-sticky-outbound.sh (mode=vpp-classify).
# Fallback:   digi-sticky-outbound-linux.sh (mode=linux) — do not use unless asked.
#
# =============================================================================
# PRODUCTION (vpp-classify) — NO ABF
#
#   GW .1 on loop10 BVI / table 81 → default gre0
#   ip4-inacl classify on loop10:
#     TCP sport ∈ SERVICE_PORTS → fib 81 (GRE) — inbound service replies
#     other TCP                 → fib 82 → tap80↔tap81 / table 83 → NAT44 → digi
#     UDP/ICMP                  → fib 81 → gre0
#
# =============================================================================
# HARD LESSONS
#
# 1) ABF on BVI loop10 CRASHES under traffic (SIGSEGV in abf_plugin.so, VPP 26.06).
#    Crash loop via pd-gre-activate sticky reapply. Do NOT attach ABF on loop10.
#    Clean attach can survive idle; traffic triggers null deref.
#
# 2) ACL create with "index N" fails if ACL N does not exist yet
#    ("Trying to replace nonexistent ACL"). Create without index, or ensure exists.
#
# 3) classify session match hex MUST include skip_n_vectors padding
#    (16 bytes per skip unit, ignored). Without pad: silent no-op / 1 session.
#
# 4) Stickiness: flags alone cannot tell client ACK vs server ACK.
#    ABF permit+reflect would, but ABF crashes. Proxy: service sports → GRE,
#    ephemeral client sports → Digi. Extend SERVICE_PORTS as needed.
#
# 5) Safe NAT: "set interface nat44 ei in tap81 out digi" (inside-vrf Digi table).
#    Never "in digi out digi output-feature".
#
# 6) GW cutover needs GARP — PVE neigh must move to BVI MAC de:ad:00:00:00:0a.
#
# 7) vppctl output has CR (\r) — strip before awk parsing table indices.
#
# =============================================================================
set -euo pipefail
echo "See header in $0 — production is digi-sticky-outbound.sh mode=vpp-classify"
exit 0
