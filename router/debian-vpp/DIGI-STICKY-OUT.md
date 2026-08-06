# Digi sticky outbound (native PPPoE + VXLAN)

## Goal

- **Outbound bulk TCP** (apt, speedtest, curl): Digi CGNAT SNAT — low latency / high BW
- **Inbound + game UDP + service TCP replies**: PD `/24` via VXLAN — players keep `79.172.242.x`

## Design (`mode=vpp-classify-ephemeral+except`)

```
loop10 classify chain:
  1) src exceptions  → fib 81 PD
  2) dst/domain except → fib 81 PD
  3) TCP sport >= 32768 → fib 82 → hairpin → NAT → digi
  miss → fib 81 PD (VXLAN /24)
```

### User whitelist

Edit on Digi: `/etc/pd/digi-sticky-except.conf`

```
src 79.172.242.3          # FROM this IP → always PD
dst 1.2.3.4               # TO this IP → always PD
domain api.lumenvm.cloud   # resolve A → dst (timer refreshes every 15m)
```

Reload without tearing sticky:

```bash
/usr/local/sbin/digi-sticky-except-reload.sh
```

NAT must **not** sit on BVI `loop10`. Hairpin taps keep NAT on `tap81`.

**Never** on enable/disable: `ip route del` on LAN covers, `set interface ip table loop10`,
delete `loop10` addresses — those SIGSEGV VPP 26.06 (`fib_table_lookup_exact_match`).

## Enable (Digi)

```bash
install -m755 digi-sticky-outbound.sh digi-sticky-disable.sh /usr/local/sbin/
install -m644 digi-sticky-outbound.service /etc/systemd/system/
systemctl daemon-reload
PD_ENABLE_STICKY=1 /usr/local/sbin/digi-sticky-outbound.sh --force
systemctl enable digi-sticky-outbound.service
```

No intentional VPP/PPPoE restart.

## Disable

```bash
/usr/local/sbin/digi-sticky-disable.sh
# or: systemctl stop digi-sticky-outbound.service
```

## Live results (2026-08-06, PVE `1vps`)

| Metric | Digi sticky out | Prior PD-only (approx) |
|--------|-----------------|------------------------|
| Egress IP | Digi public `188.209.103.232` (CGNAT `100.64.149.232`) | `79.172.242.2` |
| Ookla down/up | **7.2G / 6.2G** (edpnet BRU) | ~2–4G Internet |
| Ookla ping | **1.5 ms** | ~12 ms via PD |
| GW RTT under load | **0.05 ms, 0% loss** | flat (unchanged) |
| CF RTT under load | ~12 ms, 0% loss | bloated under PD saturation |
| Inbound `https://79.172.242.2/` | 200 from VPS | OK |

## Verify

```bash
curl -4 -s ifconfig.me          # Digi public (not 79.172.242.2)
ping -c 20 79.172.242.1         # ~0.05ms flat
# from outside / VPS:
curl -sk -o /dev/null -w "%{http_code}\n" https://79.172.242.2/
```
