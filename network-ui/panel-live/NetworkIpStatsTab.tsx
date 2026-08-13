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
import { faArrowDown, faArrowUp, faTachometerAlt, faSyncAlt } from '@fortawesome/free-solid-svg-icons';
import getFirewallTraffic from '@/api/server/firewall/getFirewallTraffic';
import type { FirewallTraffic } from '@/api/server/firewall/getFirewallTraffic';
import { CloudUI } from '@/components/hms/cloudUi';
import { HMS } from '@/components/hms/hmsTheme';
import {
    Badge,
    EmptyState,
    GhostButton,
    MetaLine,
    Panel,
    PanelHeader,
    SegmentedControl,
    StatCard,
} from '@/components/network/NetworkUi';
import type { NetworkIpRow } from '@/api/network';

ChartJS.register(CategoryScale, LinearScale, PointElement, LineElement, Tooltip, Legend, Filler);

type RangeKey = '1h' | '24h' | '7d' | '30d' | '6m';

const REFRESH_MS = 15000;

const RANGES: { id: RangeKey; label: string; seconds: number }[] = [
    { id: '1h', label: '1 h', seconds: 3600 },
    { id: '24h', label: '24 h', seconds: 86400 },
    { id: '7d', label: '7 j', seconds: 7 * 86400 },
    { id: '30d', label: '30 j', seconds: 30 * 86400 },
    { id: '6m', label: '6 mois', seconds: 180 * 86400 },
];

function formatMbps(bps: number): string {
    if (!Number.isFinite(bps) || bps <= 0) return '0 Mbps';
    const mbps = bps / 1000000;
    if (mbps < 0.01) return `${(bps / 1000).toFixed(1)} Kbps`;
    if (mbps < 10) return `${mbps.toFixed(2)} Mbps`;
    if (mbps < 1000) return `${mbps.toFixed(1)} Mbps`;
    return `${(mbps / 1000).toFixed(2)} Gbps`;
}

function percentile95(values: number[]): number {
    if (!values.length) return 0;
    const sorted = [...values].sort((a, b) => a - b);
    const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil(0.95 * sorted.length) - 1));
    return sorted[idx] ?? 0;
}

function formatTick(ts: number, range: RangeKey): string {
    const d = new Date(ts * 1000);
    if (range === '1h' || range === '24h') {
        return d.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' });
    }
    return d.toLocaleDateString('fr-FR', { day: '2-digit', month: 'short' });
}

interface Props {
    row: NetworkIpRow;
    prefixLabel: string;
}

export default ({ row, prefixLabel }: Props) => {
    const uuid = row.service?.uuid || null;
    const [range, setRange] = useState<RangeKey>('24h');
    const [loading, setLoading] = useState(false);
    const [refreshing, setRefreshing] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const [traffic, setTraffic] = useState<FirewallTraffic | null>(null);
    const [fetchedAt, setFetchedAt] = useState<number | null>(null);

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
                    setError(e?.message || 'Impossible de récupérer les statistiques.');
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

    const filteredHistory = useMemo(() => {
        const history = traffic?.history || [];
        if (!history.length) return [];
        const seconds = RANGES.find((r) => r.id === range)?.seconds ?? 86400;
        const cutoff = Math.floor(Date.now() / 1000) - seconds;
        const sliced = history.filter((h) => (h.t || 0) >= cutoff);
        return sliced.length ? sliced : history.slice(-Math.min(history.length, 120));
    }, [traffic, range]);

    const metrics = useMemo(() => {
        if (!filteredHistory.length) {
            return {
                latestOut: 0,
                latestIn: 0,
                peakOut: 0,
                peakIn: 0,
                avgOut: 0,
                avgIn: 0,
                p95: 0,
            };
        }
        const outs = filteredHistory.map((h) => h.tx_bps || 0);
        const ins = filteredHistory.map((h) => h.rx_bps || 0);
        const last = filteredHistory[filteredHistory.length - 1];
        const sum = (arr: number[]) => arr.reduce((a, b) => a + b, 0);
        return {
            latestOut: last?.tx_bps || 0,
            latestIn: last?.rx_bps || 0,
            peakOut: Math.max(...outs, 0),
            peakIn: Math.max(...ins, 0),
            avgOut: sum(outs) / outs.length,
            avgIn: sum(ins) / ins.length,
            p95: percentile95(outs.map((o, i) => Math.max(o, ins[i] || 0))),
        };
    }, [filteredHistory]);

    const chartData = useMemo(() => {
        const labels = filteredHistory.map((h) => formatTick(h.t || 0, range));
        return {
            labels,
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
        };
    }, [filteredHistory, range]);

    const chartOptions = useMemo<ChartOptions<'line'>>(
        () => ({
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
                        boxHeight: 8,
                        usePointStyle: true,
                        pointStyle: 'circle',
                        font: { size: 11, family: CloudUI.font },
                        padding: 16,
                    },
                },
                tooltip: {
                    backgroundColor: CloudUI.surface,
                    titleColor: CloudUI.text,
                    bodyColor: CloudUI.textSecondary,
                    borderColor: CloudUI.border,
                    borderWidth: 1,
                    callbacks: {
                        label: (ctx) => `${ctx.dataset.label}: ${Number(ctx.parsed.y || 0).toFixed(3)} Mbps`,
                    },
                },
            },
            scales: {
                x: {
                    ticks: { color: CloudUI.textMuted, maxTicksLimit: 8, font: { size: 10 } },
                    grid: { display: false },
                    border: { color: 'rgba(148,163,184,0.18)' },
                },
                y: {
                    beginAtZero: true,
                    ticks: {
                        color: CloudUI.textMuted,
                        font: { size: 10 },
                        callback: (v) => `${v}`,
                    },
                    grid: { color: 'rgba(148,163,184,0.10)' },
                    border: { display: false },
                    title: {
                        display: true,
                        text: 'Mbps',
                        color: CloudUI.textMuted,
                        font: { size: 10 },
                    },
                },
            },
        }),
        []
    );

    if (!uuid) {
        return (
            <EmptyState
                icon={<FontAwesomeIcon icon={faTachometerAlt} />}
                title='Aucune donnée statistique'
                description='Associez cette IP à un VPS pour afficher le trafic réseau (via le firewall du serveur).'
            />
        );
    }

    const busy = loading && !traffic;
    const kpi = (v: string) => (busy ? '…' : v);

    return (
        <div css={tw`space-y-5`}>
            <div css={tw`grid gap-3 sm:grid-cols-3`}>
                <StatCard
                    label='Conso sortant'
                    value={kpi(formatMbps(metrics.latestOut))}
                    hint={`Pic : ${formatMbps(metrics.peakOut)}`}
                    icon={<FontAwesomeIcon icon={faArrowUp} />}
                    tone='default'
                />
                <StatCard
                    label='Conso entrant'
                    value={kpi(formatMbps(metrics.latestIn))}
                    hint={`Pic : ${formatMbps(metrics.peakIn)}`}
                    icon={<FontAwesomeIcon icon={faArrowDown} />}
                />
                <StatCard
                    label='Commit 95e'
                    value={kpi(formatMbps(metrics.p95))}
                    hint='Trafic calculé sur 95 % du temps'
                    icon={<FontAwesomeIcon icon={faTachometerAlt} />}
                    tone='ok'
                />
            </div>

            <Panel padded>
                <PanelHeader
                    title='Statistiques réseau'
                    description={
                        <>
                            Trafic agrégé pour{' '}
                            <span css={tw`font-mono`} style={{ color: CloudUI.textSecondary }}>
                                {prefixLabel}
                            </span>
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
                            <GhostButton compact onClick={() => void load()} disabled={loading || refreshing} title='Actualiser'>
                                <FontAwesomeIcon icon={faSyncAlt} spin={loading || refreshing} /> Actualiser
                            </GhostButton>
                        </div>
                    }
                />

                <div css={tw`mb-4`}>
                    <SegmentedControl value={range} onChange={setRange} options={RANGES.map((r) => ({ id: r.id, label: r.label }))} />
                </div>

                {error ? (
                    <div
                        css={tw`rounded-xl border px-3 py-2.5 text-sm mb-4`}
                        style={{
                            borderColor: 'rgba(239,68,68,0.35)',
                            background: 'rgba(239,68,68,0.12)',
                            color: CloudUI.danger,
                        }}
                    >
                        {error}
                    </div>
                ) : null}

                {busy ? (
                    <div css={tw`flex h-64 items-center justify-center gap-2.5 text-sm`} style={{ color: CloudUI.textMuted }}>
                        <span
                            css={tw`h-6 w-6 animate-spin rounded-full border-2`}
                            style={{ borderColor: 'rgba(16,185,129,0.25)', borderTopColor: CloudUI.accent }}
                            aria-hidden
                        />
                        Chargement des statistiques…
                    </div>
                ) : !filteredHistory.length ? (
                    <EmptyState
                        icon={<FontAwesomeIcon icon={faTachometerAlt} />}
                        title='Aucune donnée pour cette période'
                        description='Le firewall du VPS n’a pas encore d’historique de trafic à afficher.'
                    />
                ) : (
                    <>
                        <div
                            css={tw`mb-4 flex flex-wrap gap-x-5 gap-y-2 text-xs`}
                            style={{ color: CloudUI.textMuted }}
                        >
                            <span>
                                Moy. IN{' '}
                                <strong style={{ color: CloudUI.textSecondary }}>{formatMbps(metrics.avgIn)}</strong>
                            </span>
                            <span>
                                Moy. OUT{' '}
                                <strong style={{ color: CloudUI.textSecondary }}>{formatMbps(metrics.avgOut)}</strong>
                            </span>
                            <span>
                                {filteredHistory.length} point{filteredHistory.length > 1 ? 's' : ''}
                            </span>
                            {fetchedAt ? (
                                <span>
                                    Mis à jour{' '}
                                    {new Date(fetchedAt).toLocaleTimeString('fr-FR', {
                                        hour: '2-digit',
                                        minute: '2-digit',
                                        second: '2-digit',
                                    })}
                                </span>
                            ) : null}
                        </div>
                        <div
                            css={tw`h-80 w-full rounded-xl px-2 pt-2 pb-1`}
                            style={{ background: 'rgba(255,255,255,0.02)', border: `1px solid ${HMS.cardBorder}` }}
                        >
                            <Line data={chartData} options={chartOptions} />
                        </div>
                        <MetaLine css={tw`mt-4`}>
                            Source : trafic firewall du VPS lié ({row.service?.name || row.service?.uuid}). Actualisation
                            automatique toutes les 15 secondes.
                        </MetaLine>
                    </>
                )}
            </Panel>
        </div>
    );
};
