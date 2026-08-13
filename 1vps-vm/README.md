# 1vps-vm

Self-hosted KVM agent replacing LumenVM for Digi / 1VPS.

## Image source (Hetzner S3)

Bucket: `1vps-vm-images` @ `https://fsn1.your-objectstorage.com`

Objects are **public-read**:
`https://fsn1.your-objectstorage.com/1vps-vm-images/<os>.qcow2`

Override base URL with env `VM_IMAGE_BASE`.

Sync (on the Wings node, with `/root/.1vps-s3.env`):

```bash
/opt/1vps/lumenvm-net/bin/sync-images-to-s3.sh
# or from repo:
./scripts/sync-images-to-s3.sh
```

Warm local cache from S3:

```bash
./scripts/fetch-images.sh debian-12 ubuntu-24
```

## Host stack reused

- QEMU wrapper → TAP + virtio-net + DHCP `10.0.2.15`
- `lumen-autoballoon` (QMP)
- `lumen-dedicated-ip-forward`

## Layout

- `agent/1vps-vm` — container entrypoint
- `scripts/fetch-images.sh` — pull from S3 → host cache
- `scripts/sync-images-to-s3.sh` — mirrors → S3
- `docker/Dockerfile` — thin image (`ENTRYPOINT` → host-mounted agent)

## Deploy

```bash
install -m 0755 agent/1vps-vm /opt/1vps/lumenvm-net/bin/1vps-vm
install -m 0755 scripts/*.sh /opt/1vps/lumenvm-net/bin/
docker build --build-arg VM_OS=debian-12 -t ghcr.io/david1117dev/lumenvm:1vps-debian-12 -f docker/Dockerfile docker
```
