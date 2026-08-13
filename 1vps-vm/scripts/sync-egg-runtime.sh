#!/bin/bash
# Sync 1vps-vm egg runtime: disk size + graphical display allocations.
set -euo pipefail

mysql --default-character-set=utf8mb4 panel <<'SQL'
UPDATE server_variables sv
JOIN egg_variables ev ON ev.id = sv.variable_id
JOIN servers s ON s.id = sv.server_id
SET sv.variable_value = CAST(s.disk AS CHAR), sv.updated_at = NOW()
WHERE ev.env_variable = 'OS_DISKSIZE' AND ev.egg_id = 77
  AND sv.variable_value <> CAST(s.disk AS CHAR);

UPDATE server_variables sv
JOIN egg_variables ev ON ev.id = sv.variable_id
SET sv.variable_value = '', sv.updated_at = NOW()
WHERE ev.egg_id = 77 AND ev.env_variable = 'LICENSE'
  AND sv.variable_value <> '';
SQL

CHANGED_IDS=()

mapfile -t rows < <(mysql --default-character-set=utf8mb4 -N panel -e "
SELECT s.id, a.node_id, a.ip,
  COALESCE((
    SELECT sv.variable_value FROM server_variables sv
    JOIN egg_variables ev ON ev.id=sv.variable_id
    WHERE sv.server_id=s.id AND ev.env_variable='DISPLAY_MODE' LIMIT 1
  ), 'ssh')
FROM servers s
JOIN allocations a ON a.id = s.allocation_id
WHERE s.egg_id = 77;
")

for row in "${rows[@]:-}"; do
  [[ -z "$row" ]] && continue
  sid=$(awk '{print $1}' <<<"$row")
  node_id=$(awk '{print $2}' <<<"$row")
  ip=$(awk '{print $3}' <<<"$row")
  mode=$(awk '{print tolower($4)}' <<<"$row")
  ports=""
  case "$mode" in
    vnc) ports="5900" ;;
    novnc) ports="5900 6080" ;;
    spice) ports="5901" ;;
    *) continue ;;
  esac
  for p in $ports; do
    exists=$(mysql --default-character-set=utf8mb4 -N panel -e \
      "SELECT id FROM allocations WHERE server_id=${sid} AND ip='${ip}' AND port=${p} LIMIT 1;")
    [[ -n "$exists" ]] && continue

    free=$(mysql --default-character-set=utf8mb4 -N panel -e \
      "SELECT id FROM allocations WHERE server_id IS NULL AND ip='${ip}' AND port=${p} LIMIT 1;")
    if [[ -n "$free" ]]; then
      mysql --default-character-set=utf8mb4 panel -e \
        "UPDATE allocations SET server_id=${sid}, updated_at=NOW() WHERE id=${free};"
      echo "bound ${ip}:${p} -> server ${sid}"
      CHANGED_IDS+=("$sid")
      continue
    fi

    taken=$(mysql --default-character-set=utf8mb4 -N panel -e \
      "SELECT id FROM allocations WHERE ip='${ip}' AND port=${p} LIMIT 1;")
    if [[ -n "$taken" ]]; then
      echo "skip ${ip}:${p} taken"
      continue
    fi
    mysql --default-character-set=utf8mb4 panel -e \
      "INSERT INTO allocations (node_id, ip, port, server_id, created_at, updated_at)
       VALUES (${node_id}, '${ip}', ${p}, ${sid}, NOW(), NOW());"
    echo "created ${ip}:${p} -> server ${sid}"
    CHANGED_IDS+=("$sid")
  done
done

# Wings must republish Docker DNAT for new display ports (otherwise noVNC is unreachable).
if [[ "${#CHANGED_IDS[@]}" -gt 0 && -f /var/www/jexactyl/artisan ]]; then
  uniq_ids=$(printf '%s\n' "${CHANGED_IDS[@]}" | awk 'NF && !a[$0]++' | tr '\n' ' ')
  echo "syncing Wings for servers: ${uniq_ids}"
  cd /var/www/jexactyl
  IDS="$uniq_ids" php -r '
require "vendor/autoload.php";
$app = require "bootstrap/app.php";
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
$ids = array_values(array_unique(array_filter(array_map("intval", preg_split("/\s+/", getenv("IDS") ?: "")))));
$svc = $app->make(Jexactyl\Services\Allocations\LumenVmNetworkService::class);
foreach ($ids as $id) {
  $s = Jexactyl\Models\Server::query()->with(["allocation","egg","allocations"])->find($id);
  if (!$s) continue;
  try {
    $svc->afterChange($s, true);
    echo "wings-sync ok server={$id}\n";
  } catch (Throwable $e) {
    echo "wings-sync fail server={$id}: ".$e->getMessage()."\n";
  }
}
'
fi
