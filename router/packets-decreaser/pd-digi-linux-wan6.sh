#!/bin/bash
# Assign Digi-observed style WAN IPv6 on ppp0 (IPv4 embedded in Digi /64).
# Digi typically does not SLAAC a GUA onto ppp0 — we synthesize:
#   2a01:4700:{807f|817f|80ff}:ffff::<ipv4-as-hex>
set -euo pipefail
IFACE=${IFACE:-ppp0}
[ -d "/sys/class/net/$IFACE" ] || exit 0
IP4=$(ip -4 -o addr show dev "$IFACE" | awk '{print $4}' | head -1 | cut -d/ -f1)
[ -n "$IP4" ] || exit 0
H=$(python3 -c "import ipaddress; h=format(int(ipaddress.IPv4Address(\"$IP4\")),\"08x\"); print(h[:4]+\":\"+h[4:])")
# Prefer last known good prefix, then probe
PREF_FILE=/run/pd-digi-v6-prefix.txt
CAND=()
[ -f "$PREF_FILE" ] && CAND+=("$(tr -d ' \r\n' <"$PREF_FILE")")
CAND+=(807f 817f 80ff)
for p in "${CAND[@]}"; do
  [ -n "$p" ] || continue
  A="2a01:4700:${p}:ffff::${H}"
  ip -6 addr replace "$A/64" dev "$IFACE"
  if ping -6 -c1 -W2 -I "$A" 2a0e:97c0:4c1::60 >/dev/null 2>&1; then
    echo "$p" >"$PREF_FILE"
    echo "$A" >/run/pd-digi-vtep.txt
    echo "$A" >/run/pd-vxlan-digi-vtep.txt
    echo "pd-digi-linux-wan6: $A (prefix $p)"
    # Re-arm Linux VXLAN when Digi GUA changes (no VPP/PPPoE restart)
    if [ "${PD_WAN6_REARM_VXLAN:-1}" = "1" ] && [ -x /usr/local/sbin/pd-linux-vxlan-digi-activate.sh ]; then
      /usr/local/sbin/pd-linux-vxlan-digi-activate.sh || true
    fi
    exit 0
  fi
  ip -6 addr del "$A/64" dev "$IFACE" 2>/dev/null || true
done
echo "pd-digi-linux-wan6: no Digi prefix answered PD VTEP" >&2
exit 1
