import React, { useCallback, useEffect, useMemo, useState } from 'react';
import tw from 'twin.macro';
import {
    Chart as ChartJS,
    CategoryScale,
    LinearScale,
    PointElement,
    LineElement,
    Tooltip,
    Legend,
    Filler,
    type ChartOptions,
} from 'chart.js';
import { Line } from 'react-chartjs-2';
import { FontAwesomeIcon } from '@fortawesome/react-fontawesome';
import {
    faArrowDown,
    faArrowUp,
    faChartPie,
    faGlobe,
    faNetworkWired,
    faSyncAlt,
} from '@fortawesome/free-solid-svg-icons';
import getFirewallTraffic from '@/api/server/firewall/getFirewallTraffic';
import type {
    FirewallProtocolCounter,
    FirewallRuleCounter,
    FirewallTraffic,
    FirewallTrafficSample,
} from '@/api/server/firewall/getFirewallTraffic';
import { CloudUI } from '@/components/hms/cloudUi';
import { HMS } from '@/components/hms/hmsTheme';
import { Alert } from '@/components/elements/alert';
import {
    Badge,
    EmptyState,
    GhostButton,
    MetaLine,
    Panel,
    PanelHeader,
    SegmentedControl,
    SelectField,
    StatCard,
} from '@/components/network/NetworkUi';
import type { NetworkIpRow } from '@/api/network';

ChartJS.register(CategoryScale, LinearScale, PointElement, LineElement, Tooltip, Legend, Filler);

type Direction = 'in' | 'out';
type BreakdownKind = 'ports' | 'peers' | 'protocols' | 'countries';
type RangeKey = '5m' | '15m' | '30m' | '1h' | '3h' | '8h' | '12h' | '24h' | '7d' | '30d';

type BreakdownItem = {
    key: string;
    label: string;
    sub?: string;
    value: number;
    packets: number;
    unit: 'bytes' | 'packets';
};

const REFRESH_MS = 15000;

const RANGES: { id: RangeKey; label: string; seconds: number }[] = [
    { id: '5m', label: '5 min', seconds: 5 * 60 },
    { id: '15m', label: '15 min', seconds: 15 * 60 },
    { id: '30m', label: '30 min', seconds: 30 * 60 },
    { id: '1h', label: '1 h', seconds: 3600 },
    { id: '3h', label: '3 h', seconds: 3 * 3600 },
    { id: '8h', label: '8 h', seconds: 8 * 3600 },
    { id: '12h', label: '12 h', seconds: 12 * 3600 },
    { id: '24h', label: '24 h', seconds: 86400 },
    { id: '7d', label: '7 j', seconds: 7 * 86400 },
    { id: '30d', label: '30 j', seconds: 30 * 86400 },
];

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

const formatPps = (n: number) => {
    if (!Number.isFinite(n) || n <= 0) return '0 pps';
    if (n >= 1000000) return `${(n / 1000000).toFixed(2)} Mpps`;
    if (n >= 1000) return `${(n / 1000).toFixed(1)} Kpps`;
    return `${Math.round(n)} pps`;
};

const samplePps = (h: FirewallTrafficSample, dir: Direction) => {
    if (dir === 'in') return Math.max(0, (h.tcp_in || 0) + (h.udp_in || 0) + (h.icmp_in || 0));
    return Math.max(0, (h.tcp_out || 0) + (h.udp_out || 0) + (h.icmp_out || 0));
};

const protocolBytes = (p: FirewallProtocolCounter, dir: Direction) =>
    Math.max(0, Number(dir === 'in' ? p.bytes_in : p.bytes_out) || 0);

const protocolPackets = (p: FirewallProtocolCounter, dir: Direction) =>
    Math.max(0, Number(dir === 'in' ? p.packets_in : p.packets_out) || 0);

const isWildcardPeer = (ip: string) => {
    const v = ip.trim().toLowerCase();
    return (
        !v ||
        v === '0.0.0.0/0' ||
        v === '0.0.0.0' ||
        v === '::/0' ||
        v === '::' ||
        v === 'any' ||
        v === 'all' ||
        v === '*'
    );
};

const ruleWeight = (r: FirewallRuleCounter) => {
    const bytes = Math.max(0, Number(r.bytes) || 0);
    const packets = Math.max(0, Number(r.packets) || 0);
    // Prefer bytes; fall back to packets when counters only expose packet hits.
    return bytes > 0 ? bytes : packets;
};

const formatTick = (ts: number, range: RangeKey) => {
    const d = new Date(ts * 1000);
    if (range === '7d' || range === '30d') {
        return d.toLocaleDateString('fr-FR', { day: '2-digit', month: 'short' });
    }
    return d.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' });
};

interface Props {
    row: NetworkIpRow;
    prefixLabel: string;
}

export default ({ row, prefixLabel }: Props) => {
    const uuid = row.service?.uuid || '';
    const [loading, setLoading] = useState(false);
    const [refreshing, setRefreshing] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const [traffic, setTraffic] = useState<FirewallTraffic | null>(null);
    const [direction, setDirection] = useState<Direction>('in');
    const [kind, setKind] = useState<BreakdownKind>('protocols');
    const [range, setRange] = useState<RangeKey>('24h');
    const [fetchedAt, setFetchedAt] = useState<number | null>(null);
    const [kindTouched, setKindTouched] = useState(false);

    const load = useCallback(
        async (opts?: { silent?: boolean }) => {
            if (!uuid) {
                setTraffic(null);
                setError(null);
                return;
            }
            const silent = Boolean(opts?.silent);
            if (silent) setRefreshing(true);
            else setLoading(true);
            if (!silent) setError(null);
            try {
                const data = await getFirewallTraffic(uuid);
                setTraffic(data);
                setFetchedAt(Date.now());
                setError(null);
            } catch (e: any) {
                if (!silent) {
                    setTraffic(null);
                    setError(e?.message || 'Impossible de récupérer l’analyse du trafic.');
                }
            } finally {
                setLoading(false);
                setRefreshing(false);
            }
        },
        [uuid]
    );

    useEffect(() => {
        void load();
    }, [load]);

    useEffect(() => {
        if (!uuid) return undefined;
        const id = window.setInterval(() => void load({ silent: true }), REFRESH_MS);
        return () => window.clearInterval(id);
    }, [uuid, load]);

    const protocols = useMemo(() => traffic?.protocols || [], [traffic]);
    const rules = useMemo(() => traffic?.rules || [], [traffic]);

    const filteredHistory = useMemo(() => {
        const history = traffic?.history || [];
        if (!history.length) return [];
        const seconds = RANGES.find((r) => r.id === range)?.seconds ?? 86400;
        const cutoff = Math.floor(Date.now() / 1000) - seconds;
        const sliced = history.filter((h) => (h.t || 0) >= cutoff);
        return sliced.length ? sliced : history.slice(-Math.min(history.length, 120));
    }, [traffic, range]);

    const peaks = useMemo(() => {
        if (!filteredHistory.length) {
            return { inBps: 0, outBps: 0, inPps: 0, outPps: 0 };
        }
        return filteredHistory.reduce(
            (acc, h) => ({
                inBps: Math.max(acc.inBps, h.rx_bps || 0),
                outBps: Math.max(acc.outBps, h.tx_bps || 0),
                inPps: Math.max(acc.inPps, samplePps(h, 'in')),
                outPps: Math.max(acc.outPps, samplePps(h, 'out')),
            }),
            { inBps: 0, outBps: 0, inPps: 0, outPps: 0 }
        );
    }, [filteredHistory]);

    const volumes = useMemo(
        () => ({
            in: protocols.reduce((s, p) => s + protocolBytes(p, 'in'), 0),
            out: protocols.reduce((s, p) => s + protocolBytes(p, 'out'), 0),
            rules: rules.reduce((s, r) => s + ruleWeight(r), 0),
        }),
        [protocols, rules]
    );

    const protocolBreakdown = useMemo((): BreakdownItem[] => {
        const fromApi = protocols
            .map((p) => {
                const bytes = protocolBytes(p, direction);
                const packets = protocolPackets(p, direction);
                return {
                    key: String(p.id || p.label),
                    label: p.label || String(p.id).toUpperCase(),
                    sub: `${packets.toLocaleString('fr-FR')} paquets`,
                    value: bytes > 0 ? bytes : packets,
                    packets,
                    unit: (bytes > 0 ? 'bytes' : 'packets') as 'bytes' | 'packets',
                };
            })
            .filter((x) => x.value > 0);

        if (fromApi.length) {
            return fromApi.sort((a, b) => b.value - a.value).slice(0, 10);
        }

        const fallback: BreakdownItem[] = [
            { key: 'tcp', label: 'TCP', value: Math.max(0, Number(traffic?.tcp) || 0), packets: Math.max(0, Number(traffic?.tcp) || 0), unit: 'packets' as const },
            { key: 'udp', label: 'UDP', value: Math.max(0, Number(traffic?.udp) || 0), packets: Math.max(0, Number(traffic?.udp) || 0), unit: 'packets' as const },
            { key: 'icmp', label: 'ICMP', value: Math.max(0, Number(traffic?.icmp) || 0), packets: Math.max(0, Number(traffic?.icmp) || 0), unit: 'packets' as const },
            { key: 'other', label: 'Autre', value: Math.max(0, Number(traffic?.other) || 0), packets: Math.max(0, Number(traffic?.other) || 0), unit: 'packets' as const },
        ].filter((x) => x.value > 0);

        return fallback.sort((a, b) => b.value - a.value);
    }, [protocols, direction, traffic]);

    const portsBreakdown = useMemo((): BreakdownItem[] => {
        const map = new Map<string, BreakdownItem>();
        rules.forEach((r: FirewallRuleCounter) => {
            const port = Number(r.port) || 0;
            if (port <= 0) return;
            const proto = String(r.protocol || 'any').toUpperCase();
            const key = `${proto}:${port}`;
            const bytes = Math.max(0, Number(r.bytes) || 0);
            const packets = Math.max(0, Number(r.packets) || 0);
            const unit: 'bytes' | 'packets' = bytes > 0 ? 'bytes' : 'packets';
            const value = bytes > 0 ? bytes : packets;
            if (value <= 0) return;
            const prev = map.get(key);
            if (!prev) {
                map.set(key, {
                    key,
                    label: `Port ${port}`,
                    sub: unit === 'bytes' ? proto : `${proto} · paquets`,
                    value,
                    packets,
                    unit,
                });
            } else {
                prev.value += value;
                prev.packets += packets;
                if (bytes > 0) prev.unit = 'bytes';
            }
        });
        return Array.from(map.values())
            .sort((a, b) => b.value - a.value)
            .slice(0, 10);
    }, [rules]);

    const peersBreakdown = useMemo((): BreakdownItem[] => {
        const map = new Map<string, BreakdownItem>();
        rules.forEach((r: FirewallRuleCounter) => {
            const peer = String(r.ip || '').trim();
            if (isWildcardPeer(peer)) return;
            const bytes = Math.max(0, Number(r.bytes) || 0);
            const packets = Math.max(0, Number(r.packets) || 0);
            const unit: 'bytes' | 'packets' = bytes > 0 ? 'bytes' : 'packets';
            const value = bytes > 0 ? bytes : packets;
            if (value <= 0) return;
            const prev = map.get(peer);
            if (!prev) {
                map.set(peer, {
                    key: peer,
                    label: peer,
                    sub: String(r.protocol || r.action || 'rule').toUpperCase(),
                    value,
                    packets,
                    unit,
                });
            } else {
                prev.value += value;
                prev.packets += packets;
                if (bytes > 0) prev.unit = 'bytes';
            }
        });
        return Array.from(map.values())
            .sort((a, b) => b.value - a.value)
            .slice(0, 10);
    }, [rules]);

    const breakdown = useMemo((): BreakdownItem[] => {
        if (kind === 'countries') return [];
        if (kind === 'protocols') return protocolBreakdown;
        if (kind === 'ports') return portsBreakdown;
        return peersBreakdown;
    }, [kind, protocolBreakdown, portsBreakdown, peersBreakdown]);

    // Prefer a breakdown that actually has data on first load.
    useEffect(() => {
        if (!traffic || kindTouched) return;
        const order: BreakdownKind[] = ['protocols', 'ports', 'peers'];
        const has: Record<BreakdownKind, boolean> = {
            protocols: protocolBreakdown.length > 0,
            ports: portsBreakdown.length > 0,
            peers: peersBreakdown.length > 0,
            countries: false,
        };
        if (has[kind]) return;
        const next = order.find((k) => has[k]);
        if (next) setKind(next);
    }, [traffic, kind, kindTouched, protocolBreakdown, portsBreakdown, peersBreakdown]);

    const volumeBase = useMemo(() => {
        if (breakdown.length) return breakdown.reduce((s, x) => s + x.value, 0);
        if (kind === 'protocols') return direction === 'in' ? volumes.in : volumes.out;
        return volumes.rules;
    }, [breakdown, kind, direction, volumes]);

    const lastSample = filteredHistory.length ? filteredHistory[filteredHistory.length - 1] : null;

    const bpsChart = useMemo(
        () => ({
            labels: filteredHistory.map((h) => formatTick(h.t || 0, range)),
            datasets: [
                {
                    label: 'Entrant',
                    data: filteredHistory.map((h) => Number(((h.rx_bps || 0) / 1000000).toFixed(3))),
                    borderColor: '#10b981',
                    backgroundColor: 'rgba(16, 185, 129, 0.14)',
                    fill: true,
                    tension: 0.35,
                    pointRadius: 0,
                    borderWidth: 2,
                },
                {
                    label: 'Sortant',
                    data: filteredHistory.map((h) => Number(((h.tx_bps || 0) / 1000000).toFixed(3))),
                    borderColor: '#34d399',
                    backgroundColor: 'rgba(52, 211, 153, 0.08)',
                    fill: true,
                    tension: 0.35,
                    pointRadius: 0,
                    borderWidth: 2,
                },
            ],
        }),
        [filteredHistory, range]
    );

    const ppsChart = useMemo(
        () => ({
            labels: filteredHistory.map((h) => formatTick(h.t || 0, range)),
            datasets: [
                {
                    label: 'PPS entrant',
                    data: filteredHistory.map((h) => samplePps(h, 'in')),
                    borderColor: '#10b981',
                    backgroundColor: 'rgba(16, 185, 129, 0.14)',
                    fill: true,
                    tension: 0.35,
                    pointRadius: 0,
                    borderWidth: 2,
                },
                {
                    label: 'PPS sortant',
                    data: filteredHistory.map((h) => samplePps(h, 'out')),
                    borderColor: '#34d399',
                    backgroundColor: 'rgba(52, 211, 153, 0.08)',
                    fill: true,
                    tension: 0.35,
                    pointRadius: 0,
                    borderWidth: 2,
                },
            ],
        }),
        [filteredHistory, range]
    );

    const makeChartOptions = (unit: string): ChartOptions<'line'> => ({
        responsive: true,
        maintainAspectRatio: false,
        animation: false,
        interaction: { mode: 'index', intersect: false },
        plugins: {
            legend: {
                display: true,
                position: 'top',
                align: 'end',
                labels: {
                    color: CloudUI.textSecondary,
                    boxWidth: 8,
                    usePointStyle: true,
                    pointStyle: 'circle',
                    font: { size: 11, family: CloudUI.font },
                },
            },
            tooltip: {
                backgroundColor: CloudUI.surface,
                titleColor: CloudUI.text,
                bodyColor: CloudUI.textSecondary,
                borderColor: CloudUI.border,
                borderWidth: 1,
            },
        },
        scales: {
            x: {
                ticks: { color: CloudUI.textMuted, maxTicksLimit: 5, font: { size: 10 } },
                grid: { display: false },
            },
            y: {
                beginAtZero: true,
                ticks: { color: CloudUI.textMuted, font: { size: 10 } },
                grid: { color: 'rgba(148,163,184,0.10)' },
                title: {
                    display: true,
                    text: unit,
                    color: CloudUI.textMuted,
                    font: { size: 10 },
                },
            },
        },
    });

    const bpsOptions = useMemo(() => makeChartOptions('Mbps'), []);
    const ppsOptions = useMemo(() => makeChartOptions('pps'), []);

    const busy = loading && !traffic;
    const kpiValue = (v: string) => (busy ? '…' : v);

    const emptyCopy =
        kind === 'ports'
            ? 'Aucun compteur de port actif pour le moment. Les règles firewall n’ont pas encore de volume mesuré — essayez Protocoles.'
            : kind === 'peers'
              ? 'Aucune pair IP distante dans les règles firewall (souvent uniquement 0.0.0.0/0). Essayez Protocoles ou Ports.'
              : kind === 'countries'
                ? 'Aucune répartition pays disponible.'
                : 'Aucun volume protocole significatif pour ce sens.';

    const formatBreakdownValue = (item: BreakdownItem) => {
        if (item.unit === 'packets') return `${item.value.toLocaleString('fr-FR')} pkt`;
        return formatBytes(item.value);
    };

    if (!uuid) {
        return (
            <EmptyState
                icon={<FontAwesomeIcon icon={faChartPie} />}
                title='Analyse indisponible'
                description='Associez cette IP à un VPS pour analyser le trafic applicatif (ports, pairs, protocoles).'
            />
        );
    }

    return (
        <div css={tw`space-y-5`}>
            <div css={tw`grid gap-3 sm:grid-cols-2 lg:grid-cols-4`}>
                <StatCard
                    label='Pic entrant'
                    value={kpiValue(formatRate(peaks.inBps))}
                    hint='Débit RX max'
                    icon={<FontAwesomeIcon icon={faArrowDown} />}
                />
                <StatCard
                    label='Pic sortant'
                    value={kpiValue(formatRate(peaks.outBps))}
                    hint='Débit TX max'
                    icon={<FontAwesomeIcon icon={faArrowUp} />}
                />
                <StatCard
                    label='Pic PPS entrant'
                    value={kpiValue(formatPps(peaks.inPps))}
                    hint='Paquets / s max'
                    icon={<FontAwesomeIcon icon={faNetworkWired} />}
                />
                <StatCard
                    label='Pic PPS sortant'
                    value={kpiValue(formatPps(peaks.outPps))}
                    hint='Paquets / s max'
                    icon={<FontAwesomeIcon icon={faNetworkWired} />}
                />
            </div>

            <div css={tw`grid gap-3 sm:grid-cols-2`}>
                <StatCard
                    label='Volume entrant'
                    value={kpiValue(formatBytes(volumes.in))}
                    hint='Compteurs protocoles (IN)'
                    icon={<FontAwesomeIcon icon={faChartPie} />}
                    tone='ok'
                />
                <StatCard
                    label='Volume sortant'
                    value={kpiValue(formatBytes(volumes.out))}
                    hint='Compteurs protocoles (OUT)'
                    icon={<FontAwesomeIcon icon={faChartPie} />}
                />
            </div>

            {error ? <Alert type={'danger'}>{error}</Alert> : null}

            <Panel padded>
                <PanelHeader
                    title='Analyse du trafic'
                    description={
                        <>
                            Trafic applicatif pour <span css={tw`font-mono`}>{prefixLabel}</span>
                            {traffic?.interface?.name ? (
                                <>
                                    {' '}
                                    · iface <span css={tw`font-mono`}>{traffic.interface.name}</span>
                                </>
                            ) : null}
                        </>
                    }
                    actions={
                        <div css={tw`flex flex-col sm:flex-row sm:items-center gap-2 w-full lg:w-auto`}>
                            <Badge tone='accent'>
                                <span
                                    css={tw`inline-block h-1.5 w-1.5 rounded-full`}
                                    style={{
                                        background: CloudUI.accent,
                                        boxShadow: refreshing ? `0 0 0 4px ${CloudUI.accentMuted}` : 'none',
                                    }}
                                />
                                Auto 15 s
                            </Badge>
                            <SelectField value={range} onChange={(v) => setRange(v as RangeKey)}>
                                {RANGES.map((r) => (
                                    <option key={r.id} value={r.id}>
                                        {r.label}
                                    </option>
                                ))}
                            </SelectField>
                            <GhostButton
                                compact
                                onClick={() => void load()}
                                disabled={loading || refreshing}
                                title='Actualiser'
                            >
                                <FontAwesomeIcon icon={faSyncAlt} spin={loading || refreshing} /> Actualiser
                            </GhostButton>
                        </div>
                    }
                />

                {busy ? (
                    <div css={tw`flex h-48 items-center justify-center text-sm`} style={{ color: CloudUI.textMuted }}>
                        Chargement…
                    </div>
                ) : !filteredHistory.length ? (
                    <EmptyState
                        icon={<FontAwesomeIcon icon={faChartPie} />}
                        title='Aucune donnée sur la période'
                        description='Le firewall du VPS n’a pas encore d’historique de trafic à afficher.'
                    />
                ) : (
                    <div css={tw`grid gap-4 lg:grid-cols-2`}>
                        <div
                            css={tw`rounded-xl p-3 sm:p-4`}
                            style={{ background: 'rgba(255,255,255,0.02)', border: `1px solid ${HMS.cardBorder}` }}
                        >
                            <p css={tw`mb-3 text-sm font-semibold`} style={{ color: CloudUI.text }}>
                                Débit (BPS)
                            </p>
                            <div css={tw`h-56 w-full`}>
                                <Line data={bpsChart} options={bpsOptions} />
                            </div>
                        </div>
                        <div
                            css={tw`rounded-xl p-3 sm:p-4`}
                            style={{ background: 'rgba(255,255,255,0.02)', border: `1px solid ${HMS.cardBorder}` }}
                        >
                            <p css={tw`mb-3 text-sm font-semibold`} style={{ color: CloudUI.text }}>
                                Paquets (PPS)
                            </p>
                            <div css={tw`h-56 w-full`}>
                                <Line data={ppsChart} options={ppsOptions} />
                            </div>
                        </div>
                    </div>
                )}

                <MetaLine css={tw`mt-4`}>
                    {lastSample
                        ? `Dernier échantillon : ${new Date((lastSample.t || 0) * 1000).toLocaleString('fr-FR')}`
                        : fetchedAt
                          ? `Mis à jour ${new Date(fetchedAt).toLocaleTimeString('fr-FR')}`
                          : 'Actualisation automatique toutes les 15 secondes.'}
                    {' · '}Auto 15 s
                </MetaLine>
            </Panel>

            <Panel padded>
                <PanelHeader
                    title='Répartition du trafic'
                    description={`Volume : ${formatBytes(volumeBase)}`}
                    actions={
                        <div css={tw`flex w-full flex-col gap-2 sm:w-auto`}>
                            <SegmentedControl
                                value={direction}
                                onChange={setDirection}
                                options={[
                                    { id: 'in', label: 'Entrant' },
                                    { id: 'out', label: 'Sortant' },
                                ]}
                            />
                            <SegmentedControl
                                value={kind}
                                onChange={(v) => {
                                    setKindTouched(true);
                                    setKind(v);
                                }}
                                options={[
                                    { id: 'protocols', label: 'Protocoles' },
                                    { id: 'ports', label: 'Ports' },
                                    { id: 'peers', label: 'Pairs IP' },
                                    { id: 'countries', label: 'Pays' },
                                ]}
                            />
                        </div>
                    }
                />

                {kind === 'countries' ? (
                    <EmptyState
                        icon={<FontAwesomeIcon icon={faGlobe} />}
                        title='Aucune répartition pays disponible'
                        description='La géolocalisation du trafic n’est pas disponible. Ports, pairs IP et protocoles restent disponibles.'
                    />
                ) : busy ? (
                    <div css={tw`flex h-40 items-center justify-center text-sm`} style={{ color: CloudUI.textMuted }}>
                        Chargement…
                    </div>
                ) : breakdown.length === 0 ? (
                    <EmptyState
                        icon={<FontAwesomeIcon icon={faChartPie} />}
                        title='Aucune donnée sur la période'
                        description={emptyCopy}
                    />
                ) : (
                    <div css={tw`space-y-2`}>
                        {breakdown.map((item, idx) => {
                            const pct = volumeBase > 0 ? Math.min(100, (item.value / volumeBase) * 100) : 0;
                            return (
                                <div
                                    key={item.key}
                                    css={tw`rounded-xl px-3 py-3`}
                                    style={{ border: `1px solid ${HMS.cardBorder}`, background: 'rgba(255,255,255,0.02)' }}
                                >
                                    <div css={tw`mb-2 flex items-center justify-between gap-3 text-sm`}>
                                        <div css={tw`min-w-0 flex items-center gap-3`}>
                                            <span
                                                css={tw`inline-flex h-7 w-7 flex-shrink-0 items-center justify-center rounded-lg text-xs font-semibold tabular-nums`}
                                                style={{ background: CloudUI.accentMuted, color: CloudUI.accentHover }}
                                            >
                                                {idx + 1}
                                            </span>
                                            <div css={tw`min-w-0`}>
                                                <p css={tw`truncate font-semibold m-0`} style={{ color: CloudUI.text }}>
                                                    {item.label}
                                                </p>
                                                {item.sub ? (
                                                    <p css={tw`truncate text-xs m-0 mt-0.5`} style={{ color: CloudUI.textMuted }}>
                                                        {item.sub}
                                                        {item.packets > 0
                                                            ? ` · ${item.packets.toLocaleString('fr-FR')} paquets`
                                                            : ''}
                                                    </p>
                                                ) : null}
                                            </div>
                                        </div>
                                        <div css={tw`flex-shrink-0 text-right`}>
                                            <p css={tw`font-semibold tabular-nums m-0`} style={{ color: CloudUI.text }}>
                                                {formatBreakdownValue(item)}
                                            </p>
                                            <p css={tw`text-xs tabular-nums m-0 mt-0.5`} style={{ color: CloudUI.textMuted }}>
                                                {pct.toFixed(1)} %
                                            </p>
                                        </div>
                                    </div>
                                    <div css={tw`h-1.5 overflow-hidden rounded-full`} style={{ background: CloudUI.borderSubtle }}>
                                        <div
                                            css={tw`h-full rounded-full transition-all`}
                                            style={{ width: `${pct}%`, background: CloudUI.accent }}
                                        />
                                    </div>
                                </div>
                            );
                        })}
                    </div>
                )}

                {kind !== 'countries' && kind !== 'protocols' ? (
                    <MetaLine css={tw`mt-4`}>
                        Ports et pairs viennent des compteurs de règles firewall. Si les compteurs sont à zéro,
                        basculez sur Protocoles (données snmp). Les IP 0.0.0.0/0 ne sont pas des pairs.
                    </MetaLine>
                ) : kind === 'protocols' ? (
                    <MetaLine css={tw`mt-4`}>
                        Répartition par protocole (TCP/UDP/ICMP…). Le filtre Entrant / Sortant s’applique ici.
                    </MetaLine>
                ) : null}
            </Panel>
        </div>
    );
};
