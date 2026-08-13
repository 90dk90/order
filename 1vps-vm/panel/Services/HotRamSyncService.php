<?php

namespace Jexactyl\Services\Servers;

use Jexactyl\Models\Node;
use Jexactyl\Models\Server;
use Illuminate\Support\Facades\Log;
use Symfony\Component\Process\Process;

/**
 * Ask the Wings node to hot-adjust guest RAM via QMP (1vps-hot-ram).
 */
class HotRamSyncService
{
    public function syncSafe(Server $server, ?int $targetMemoryMb = null): void
    {
        try {
            $this->sync($server, $targetMemoryMb);
        } catch (\Throwable $e) {
            Log::warning('1vps-hot-ram sync failed', [
                'server_id' => $server->id,
                'error' => $e->getMessage(),
            ]);
        }
    }

    public function sync(Server $server, ?int $targetMemoryMb = null): string
    {
        if (!config('jexactyl.hot_ram.enabled', true)) {
            return 'hot_ram disabled';
        }

        if (!$this->isVmServer($server)) {
            return 'not a 1vps-vm egg';
        }

        $target = $targetMemoryMb ?? (int) $server->memory;
        // Mirror agent headroom so balloon/hotplug target matches guest usable RAM.
        $guest = $this->guestTargetMib($target);
        $uuid = $server->uuid;

        /** @var Node $node */
        $node = $server->node;
        $user = (string) config('jexactyl.dedicated_ip_host_sync.ssh_user', 'root');
        $key = (string) config(
            'jexactyl.dedicated_ip_host_sync.ssh_key',
            storage_path('app/dedicated-ip-sync/id_ed25519')
        );
        $override = config('jexactyl.dedicated_ip_host_sync.ssh_host');
        $host = is_string($override) && $override !== '' ? $override : $node->fqdn;
        $timeout = (int) config('jexactyl.hot_ram.timeout', 45);
        $remote = sprintf(
            '/usr/local/sbin/1vps-hot-ram %s %d',
            escapeshellarg($uuid),
            $guest
        );

        if (!is_readable($key)) {
            throw new \RuntimeException('SSH key unreadable for hot-ram: ' . $key);
        }

        $knownHosts = dirname($key) . '/known_hosts';
        if (!is_dir(dirname($knownHosts))) {
            @mkdir(dirname($knownHosts), 0750, true);
        }
        if (!file_exists($knownHosts)) {
            @touch($knownHosts);
            @chmod($knownHosts, 0644);
        }

        $sshBin = is_executable('/usr/bin/ssh') ? '/usr/bin/ssh' : 'ssh';
        $process = new Process([
            $sshBin,
            '-i', $key,
            '-o', 'BatchMode=yes',
            '-o', 'IdentitiesOnly=yes',
            '-o', 'StrictHostKeyChecking=accept-new',
            '-o', 'UserKnownHostsFile=' . $knownHosts,
            '-o', 'ConnectTimeout=15',
            sprintf('%s@%s', $user, $host),
            $remote,
        ]);
        $process->setTimeout($timeout);
        $env = getenv() ?: [];
        if (!is_array($env)) {
            $env = [];
        }
        $env['HOME'] = dirname($key);
        $process->setEnv($env);
        $process->run();

        if (!$process->isSuccessful()) {
            throw new \RuntimeException(trim($process->getErrorOutput() . ' ' . $process->getOutput()) ?: 'hot-ram ssh failed');
        }

        return trim($process->getOutput());
    }

    private function isVmServer(Server $server): bool
    {
        $eggId = (int) config('jexactyl.vm_egg_id', 77);
        if ((int) $server->egg_id === $eggId) {
            return true;
        }
        $image = (string) $server->image;
        return str_contains($image, '1vps-') || str_contains($image, 'lumenvm');
    }

    private function guestTargetMib(int $serverMemory): int
    {
        $overhead = match (true) {
            $serverMemory <= 2048 => 256,
            $serverMemory <= 4096 => 384,
            $serverMemory <= 8192 => 768,
            default => 1024,
        };
        if ($serverMemory > $overhead + 512) {
            return $serverMemory - $overhead;
        }
        return $serverMemory;
    }
}
