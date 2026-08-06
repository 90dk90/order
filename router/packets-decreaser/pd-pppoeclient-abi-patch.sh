#!/bin/bash
# Patch Hi-Jiajun pppoeclient_plugin.so for official FDio VPP 26.06-release.
#
# Stock debs are built against VPP 26.06-rc0 where sizeof(vnet_device_class_t)=240.
# FDio 26.06-release grew that struct to 248 (+vnet_tm_sys_impl). The plugin indexes
# device_classes with imul $0xf0, so format_device becomes garbage (often 0x1) and
# save_session → get_linux_ifname → format() SIGSEGVs during PPPoE discovery.
#
# This rewrites both imul sites to $0xf8 (248) and keeps the IPv6CP /128 (ll128) byte.
# Requires ONE VPP restart to reload the .so. Does not restart VPP itself.
set -euo pipefail

SO="${PPPOECLIENT_SO:-/usr/lib/x86_64-linux-gnu/vpp_plugins/pppoeclient_plugin.so}"
TS=$(date +%Y%m%d%H%M%S)

if [ ! -f "$SO" ]; then
  echo "pd-pppoeclient-abi-patch: missing $SO" >&2
  exit 1
fi

python3 - "$SO" "$TS" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
ts = sys.argv[2]
data = bytearray(p.read_bytes())
pat = bytes.fromhex("4869c5f0000000")  # imul $0xf0,%rbp,%rax
rep = bytes.fromhex("4869c5f8000000")  # imul $0xf8,%rbp,%rax

def find_all(blob, needle):
    out, i = [], 0
    while True:
        j = blob.find(needle, i)
        if j < 0:
            return out
        out.append(j)
        i = j + 1

old = find_all(data, pat)
new = find_all(data, rep)
if not old and len(new) == 2:
    print(f"pd-pppoeclient-abi-patch: already ABI248 ({p})")
    raise SystemExit(0)
if len(old) != 2:
    raise SystemExit(
        f"expected 2 imul $0xf0 sites (or 2 already-patched $0xf8), "
        f"found old={len(old)} new={len(new)} at {[hex(x) for x in old]}"
    )

bak = Path(f"{p}.bak-pre-abi248-{ts}")
bak.write_bytes(bytes(data))
root_bak = Path(f"/root/pppoeclient_plugin.so.bak-pre-abi248-{ts}")
try:
    root_bak.write_bytes(bytes(data))
except OSError:
    pass

for j in old:
    data[j : j + 7] = rep
# ll128: IPv6CP link-local prefix length 64→128 (single-byte site used on Digi)
off = 280244
if off < len(data) and data[off] == 64:
    data[off] = 128
p.write_bytes(data)
if find_all(data, pat) or len(find_all(data, rep)) != 2:
    p.write_bytes(bak.read_bytes())
    raise SystemExit("verify failed — restored backup")
print(f"pd-pppoeclient-abi-patch: OK — backup {bak}")
print(f"  patched sites {[hex(x) for x in old]} -> stride 248")
print("  Reload with ONE planned: PD_ALLOW_VPP_RESTART=1 systemctl restart vpp")
print("  Then re-arm: /usr/local/sbin/pd-vpp-prox-vxlan-activate.sh (or digi cutover path)")
PY
md5sum "$SO"
