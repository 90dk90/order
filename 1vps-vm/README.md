# 1vps-vm

Self-hosted KVM agent replacing LumenVM for Digi / 1VPS.

## Why

LumenVM downloads OS images via `api.lumenvm.cloud` (license + redirects). Debian mirrors hang; Ubuntu often works. This agent downloads from **official mirrors only** and keeps using the existing host TAP / dedicated-IP stack.

## Layout

- `agent/1vps-vm` — container entrypoint
- `scripts/fetch-images.sh` — prefetch cache on the node
- `docker/Dockerfile` — thin image (`ENTRYPOINT` → host-mounted agent)

## Host paths (already mounted by custom Wings)

- `/opt/1vps/lumenvm-net` → container
- `/opt/1vps/lumenvm-net/qemu-system-x86_64` → `/usr/bin/qemu-system-x86_64` (TAP wrapper)
- Cache: `/opt/1vps/lumenvm-net/vm-images/`

## Deploy (node)

```bash
install -m 0755 agent/1vps-vm /opt/1vps/lumenvm-net/bin/1vps-vm
mkdir -p /opt/1vps/lumenvm-net/vm-images
./scripts/fetch-images.sh debian-12 ubuntu-24
docker build -t ghcr.io/david1117dev/lumenvm:1vps-debian-12 --build-arg VM_OS=debian-12 -f docker/Dockerfile .
# set server docker image to ghcr.io/david1117dev/lumenvm:1vps-debian-12 and VM_OS=debian-12
```

## Env (egg)

Same as Lumen egg: `OS_PASSWORD`, `OS_HOSTNAME`, `OS_DISKSIZE`, `ADDITIONAL_PORTS`, `SERVER_IP`, plus `VM_OS`.
