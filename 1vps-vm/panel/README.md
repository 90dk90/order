# Panel drop-ins for 1vps-vm

Deploy onto `dash.1vps.cc` (Jexactyl).

| File | Target |
|------|--------|
| `Controllers/NoVncController.php` | `app/Http/Controllers/Api/Client/Servers/` |
| `Services/HotRamSyncService.php` | `app/Services/Servers/` |
| `Jobs/PrewarmVmImageJob.php` | `app/Jobs/Server/` |
| `ExternalConsole.tsx` | `resources/scripts/components/server/` |
| `scripts/novnc-proxy.py` | `/usr/local/sbin/1vps-novnc-proxy` |
| `nginx/1vps-novnc-proxy.service` | `/etc/systemd/system/` |
| `nginx/novnc-location.conf` | include in `panel.conf` |
| `jexactyl-vm-config.php` | merge into `config/jexactyl.php` |

Hooks (already applied on dash in this rollout):

- Route `GET /api/client/servers/{server}/novnc`
- `ServerCreationService` → `PrewarmVmImageJob::dispatch`
- `ServerEditService` / `BuildModificationService` → `HotRamSyncService` on memory change

Env:

```
NOVNC_PROXY_SECRET=...
NOVNC_PROXY_ENABLED=true
HOT_RAM_ENABLED=true
VM_PREWARM_ENABLED=true
JEXACTYL_VM_EGG_ID=77
DEDICATED_IP_SSH_HOST=100.64.96.103
```

Frontend: `NODE_ENV=production yarn/webpack build` (dev mode fails on unrelated eqeqeq lint).
