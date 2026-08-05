# Packets Decreaser — Infrawire-style (Digi/VPP primary)

## Mode
**Digi PPPoE = VPP native** `pppoeclient` on `x520wan`  
**GRE PD = VPP `gre0`** (Digi IPv6 VTEP `807f`/`817f` → VPS `2a0e:97c0:4c1::60`)  
**Proximus `enp36s0` = admin only** (Tailscale / SSH / host Internet) — **not** PD GRE underlay  
**Linux FOU GRE** = abandoned for PD primary (optional emergency only)

## Why this again
Infrawire was stable with PPPoE+GRE inside VPP when config was **immutable**.  
Crashes came from live FIB/GRE/tap churn (sticky, lan-prepare del loops, watchdogs).

## Restore on Digi
```bash
sudo install -m 755 pd-restore-infrawire.sh /usr/local/sbin/
sudo /usr/local/sbin/pd-restore-infrawire.sh
# When Digi publishes real wan-ipv6 807f/817f:
sudo PD_FORCE_SYNC=1 /usr/local/sbin/pd-gre-activate.sh
```

## Stability rules
1. `pd-lan-prepare.sh` is soft — **skip if already OK** (no route-del storm)
2. Classic `pd-gre-watchdog.timer` only reacts when Digi VTEP appears / gre0 down
3. Never enable `pd-gre-watchdog-linux.timer` in this mode
4. Do not recreate PPPoE just because IPv6 is missing

## VPS
When Digi VTEP is known:
```bash
/usr/local/sbin/pd-gre-set-vtep.sh <digi-807f-addr>
```
(ip6gre, `GRE_FOU=0`)

## Roles
| Path | Role |
|------|------|
| Digi → VPP GRE → VPS | Dedicated `/24` (PD) |
| Proximus → Tailscale | Keep admin access if Digi flaps |
| Host default via Proximus | OK — must not steal PD table 81 |
