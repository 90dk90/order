<?php

namespace Jexactyl\Http\Controllers\Api\Client\Servers;

use Illuminate\Http\JsonResponse;
use Illuminate\Support\Facades\File;
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
        $mode = strtolower((string) optional(
            $server->variables->firstWhere('env_variable', 'DISPLAY_MODE')
        )->server_value);

        $allocation = $server->allocation;
        $ip = $allocation?->ip;
        $novncPort = 6080;
        $vncPort = 5900;

        // Prefer dedicated IP; fall back to first non-null allocation.
        if (!$ip) {
            $ip = optional($server->allocations->first())->ip;
        }

        $direct = $ip ? sprintf('http://%s:%d/vnc.html?autoconnect=1&resize=remote', $ip, $novncPort) : null;

        $embed = null;
        $expires = null;
        if ($ip && config('jexactyl.novnc_proxy.enabled', true)) {
            $mapDir = (string) config('jexactyl.novnc_proxy.map_dir', '/var/lib/1vps-novnc/map');
            File::ensureDirectoryExists($mapDir, 0750);
            File::put($mapDir . '/' . $server->uuid, $ip . ':' . $novncPort);

            $ttl = (int) config('jexactyl.novnc_proxy.ttl', 43200);
            $expires = time() + $ttl;
            $upstream = $ip . ':' . $novncPort;
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
