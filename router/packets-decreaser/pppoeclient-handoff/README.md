# pppoeclient soft-handoff (Digi Option B)

Vendored [Hi-Jiajun/vpp-pppoeclient](https://github.com/Hi-Jiajun/vpp-pppoeclient) at commit in `UPSTREAM_COMMIT` (matches Digi `vpp-pppoeclient-plugins` `492cdef`), plus a **soft worker handoff after PPPoE session unwrap**.

## Why

Digi WAN PPPoE (`0x8864`) always lands on `x520wan` **rx_q0 → one worker**. Stock plugin runs `ip6-input → vxlan6-…` on that same worker → ~2.5–2.8 Gbps ceiling and `rx-miss` under load. Hardware RSS cannot hash past PPPoE.

Option B spreads **post-PPPoE** IP4/IP6 work across workers via VPP frame queues.

## Behaviour

After `pppoeclient-session-input` unwraps a session frame:

| Payload | Action |
|---|---|
| IPv4 / IPv6 | 5-tuple hash → frame-queue to `ip4-input` / `ip6-input` on another worker (same worker stays local, no FQ) |
| PPP control (LCP/IPCP/…) | stays on the RX worker → `pppox-input` |

CLI (runtime, no VPP restart):

```text
show pppoeclient soft-handoff
set pppoeclient soft-handoff on|off
show error | grep HANDOFF
```

Default: **on** when `workers > 1`.

Counters: `HANDOFF_IP4`, `HANDOFF_IP6`, `HANDOFF_CONGESTION_DROP`.

## Build (Digi, compile only)

Needs Digi `vpp-dev` / matching `26.06-release` headers plus:

```bash
apt-get install -y cmake build-essential python3-ply
```

Rebuild is **ABI248-native** (no `pd-pppoeclient-abi-patch.sh`).

```bash
# from this directory, on Digi:
./pd-pppoeclient-handoff-build.sh
# → /tmp/pd-pppoeclient-handoff/pppoeclient_plugin.so
```

Or manually:

```bash
cmake -S . -B /tmp/pd-pppoeclient-handoff-build -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/pd-pppoeclient-handoff-build -j"$(nproc)"
```

## Deploy — wait for approval

**Do not** install or restart VPP until explicitly approved (flaps Digi PPPoE).

When approved (step 2.4):

1. Backup live `.so`
2. Install built `.so` to `/usr/lib/x86_64-linux-gnu/vpp_plugins/pppoeclient_plugin.so`
3. `PD_ALLOW_VPP_RESTART=1 systemctl restart vpp`
4. Re-arm Digi PPPoE / VXLAN path (`pd-vpp-prox-vxlan-activate.sh` / cutover scripts)
5. Confirm: `show plugins` description contains `soft-handoff`, `show pppoeclient soft-handoff`

Rollback: restore backup `.so` + one VPP restart, or `set pppoeclient soft-handoff off` (no restart) if only disabling the feature.

## Provenance

See `pppoeclient/PROVENANCE.md` (Hi-Jiajun / RaydoNetworks, Apache-2.0). Soft-handoff changes are PD-local on Digi Option B.
