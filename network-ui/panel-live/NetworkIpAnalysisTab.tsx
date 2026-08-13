import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { FontAwesomeIcon } from '@fortawesome/react-fontawesome';
import { faChartPie, faExclamationTriangle, faSyncAlt } from '@fortawesome/free-solid-svg-icons';
import getFirewallTraffic, {
    FirewallProtocolCounter,
    FirewallRuleCounter,
    FirewallTraffic,
} from '@/api/server/firewall/getFirewallTraffic';
import { NetworkIpRow } from '@/api/network';
import { CloudUI, cloudPanelStyle } from '@/components/hms/cloudUi';
import { EmptyState, Panel } from '@/components/network/NetworkUi';

type Props = {
    row: NetworkIpRow;
    prefixLabel: string;
};

type Direction = 'in' | 'out';
type BreakdownKind = 'ports' | 'peers' | 'protocols';

type BreakdownItem = {
    key: string;
    label: string;
    sub?: string;
    value: number;
};

const formatBytes = (n: number) => {
    if (!Number.isFinite(n) || n <= 0) return '0 o';
    const units = ['o', 'Ko', 'Mo', 'Go', 'To'];
    let v = n;
    let i = 0;
    while (v >= 1000 && i < units.length - 1) {
        v /= 1000;
        i += 1;
    }
    return `${v >= 100 ? v.toFixed(0) : v.toFixed(1)} ${units[i]}`;
};

const formatRate = (bps: number) => {
    if (!Number.isFinite(bps) || bps <= 0) return '0 bps';
    const units = ['bps', 'Kbps', 'Mbps', 'Gbps'];
    let v = bps;
    let i = 0;
    while (v >= 1000 && i < units.length - 1) {
        v /= 1000;
        i += 1;
    }
    return `${v >= 100 ? v.toFixed(0) : v.toFixed(1)} ${units[i]}`;
};

const protocolBytes = (p: FirewallProtocolCounter, dir: Direction) =>
    Math.max(0, Number(dir === 'in' ? p.bytes_in : p.bytes_out) || 0);

const protocolPackets = (p: FirewallProtocolCounter, dir: Direction) =>
    Math.max(0, Number(dir === 'in' ? p.packets_in : p.packets_out) || 0);

const NetworkIpAnalysisTab = ({ row, prefixLabel }: Props) => {
    const uuid = row.service?.uuid || '';
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const [traffic, setTraffic] = useState<FirewallTraffic | null>(null);
    const [direction, setDirection] = useState<Direction>('in');
    const [kind, setKind] = useState<BreakdownKind>('protocols');

    const load = useCallback(async () => {
        if (!uuid) {
            setTraffic(null);
            setError(null);
            return;
        }
        setLoading(true);
        setError(null);
        try {
            const data = await getFirewallTraffic(uuid);
            setTraffic(data);
        } catch (e: any) {
            setTraffic(null);
            setError(e?.message || 'Impossible de récupérer l’analyse du trafic.');
        } finally {
            setLoading(false);
        }
    }, [uuid]);

    useEffect(() => {
        void load();
    }, [load]);

    const protocols = useMemo(() => traffic?.protocols || [], [traffic]);
    const rules = useMemo(() => traffic?.rules || [], [traffic]);

    const totals = useMemo(() => {
        const protocolTotal = protocols.reduce((sum, p) => sum + protocolBytes(p, direction), 0);
        const ruleTotal = rules.reduce((sum, r) => sum + Math.max(0, Number(r.bytes) || 0), 0);
        return {
            protocol: protocolTotal,
            rules: ruleTotal,
            ifaceRx: Math.max(0, Number(traffic?.interface?.rx_bps) || 0),
            ifaceTx: Math.max(0, Number(traffic?.interface?.tx_bps) || 0),
        };
    }, [protocols, rules, direction, traffic]);

    const breakdown = useMemo((): BreakdownItem[] => {
        if (kind === 'protocols') {
            return protocols
                .map((p) => ({
                    key: String(p.id),
                    label: p.label || String(p.id).toUpperCase(),
                    sub: `${protocolPackets(p, direction).toLocaleString('fr-FR')} paquets`,
                    value: protocolBytes(p, direction),
                }))
                .filter((x) => x.value > 0)
                .sort((a, b) => b.value - a.value)
                .slice(0, 10);
        }
        if (kind === 'ports') {
            const map = new Map<string, BreakdownItem>();
            rules.forEach((r: FirewallRuleCounter) => {
                const port = Number(r.port) || 0;
                if (port <= 0) return;
                const key = `${String(r.protocol || 'any').toLowerCase()}:${port}`;
                const prev = map.get(key);
                const value = Math.max(0, Number(r.bytes) || 0);
                if (!prev) {
                    map.set(key, {
                        key,
                        label: `Port ${port}`,
                        sub: String(r.protocol || 'any').toUpperCase(),
                        value,
                    });
                } else {
                    prev.value += value;
                }
            });
            return Array.from(map.values())
                .filter((x) => x.value > 0)
                .sort((a, b) => b.value - a.value)
                .slice(0, 10);
        }
        const map = new Map<string, BreakdownItem>();
        rules.forEach((r: FirewallRuleCounter) => {
            const peer = String(r.ip || '').trim();
            if (!peer) return;
            const prev = map.get(peer);
            const value = Math.max(0, Number(r.bytes) || 0);
            if (!prev) {
                map.set(peer, {
                    key: peer,
                    label: peer,
                    sub: String(r.action || r.protocol || 'rule'),
                    value,
                });
            } else {
                prev.value += value;
            }
        });
        return Array.from(map.values())
            .filter((x) => x.value > 0)
            .sort((a, b) => b.value - a.value)
            .slice(0, 10);
    }, [kind, protocols, rules, direction]);

    const volumeBase = kind === 'protocols' ? totals.protocol : totals.rules;
    const chip = (active: boolean) =>
        `inline-flex items-center rounded-md border px-2.5 py-1 text-xs font-semibold transition ${
            active
                ? 'border-transparent text-white'
                : 'border-[var(--border)] text-[var(--muted)] hover:bg-[var(--hover)] hover:text-[var(--text)]'
        }`;

    if (!uuid) {
        return (
            <EmptyState
                icon={<FontAwesomeIcon icon={faChartPie} />}
                title="Analyse indisponible"
                description="Associez cette IP à un VPS pour analyser le trafic applicatif (ports, pairs, protocoles)."
            />
        );
    }

    return (
        <div className={'space-y-5'}>
            <div className={'flex flex-wrap items-start justify-between gap-3'}>
                <div className={'min-w-0'}>
                    <h2 className={'text-base font-semibold'} style={{ color: CloudUI.text }}>
                        Analyse du trafic
                    </h2>
                    <p className={'mt-1 text-sm'} style={{ color: CloudUI.textMuted }}>
                        Trafic applicatif pour <span className={'font-mono'}>{prefixLabel}</span>
                        {traffic?.interface?.name ? (
                            <span>
                                {' '}
                                · iface <span className={'font-mono'}>{traffic.interface.name}</span>
                            </span>
                        ) : null}
                    </p>
                </div>
                <button
                    type={'button'}
                    onClick={() => void load()}
                    disabled={loading}
                    className={'inline-flex h-9 items-center gap-2 rounded-md border px-3 text-xs font-semibold disabled:opacity-50'}
                    style={{ borderColor: CloudUI.border, color: CloudUI.text, background: CloudUI.surface }}
                >
                    <FontAwesomeIcon icon={faSyncAlt} className={loading ? 'animate-spin' : undefined} />
                    Actualiser
                </button>
            </div>

            <div className={'grid gap-3 sm:grid-cols-2 lg:grid-cols-4'}>
                {[
                    { label: 'Volume entrant (proto)', value: formatBytes(protocols.reduce((s, p) => s + protocolBytes(p, 'in'), 0)) },
                    { label: 'Volume sortant (proto)', value: formatBytes(protocols.reduce((s, p) => s + protocolBytes(p, 'out'), 0)) },
                    { label: 'Débit iface RX', value: formatRate(totals.ifaceRx) },
                    { label: 'Débit iface TX', value: formatRate(totals.ifaceTx) },
                ].map((card) => (
                    <div
                        key={card.label}
                        className={'rounded-lg border p-4'}
                        style={{
                            borderColor: CloudUI.border,
                            background: CloudUI.surface,
                            boxShadow: cloudPanelStyle.boxShadow as string,
                        }}
                    >
                        <p className={'text-[11px] font-semibold uppercase tracking-wide'} style={{ color: CloudUI.textMuted }}>
                            {card.label}
                        </p>
                        <p className={'mt-2 text-xl font-bold tabular-nums'} style={{ color: CloudUI.accent }}>
                            {loading && !traffic ? '…' : card.value}
                        </p>
                    </div>
                ))}
            </div>

            {error ? (
                <div
                    className={'flex items-start gap-2 rounded-lg border px-3 py-2 text-sm'}
                    style={{ borderColor: 'rgba(239,68,68,0.35)', background: 'rgba(239,68,68,0.12)', color: CloudUI.danger }}
                >
                    <FontAwesomeIcon icon={faExclamationTriangle} className={'mt-0.5'} />
                    <span>{error}</span>
                </div>
            ) : null}

            <Panel padded>
                <div className={'mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between'}>
                    <div>
                        <h3 className={'text-sm font-semibold'} style={{ color: CloudUI.text }}>
                            Répartition du trafic
                        </h3>
                        <p className={'mt-1 text-xs'} style={{ color: CloudUI.textMuted }}>
                            Volume sur la période : {formatBytes(volumeBase)}
                        </p>
                    </div>
                    <div className={'flex flex-wrap gap-2'} style={{ ['--border' as any]: CloudUI.border, ['--muted' as any]: CloudUI.textMuted, ['--hover' as any]: CloudUI.surfaceHover, ['--text' as any]: CloudUI.text }}>
                        <button type={'button'} className={chip(direction === 'in')} style={direction === 'in' ? { background: CloudUI.accent } : undefined} onClick={() => setDirection('in')}>
                            Entrant
                        </button>
                        <button type={'button'} className={chip(direction === 'out')} style={direction === 'out' ? { background: CloudUI.accent } : undefined} onClick={() => setDirection('out')}>
                            Sortant
                        </button>
                        <span className={'mx-1 h-6 w-px bg-current opacity-20'} />
                        <button type={'button'} className={chip(kind === 'protocols')} style={kind === 'protocols' ? { background: CloudUI.accent } : undefined} onClick={() => setKind('protocols')}>
                            Protocoles
                        </button>
                        <button type={'button'} className={chip(kind === 'ports')} style={kind === 'ports' ? { background: CloudUI.accent } : undefined} onClick={() => setKind('ports')}>
                            Ports
                        </button>
                        <button type={'button'} className={chip(kind === 'peers')} style={kind === 'peers' ? { background: CloudUI.accent } : undefined} onClick={() => setKind('peers')}>
                            Pairs IP
                        </button>
                    </div>
                </div>

                {loading && !traffic ? (
                    <div className={'flex h-40 items-center justify-center text-sm'} style={{ color: CloudUI.textMuted }}>
                        Chargement…
                    </div>
                ) : breakdown.length === 0 ? (
                    <EmptyState
                        icon={<FontAwesomeIcon icon={faChartPie} />}
                        title="Aucune donnée sur la période"
                        description="Aucun volume significatif pour ce filtre. Actualisez ou changez le type de répartition."
                    />
                ) : (
                    <div className={'space-y-2'}>
                        {breakdown.map((item) => {
                            const pct = volumeBase > 0 ? Math.min(100, (item.value / volumeBase) * 100) : 0;
                            return (
                                <div key={item.key} className={'rounded-md border px-3 py-2.5'} style={{ borderColor: CloudUI.borderSubtle, background: CloudUI.bg }}>
                                    <div className={'mb-1.5 flex items-center justify-between gap-3 text-sm'}>
                                        <div className={'min-w-0'}>
                                            <p className={'truncate font-semibold'} style={{ color: CloudUI.text }}>
                                                {item.label}
                                            </p>
                                            {item.sub ? (
                                                <p className={'truncate text-xs'} style={{ color: CloudUI.textMuted }}>
                                                    {item.sub}
                                                </p>
                                            ) : null}
                                        </div>
                                        <div className={'flex-shrink-0 text-right'}>
                                            <p className={'font-semibold tabular-nums'} style={{ color: CloudUI.text }}>
                                                {formatBytes(item.value)}
                                            </p>
                                            <p className={'text-xs tabular-nums'} style={{ color: CloudUI.textMuted }}>
                                                {pct.toFixed(1)} %
                                            </p>
                                        </div>
                                    </div>
                                    <div className={'h-1.5 overflow-hidden rounded-full'} style={{ background: CloudUI.borderSubtle }}>
                                        <div className={'h-full rounded-full'} style={{ width: `${pct}%`, background: CloudUI.accent }} />
                                    </div>
                                </div>
                            );
                        })}
                    </div>
                )}
            </Panel>
        </div>
    );
};

export default NetworkIpAnalysisTab;
