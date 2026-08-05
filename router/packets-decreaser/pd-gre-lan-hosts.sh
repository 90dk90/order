#!/bin/bash
# Route full dedicated /24 into gre-pd (no blackhole).
# BGP announces 79.172.242.0/24; all addresses are reachable via Digi when GRE is up.
set -euo pipefail
ENV=/etc/pd-gre.env
[ -f "$ENV" ] && . "$ENV"
PEER="${INNER_PEER:-172.16.207.2}"
ip route del blackhole 79.172.242.0/24 2>/dev/null || true
for h in 79.172.242.1 79.172.242.2 79.172.242.3 79.172.242.10; do
  ip route del "$h/32" 2>/dev/null || true
done
ip route replace 79.172.242.0/24 via "$PEER" dev gre-pd
echo "pd-gre-lan-hosts: 79.172.242.0/24 via $PEER gre-pd (full prefix)"
