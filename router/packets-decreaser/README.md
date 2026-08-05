# Packets Decreaser — Infrawire-style (Digi/VPP primary)

## Mode
**Digi PPPoE = VPP native** `pppoeclient` on `x520wan`  
**GRE PD = VPP `gre0`** (Digi-observed WAN IPv6 → VPS `2a0e:97c0:4c1::60`)  
**Proximus `enp36s0` = admin only** (Tailscale / SSH / host Internet) — **not** PD GRE underlay  
**Linux FOU GRE** = abandoned for PD primary (optional emergency only)

Digi may publish `807f`, `817f`, or `80ff` as `wan-ipv6 observed`. Use whatever Digi observes — when Digi publishes it, PD can reach it inbound (~12 ms).

## Why this again
Infrawire was stable with PPPoE+GRE inside VPP when config was **immutable**.  
Crashes came from live FIB/GRE/tap churn (sticky, lan-prepare del loops, watchdogs).

## Restore on Digi
```bash
sudo install -m 755 pd-restore-infrawire.sh /usr/local/sbin/
sudo /usr/local/sbin/pd-restore-infrawire.sh
sudo PD_FORCE_SYNC=1 /usr/local/sbin/pd-gre-activate.sh
```

## Stability rules
1. `pd-lan-prepare.sh` / `pd-gre-activate.sh` are soft — **skip if already OK** (no route-del storm)
2. Classic `pd-gre-watchdog.timer` only reacts when Digi VTEP changes / gre0 down
3. Never enable `pd-gre-watchdog-linux.timer` in this mode
4. Do not recreate PPPoE just because IPv6 is missing
5. No sticky / ABF / classify — all dedicated traffic via VPP `gre0` only
6. VPS `pd-gre-lan-hosts.sh` whitelists live LAN `/32` into gre-pd and blackholes unused `/24` locally (BGP still announces `/24`) — stops scanner flood into GRE

## VPS
When Digi VTEP is known:
```bash
/usr/local/sbin/pd-gre-set-vtep.sh <digi-wan-ipv6>
```
(ip6gre, `GRE_FOU=0`)

## Roles
| Path | Role |
|------|------|
| Digi → VPP GRE → VPS | Dedicated `/24` (PD) |
| Proximus → Tailscale | Keep admin access if Digi flaps |
| Host default via Proximus | OK — must not steal PD table 81 |
