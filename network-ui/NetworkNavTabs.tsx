import { Link } from 'react-router-dom';

import { cn } from '@/lib/utils';

const TABS = [
    { to: '/network/ips', label: 'Adresses IP', match: (p: string) => p.startsWith('/network/ips') },
    { to: '/network/ddos', label: 'Attaques DDoS', match: (p: string) => p.startsWith('/network/ddos') || p.startsWith('/network/attacks') },
] as const;

/**
 * Navigation secondaire Réseau — alignée console Infrawire
 * (« Adresses IP » / « Attaques DDoS »).
 */
export function NetworkNavTabs({ pathname }: { pathname: string }) {
    return (
        <div className='-mb-px flex flex-wrap gap-1 border-b border-zinc-200 dark:border-zinc-800'>
            {TABS.map((tab) => {
                const active = tab.match(pathname);
                return (
                    <Link
                        key={tab.to}
                        to={tab.to}
                        aria-current={active ? 'page' : undefined}
                        className={cn(
                            'inline-flex items-center gap-2 rounded-t-lg border-b-2 px-4 py-3 text-sm font-semibold transition',
                            active
                                ? 'border-brand text-brand dark:border-emerald-400 dark:text-emerald-300'
                                : 'border-transparent text-zinc-500 hover:border-zinc-300 hover:text-zinc-800 dark:text-zinc-400 dark:hover:border-zinc-700 dark:hover:text-zinc-200',
                        )}
                    >
                        {tab.label}
                    </Link>
                );
            })}
        </div>
    );
}
