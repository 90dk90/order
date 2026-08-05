#!/bin/bash
# VPS: set GRE remote to Digi IPv6 OR Proximus IPv4 (auto-detect).
set -euo pipefail
NEW="${1:?usage: pd-gre-set-vtep.sh <remote-v4-or-v6>}"
ENV=/etc/pd-gre.env
touch "$ENV"
grep -q '^LOCAL_VTEP=' "$ENV" 2>/dev/null || echo 'LOCAL_VTEP=2a0e:97c0:4c1::60' >> "$ENV"
grep -q '^LOCAL_VTEP_V4=' "$ENV" 2>/dev/null || echo 'LOCAL_VTEP_V4=77.90.4.48' >> "$ENV"
grep -q '^INNER_LOCAL=' "$ENV" 2>/dev/null || echo 'INNER_LOCAL=172.16.207.1/30' >> "$ENV"
grep -q '^INNER_PEER=' "$ENV" 2>/dev/null || echo 'INNER_PEER=172.16.207.2' >> "$ENV"
if grep -q '^DIGI_VTEP=' "$ENV"; then
  sed -i "s|^DIGI_VTEP=.*|DIGI_VTEP=$NEW|" "$ENV"
else
  echo "DIGI_VTEP=$NEW" >> "$ENV"
fi
# Track family for gre-pd builder
if [[ "$NEW" == *:* ]]; then
  if grep -q '^GRE_FAMILY=' "$ENV"; then sed -i 's|^GRE_FAMILY=.*|GRE_FAMILY=ip6|' "$ENV"
  else echo 'GRE_FAMILY=ip6' >> "$ENV"; fi
else
  if grep -q '^GRE_FAMILY=' "$ENV"; then sed -i 's|^GRE_FAMILY=.*|GRE_FAMILY=ip4|' "$ENV"
  else echo 'GRE_FAMILY=ip4' >> "$ENV"; fi
fi
/usr/local/sbin/pd-gre-to-digi.sh
