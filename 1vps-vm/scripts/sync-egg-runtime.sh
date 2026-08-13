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
  done
done
