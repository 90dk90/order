#!/usr/bin/env python3
"""HTTPS-safe noVNC reverse proxy for dash.1vps.cc.

Map files: /var/lib/1vps-novnc/map/<uuid>  →  "IP:PORT"
Tokens:    HMAC-SHA256(uuid|exp|ip:port, secret) hex, exp unix ts

Listen: 127.0.0.1:18080
Path:   /1vps-novnc/<uuid>/<exp>/<token>/...
"""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import os
import urllib.parse
from pathlib import Path

MAP_DIR = Path(os.environ.get("NOVNC_MAP_DIR", "/var/lib/1vps-novnc/map"))
SECRET = os.environ.get("NOVNC_PROXY_SECRET", "").encode()
LISTEN_HOST = os.environ.get("NOVNC_PROXY_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("NOVNC_PROXY_PORT", "18080"))
TOKEN_MAX_AGE = int(os.environ.get("NOVNC_TOKEN_MAX_AGE", "86400"))


def log(msg: str) -> None:
    print(msg, flush=True)


def verify(uuid: str, exp: str, token: str, upstream: str) -> bool:
    if not SECRET:
        return False
    try:
        exp_i = int(exp)
    except ValueError:
        return False
    import time

    now = int(time.time())
    if exp_i < now or exp_i > now + TOKEN_MAX_AGE + 3600:
        return False
    payload = f"{uuid}|{exp}|{upstream}".encode()
    expect = hmac.new(SECRET, payload, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expect, token)


def upstream_for(uuid: str) -> str | None:
    p = MAP_DIR / uuid
    if not p.is_file():
        return None
    raw = p.read_text(encoding="utf-8").strip()
    if not raw or ":" not in raw:
        return None
    host, _, port = raw.rpartition(":")
    if not host or not port.isdigit():
        return None
    return f"{host}:{port}"


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def handle(client_reader: asyncio.StreamReader, client_writer: asyncio.StreamWriter) -> None:
    try:
        req = await client_reader.readuntil(b"\r\n\r\n")
    except Exception:
        client_writer.close()
        return

    try:
        head = req.decode("latin1")
        first = head.split("\r\n", 1)[0]
        method, path, _ = first.split(" ", 2)
    except Exception:
        client_writer.close()
        return

    # /1vps-novnc/<uuid>/<exp>/<token>/rest
    parts = path.split("?", 1)[0].strip("/").split("/")
    if len(parts) < 4 or parts[0] != "1vps-novnc":
        client_writer.write(b"HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n")
        await client_writer.drain()
        client_writer.close()
        return

    uuid, exp, token = parts[1], parts[2], parts[3]
    rest = "/".join(parts[4:]) if len(parts) > 4 else ""
    qs = ""
    if "?" in path:
        qs = "?" + path.split("?", 1)[1]

    upstream = upstream_for(uuid)
    if not upstream or not verify(uuid, exp, token, upstream):
        client_writer.write(b"HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n")
        await client_writer.drain()
        client_writer.close()
        return

    host, port_s = upstream.rsplit(":", 1)
    port = int(port_s)
    target_path = "/" + rest + qs if rest else "/" + qs.lstrip("?")
    if target_path == "/":
        target_path = "/vnc.html"
    if rest == "" and not qs:
        target_path = "/vnc.html?autoconnect=1&resize=remote"

    try:
        up_reader, up_writer = await asyncio.open_connection(host, port)
    except Exception as e:
        log(f"upstream connect fail {upstream}: {e}")
        client_writer.write(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
        await client_writer.drain()
        client_writer.close()
        return

    # Rewrite request line + Host
    lines = head.split("\r\n")
    lines[0] = f"{method} {target_path} HTTP/1.1"
    out_headers = []
    for line in lines[1:]:
        if not line:
            continue
        low = line.lower()
        if low.startswith("host:"):
            out_headers.append(f"Host: {upstream}")
        elif low.startswith("connection:") and "upgrade" in low:
            out_headers.append(line)
        elif low.startswith("upgrade:") or low.startswith("sec-websocket"):
            out_headers.append(line)
        elif low.startswith("origin:"):
            continue
        else:
            out_headers.append(line)
    if not any(h.lower().startswith("host:") for h in out_headers):
        out_headers.append(f"Host: {upstream}")
    new_req = (lines[0] + "\r\n" + "\r\n".join(out_headers) + "\r\n\r\n").encode("latin1")
    # If client sent extra body after headers in first read — rare for GET
    extra = b""
    # req already includes \r\n\r\n; body would be after — we used readuntil so no body yet

    up_writer.write(new_req)
    await up_writer.drain()

    async def client_to_up() -> None:
        await pipe(client_reader, up_writer)

    async def up_to_client() -> None:
        await pipe(up_reader, client_writer)

    await asyncio.gather(client_to_up(), up_to_client())


async def main() -> None:
    if not SECRET:
        log("WARN: NOVNC_PROXY_SECRET empty — all tokens rejected")
    MAP_DIR.mkdir(parents=True, exist_ok=True)
    server = await asyncio.start_server(handle, LISTEN_HOST, LISTEN_PORT)
    log(f"1vps-novnc-proxy on {LISTEN_HOST}:{LISTEN_PORT} map={MAP_DIR}")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
