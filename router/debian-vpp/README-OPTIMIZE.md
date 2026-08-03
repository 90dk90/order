# Digi / Infrawire softpath optimization (AS219084)

## Bottleneck

GRE underlay still hairpins through Linux:

`gre0 → tap30 → vpp6-host → ppp0 → vpp-pppoe → tap20 → x520wan`

Symptoms before this pass:

- ~1M `softnet` drops on **CPU0 only**
- `tap20-tx no free tx slots` under load
- Infrawire UL ~2.5–2.6G vs Digi local ~6G UL

Root cause: VPP workers pinned to CPUs **1–5**, Linux softpath forced onto **CPU0 alone**.

## Changes applied (live)

1. **VPP workers `2-5`** — free **CPU1** for Linux RPS/XPS/`pppd`
2. **Linux affinity `0-1`** (`rps/xps=03`) on `ppp0`, `vpp-pppoe`, `vpp6-host`
3. **TAP rings 4096**, **4 queues** (match 4 workers)
4. **DPDK RX/TX desc 4096**, 4 queues
5. Stronger sysctl (backlog / budget / BBR / buffers)
6. GRUB prepared: `isolcpus=2-5 nohz_full=2-5 rcu_nocbs=2-5` (**needs reboot**)
7. Infrawire GRE scripts now follow live Digi PD from `/run/vpp-tap30-ipv6.env`

## Action required: Infrawire VTEP

Digi reassigns the delegated `/56` on each PPPoE reconnect. After the VPP restart used to apply CPU/ring changes, the PD left `2a01:4700:8080:6400::/56`.

- Underlay ping to `2a10:4646:500::1` works with the **current** PD
- GRE/BGP stay down until Infrawire updates the customer GRE endpoint to the **current** VPP VTEP (`VXLAN_LOCAL_IP6` in `/run/vpp-tap30-ipv6.env`, currently `…::2` on tap30)

Prefer registering Infrawire on a **stable** Digi address if they can (or ask Digi for a static PD). Avoid bouncing `pppoe-vpp` unless necessary.

## Ceiling without redesign

Softpath + single-threaded `pppd` will not match Digi-local ~6G UL through GRE.
To approach ~4G+ Infrawire UL (peer capability), move **PPPoE into VPP** (no Linux hairpin).

## BIOS (optional, reboot)

- Enable **Precision Boost / PBO** (CPU stuck ~3.6 GHz, no cpufreq sysfs)
- Enable **SMT** → 12 threads → more Linux softirq CPUs without cutting VPP workers

## Files on router

- `/etc/vpp/startup.conf`
- `/usr/local/sbin/vpp-bootstrap.sh`
- `/usr/local/sbin/vpp-performance-tuning.sh`
- `/usr/local/sbin/vpp-rx-placement.sh`
- `/usr/local/sbin/infrawire-vpp-exit.sh`
- `/usr/local/sbin/infrawire-gre-up.sh`
- `/etc/sysctl.d/99-vpp-softpath.conf`
- `/etc/default/grub` (isolcpus — reboot to apply)
