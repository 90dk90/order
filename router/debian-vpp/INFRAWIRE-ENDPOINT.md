# Infrawire / WEDEPLOY GRE endpoint (AS210699)

## Give this to Infrawire

Update the **customer / local GRE IPv6 endpoint** to:

```
2a01:4700:8086:be00::2
```

Remote stays:

```
2a10:4646:500::1
```

Inner `/30` unchanged:

```
172.16.206.2/30  ↔  172.16.206.1
BGP: AS219084 ↔ AS210699
```

Live copy on router: `/run/infrawire-vtep.txt` and `/run/infrawire-endpoint.env`.

## Important

Digi reassigns the delegated `/56` whenever PPPoE restarts. **Do not bounce `pppoe-vpp` / VPP** just to “refresh” the address before they update - freeze this VTEP, ask Infrawire, then run:

```
sudo /usr/local/sbin/infrawire-gre-activate.sh
```

Until then, client default can stay on Digi CGNAT:

```
sudo /usr/local/sbin/digi-snat-fallback.sh
```
