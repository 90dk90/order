<?php

namespace Jexactyl\Jobs\Server;

use Jexactyl\Jobs\Job;
use Jexactyl\Models\Server;
use Illuminate\Support\Facades\Log;
use Illuminate\Queue\SerializesModels;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Symfony\Component\Process\Process;

/**
 * Prefetch the OS qcow2 into the node S3 cache before / during first start.
 */
class PrewarmVmImageJob extends Job implements ShouldQueue
{
    use Dispatchable;
    use InteractsWithQueue;
    use SerializesModels;

    public $tries = 2;

    public $timeout = 7200;

    public function __construct(public Server $server)
    {
    }

    public function handle(): void
    {
        if (!config('jexactyl.vm_prewarm.enabled', true)) {
            return;
        }

        $eggId = (int) config('jexactyl.vm_egg_id', 77);
        if ((int) $this->server->egg_id !== $eggId
            && !str_contains((string) $this->server->image, '1vps-')
            && !str_contains((string) $this->server->image, 'lumenvm')
        ) {
            return;
        }

        $os = $this->resolveOs();
        if ($os === '') {
            Log::warning('1vps-prewarm: cannot resolve OS', ['server_id' => $this->server->id]);
            return;
        }

        $statusDir = (string) config('jexactyl.vm_prewarm.status_dir', '/var/lib/1vps-prewarm');
        @mkdir($statusDir, 0750, true);
        $statusFile = $statusDir . '/' . $this->server->uuid . '.json';
        $this->writeStatus($statusFile, 'running', $os, 'fetching ' . $os);

        $node = $this->server->node;
        $user = (string) config('jexactyl.dedicated_ip_host_sync.ssh_user', 'root');
        $key = (string) config(
            'jexactyl.dedicated_ip_host_sync.ssh_key',
            storage_path('app/dedicated-ip-sync/id_ed25519')
        );
        $override = config('jexactyl.dedicated_ip_host_sync.ssh_host');
        $host = is_string($override) && $override !== '' ? $override : $node->fqdn;
        $timeout = (int) config('jexactyl.vm_prewarm.timeout', 3600);
        $bin = (string) config('jexactyl.vm_prewarm.remote_bin', '/opt/1vps/lumenvm-net/bin/prewarm-cache.sh');
        $remote = sprintf('%s %s', escapeshellarg($bin), escapeshellarg($os));

        if (!is_readable($key)) {
            $this->writeStatus($statusFile, 'failed', $os, 'ssh key unreadable');
            throw new \RuntimeException('prewarm ssh key unreadable');
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

        $out = trim($process->getOutput() . "\n" . $process->getErrorOutput());
        if (!$process->isSuccessful()) {
            $this->writeStatus($statusFile, 'failed', $os, $out);
            Log::error('1vps-prewarm failed', [
                'server_id' => $this->server->id,
                'os' => $os,
                'output' => $out,
            ]);
            throw new \RuntimeException('prewarm failed: ' . $out);
        }

        $this->writeStatus($statusFile, 'ok', $os, $out);
        Log::info('1vps-prewarm ok', ['server_id' => $this->server->id, 'os' => $os]);
    }

    private function resolveOs(): string
    {
        $image = (string) $this->server->image;
        if (preg_match('/1vps-([a-z0-9.-]+)/i', $image, $m)) {
            return strtolower($m[1]);
        }
        // Fallback: docker image tag after last colon
        if (str_contains($image, ':')) {
            $tag = substr($image, strrpos($image, ':') + 1);
            $tag = preg_replace('/^1vps-/', '', $tag) ?? $tag;
            return strtolower((string) $tag);
        }
        return '';
    }

    private function writeStatus(string $file, string $status, string $os, string $detail): void
    {
        @file_put_contents($file, json_encode([
            'status' => $status,
            'os' => $os,
            'detail' => mb_substr($detail, 0, 4000),
            'updated_at' => now()->toIso8601String(),
            'server_id' => $this->server->id,
        ], JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT));
    }
}
