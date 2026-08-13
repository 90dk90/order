# Thin runtime: keep Lumen base (qemu tools) but run our agent from the host mount.
ARG BASE=ghcr.io/david1117dev/lumenvm:ubuntu-24
FROM ${BASE}
ARG VM_OS=debian-12
ENV VM_OS=${VM_OS}
# Agent + image cache are on /opt/1vps/lumenvm-net (Wings bind-mount).
ENTRYPOINT ["/opt/1vps/lumenvm-net/bin/1vps-vm"]
