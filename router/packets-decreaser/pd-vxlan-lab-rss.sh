#!/bin/sh
# Measure Digi X520 RX queue spread (RSS) for a few seconds.
# Run while lab traffic is flowing (ping flood / iperf over 172.16.208.0/30).
set -eu
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
IFACE="${1:-x520wan}"
SECS="${2:-5}"

snap() {
  $VPP show hardware-interfaces "$IFACE" 2>/dev/null
}

echo "pd-vxlan-lab-rss: sampling $IFACE for ${SECS}s"
B1=$(snap)
sleep "$SECS"
B2=$(snap)

python3 - "$B1" "$B2" <<'PY'
import re,sys
def qs(s):
    return {int(a): int(b) for a,b in re.findall(r"rx_q(\d+)_packets\s+(\d+)", s)}
q1,q2 = qs(sys.argv[1]), qs(sys.argv[2])
keys=sorted(set(q1)|set(q2))
print("queue  delta   share")
tot=0
deltas={}
for q in keys:
    d=max(0, q2.get(q,0)-q1.get(q,0))
    deltas[q]=d
    tot+=d
if tot==0:
    print("(no RX during sample)")
    sys.exit(0)
for q in keys:
    d=deltas[q]
    print(f"rx_q{q}  +{d:<6} {100.0*d/tot:5.1f}%")
print(f"total +{tot}")
nused=sum(1 for d in deltas.values() if d>0)
print(f"queues_used={nused}")
PY
