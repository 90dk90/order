#!/bin/bash
set -euo pipefail
NEW="${1:?usage: pd-gre-set-vtep.sh <digi-ipv6>}"
ENV=/etc/pd-gre.env
touch "$ENV"
grep -q '^LOCAL_VTEP=' "$ENV" 2>/dev/null || echo 'LOCAL_VTEP=2a0e:97c0:4c1::60' >> "$ENV"
grep -q '^INNER_LOCAL=' "$ENV" 2>/dev/null || echo 'INNER_LOCAL=172.16.207.1/30' >> "$ENV"
grep -q '^INNER_PEER=' "$ENV" 2>/dev/null || echo 'INNER_PEER=172.16.207.2' >> "$ENV"
if grep -q '^DIGI_VTEP=' "$ENV"; then
  sed -i "s|^DIGI_VTEP=.*|DIGI_VTEP=$NEW|" "$ENV"
else
  echo "DIGI_VTEP=$NEW" >> "$ENV"
fi
/usr/local/sbin/pd-gre-to-digi.sh
