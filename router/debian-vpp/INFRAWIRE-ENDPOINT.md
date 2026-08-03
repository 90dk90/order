# Infrawire / WEDEPLOY GRE endpoint (AS210699)

## Give this to Infrawire

Update the **customer / local GRE IPv6 endpoint** to the live value on the router:

```bash
cat /run/infrawire-vtep.txt
```

Current native Digi WAN pattern (example):

```
2a01:4700:80ff:ffff::6440:8e18
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

Also: `/run/infrawire-endpoint.env`.

## Architecture (native)

GRE outer runs **inside VPP** with underlay directly on Digi:

```
gre0 src=<Digi WAN IPv6> → digi → x520wan → Digi → Infrawire
```

No Linux `ppp0` / `tap30` hairpin for the underlay.

## Important

Digi reassigns CGNAT IPv4 (and therefore the embedded WAN IPv6) whenever PPPoE restarts. **Do not bounce Digi/VPP** just to refresh before they update — freeze the VTEP from `/run/infrawire-vtep.txt`, ask Infrawire, then:

```bash
sudo /usr/local/sbin/infrawire-gre-activate.sh
```

Until then, clients stay online via Digi CGNAT:

```bash
sudo /usr/local/sbin/digi-snat-fallback.sh
```
