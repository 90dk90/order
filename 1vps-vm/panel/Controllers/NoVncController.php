<?php

namespace Jexactyl\Http\Controllers\Api\Client\Servers;

use Illuminate\Http\JsonResponse;
use Jexactyl\Models\Server;
use Jexactyl\Http\Controllers\Api\Client\ClientApiController;
use Jexactyl\Http\Requests\Api\Client\Servers\GetServerRequest;

/**
 * Return HTTPS-safe noVNC embed URL for 1vps-vm DISPLAY_MODE=novnc|vnc.
 */
class NoVncController extends ClientApiController
{
    public function __invoke(GetServerRequest $request, Server $server): JsonResponse
    {
        $server->loadMissing(['allocation', 'allocations']);

        // Query the relation builder (not a possibly-stale eager collection) so
        // server_variables.variable_value AS server_value is present.
        $variable = $server->variables()->where('env_variable', 'DISPLAY_MODE')->first();
        $mode = strtolower((string) (
            ($variable->server_value ?? null) ?: ($variable->default_value ?? '') ?: 'ssh'
        ));

        $allocation = $server->allocation;
        $ip = $allocation?->ip;
        $novncPort = 6080;
        $vncPort = 5900;

        if (!$ip) {
            $ip = optional($server->allocations->first())->ip;
        }

        $direct = $ip ? sprintf('http://%s:%d/vnc.html?autoconnect=1&resize=remote', $ip, $novncPort) : null;

        $embed = null;
        $expires = null;
        if ($ip && filter_var(config('jexactyl.novnc_proxy.enabled', true), FILTER_VALIDATE_BOOLEAN)) {
            $mapDir = (string) config('jexactyl.novnc_proxy.map_dir', storage_path('app/1vps-novnc/map'));
            if (!is_dir($mapDir)) {
                @mkdir($mapDir, 0750, true);
            }
            $mapFile = rtrim($mapDir, '/') . '/' . $server->uuid;
            $upstream = $ip . ':' . $novncPort;
            if (@file_put_contents($mapFile, $upstream) === false) {
                $fallback = storage_path('app/1vps-novnc/map');
                if (!is_dir($fallback)) {
                    @mkdir($fallback, 0750, true);
                }
                @file_put_contents($fallback . '/' . $server->uuid, $upstream);
            } else {
                @chmod($mapFile, 0640);
            }

            $ttl = (int) config('jexactyl.novnc_proxy.ttl', 43200);
            $expires = time() + $ttl;
            $secret = (string) config('jexactyl.novnc_proxy.secret', config('app.key'));
            $token = hash_hmac('sha256', $server->uuid . '|' . $expires . '|' . $upstream, $secret);
            $embed = sprintf(
                '/1vps-novnc/%s/%d/%s/vnc.html?autoconnect=1&resize=remote&path=%s',
                $server->uuid,
                $expires,
                $token,
                rawurlencode(sprintf('1vps-novnc/%s/%d/%s/websockify', $server->uuid, $expires, $token))
            );
        }

        return new JsonResponse([
            'mode' => $mode ?: 'ssh',
            'available' => in_array($mode, ['novnc', 'vnc'], true) && (bool) $ip,
            'ip' => $ip,
            'novnc_port' => $novncPort,
            'vnc_port' => $vncPort,
            'direct_url' => $direct,
            'embed_url' => $embed,
            'expires_at' => $expires,
        ]);
    }
}
