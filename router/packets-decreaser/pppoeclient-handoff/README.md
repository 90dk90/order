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

## Deploy — one VPP restart only

Approved Digi procedure (exactly **one** `systemctl restart vpp`):

1. Backup live `.so` → install built `.so`
2. `systemctl stop vpp-pppoe-native.service vpp-bootstrap.service` (no VPP restart)
3. `PD_ALLOW_VPP_RESTART=1 systemctl restart vpp` ← **the only restart**
4. `systemctl start vpp-bootstrap.service`
5. `PD_ALLOW_PPPOE_RESTART=1 /usr/local/sbin/pd-pppoe-enable-once.sh`
6. Wait for Digi IPv6, then `/usr/local/sbin/pd-vpp-digi-vxlan-cutover.sh`
7. Update VPS: `DIGI_VTEP=<new> /usr/local/sbin/pd-vpp-digi-vxlan-vps.sh`
8. `/usr/local/sbin/pd-rss-tune.sh`

Confirm: `show plugins` shows `soft-handoff`, `show pppoeclient soft-handoff` → on.

Rollback: restore backup `.so` + one VPP restart, or `set pppoeclient soft-handoff off` (no restart) to disable the feature only.

## Provenance

See `pppoeclient/PROVENANCE.md` (Hi-Jiajun / RaydoNetworks, Apache-2.0). Soft-handoff changes are PD-local on Digi Option B.
