<?php
/**
 * Snippet to merge into config/jexactyl.php (before the closing ];).
 */
return [
    'vm_egg_id' => (int) env('JEXACTYL_VM_EGG_ID', 77),

    'novnc_proxy' => [
        'enabled' => env('NOVNC_PROXY_ENABLED', true),
        'map_dir' => env('NOVNC_MAP_DIR', '/var/lib/1vps-novnc/map'),
        'secret' => env('NOVNC_PROXY_SECRET', env('APP_KEY')),
        'ttl' => (int) env('NOVNC_PROXY_TTL', 43200),
    ],

    'hot_ram' => [
        'enabled' => env('HOT_RAM_ENABLED', true),
        'timeout' => (int) env('HOT_RAM_SSH_TIMEOUT', 45),
    ],

    'vm_prewarm' => [
        'enabled' => env('VM_PREWARM_ENABLED', true),
        'timeout' => (int) env('VM_PREWARM_TIMEOUT', 3600),
        'remote_bin' => env('VM_PREWARM_BIN', '/opt/1vps/lumenvm-net/bin/prewarm-cache.sh'),
        'status_dir' => env('VM_PREWARM_STATUS_DIR', '/var/lib/1vps-prewarm'),
    ],
];
