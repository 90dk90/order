<?php
/**
 * Optional drop-in: ensure OS_DISKSIZE tracks servers.disk for egg 77.
 * Prefer config/jexactyl.php environment_variables mapping instead.
 *
 * Deploy note: Panel already injects OS_DISKSIZE via:
 *   'OS_DISKSIZE' => 'disk',
 *   'SERVER_DISK' => 'disk',
 * in config/jexactyl.php → environment_variables.
 */
