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
import { CloudUI, cloudPanelStyle } from '@/components/hms/cloudUi';
import { EmptyState, Panel } from '@/components/network/NetworkUi';
import type { NetworkIpRow } from '@/api/network';

ChartJS.register(CategoryScale, LinearScale, PointElement, LineElement, Tooltip, Legend, Filler);

type RangeKey = '1h' | '24h' | '7d' | '30d' | '6m';

const RANGES: { key: RangeKey; label: string; seconds: number }[] = [
    { key: '1h', label: '1 h', seconds: 3600 },
    { key: '24h', label: '24 h', seconds: 86400 },
    { key: '7d', label: '7 j', seconds: 7 * 86400 },
    { key: '30d', label: '30 j', seconds: 30 * 86400 },
    { key: '6m', label: '6 mois', seconds: 180 * 86400 },
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
    const [error, setError] = useState<string | null>(null);
    const [traffic, setTraffic] = useState<FirewallTraffic | null>(null);
    const [fetchedAt, setFetchedAt] = useState<number | null>(null);

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
            setFetchedAt(Date.now());
        } catch (e: any) {
            setTraffic(null);
            setError(e?.message || 'Impossible de récupérer les statistiques.');
        } finally {
            setLoading(false);
        }
    }, [uuid]);

    useEffect(() => {
        void load();
    }, [load]);

    const filteredHistory = useMemo(() => {
        const history = traffic?.history || [];
        if (!history.length) return [];
        const seconds = RANGES.find((r) => r.key === range)?.seconds ?? 86400;
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
                    label: 'Trafic entrant (Mbps)',
                    data: filteredHistory.map((h) => Number(((h.rx_bps || 0) / 1000000).toFixed(3))),
                    borderColor: '#10b981',
                    backgroundColor: 'rgba(16, 185, 129, 0.12)',
                    fill: true,
                    tension: 0.3,
                    pointRadius: 0,
                    borderWidth: 2,
                },
                {
                    label: 'Trafic sortant (Mbps)',
                    data: filteredHistory.map((h) => Number(((h.tx_bps || 0) / 1000000).toFixed(3))),
                    borderColor: '#34d399',
                    backgroundColor: 'rgba(52, 211, 153, 0.08)',
                    fill: true,
                    tension: 0.3,
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
            interaction: { mode: 'index', intersect: false },
            plugins: {
                legend: {
                    display: true,
                    labels: {
                        color: CloudUI.textSecondary,
                        boxWidth: 10,
                        font: { size: 11, family: CloudUI.font },
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
                    grid: { color: 'rgba(148,163,184,0.12)' },
                },
                y: {
                    beginAtZero: true,
                    ticks: {
                        color: CloudUI.textMuted,
                        font: { size: 10 },
                        callback: (v) => `${v}`,
                    },
                    grid: { color: 'rgba(148,163,184,0.12)' },
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

    return (
        <div css={tw`space-y-5`}>
            <div css={tw`grid gap-3 sm:grid-cols-3`}>
                <KpiCard
                    icon={faArrowUp}
                    label='Conso sortant'
                    value={loading && !traffic ? null : formatMbps(metrics.latestOut)}
                    hint={`Pic sortant: ${formatMbps(metrics.peakOut)}`}
                />
                <KpiCard
                    icon={faArrowDown}
                    label='Conso entrant'
                    value={loading && !traffic ? null : formatMbps(metrics.latestIn)}
                    hint={`Pic entrant: ${formatMbps(metrics.peakIn)}`}
                />
                <KpiCard
                    icon={faTachometerAlt}
                    label='Commit 95e percentile'
                    value={loading && !traffic ? null : formatMbps(metrics.p95)}
                    hint='Trafic calculé sur 95 % du temps'
                />
            </div>

            <Panel>
                <div
                    css={tw`flex flex-col gap-3 border-b sm:flex-row sm:items-center sm:justify-between`}
                    style={{ borderColor: CloudUI.border, padding: '0.9rem 1rem' }}
                >
                    <div css={tw`min-w-0`}>
                        <h2 css={tw`text-base font-semibold sm:text-lg`} style={{ color: CloudUI.text }}>
                            Statistiques réseau
                        </h2>
                        <p css={tw`mt-1 text-sm`} style={{ color: CloudUI.textMuted }}>
                            <span css={tw`font-mono font-medium`} style={{ color: CloudUI.textSecondary }}>
                                {prefixLabel}
                            </span>
                            <span css={tw`mx-2`} style={{ color: CloudUI.border }}>
                                ·
                            </span>
                            <span css={tw`font-mono text-xs`}>{row.ip}</span>
                        </p>
                    </div>
                    <div css={tw`flex flex-shrink-0 flex-wrap items-center gap-2`}>
                        <select
                            value={range}
                            onChange={(e) => setRange(e.target.value as RangeKey)}
                            aria-label='Période des statistiques'
                            css={tw`h-10 rounded-md border px-3 text-sm font-medium outline-none`}
                            style={{
                                background: CloudUI.surface,
                                borderColor: CloudUI.border,
                                color: CloudUI.text,
                                fontFamily: CloudUI.font,
                            }}
                        >
                            {RANGES.map((r) => (
                                <option key={r.key} value={r.key}>
                                    {r.label}
                                </option>
                            ))}
                        </select>
                        <button
                            type='button'
                            onClick={() => void load()}
                            disabled={loading}
                            title='Actualiser'
                            css={tw`inline-flex h-10 w-10 items-center justify-center rounded-md border transition disabled:cursor-not-allowed disabled:opacity-50`}
                            style={{
                                background: CloudUI.surface,
                                borderColor: CloudUI.border,
                                color: CloudUI.textSecondary,
                            }}
                        >
                            <FontAwesomeIcon icon={faSyncAlt} spin={loading} />
                            <span css={tw`sr-only`}>Actualiser</span>
                        </button>
                    </div>
                </div>

                <div css={tw`px-4 py-4 sm:px-5`}>
                    {error ? (
                        <div
                            css={tw`rounded-md border px-3 py-2 text-sm`}
                            style={{
                                borderColor: 'rgba(239,68,68,0.35)',
                                background: 'rgba(239,68,68,0.12)',
                                color: CloudUI.danger,
                            }}
                        >
                            {error}
                        </div>
                    ) : loading && !filteredHistory.length ? (
                        <div
                            css={tw`flex h-56 items-center justify-center gap-2.5 text-sm`}
                            style={{ color: CloudUI.textMuted }}
                        >
                            <span
                                css={tw`h-6 w-6 animate-spin rounded-full border-2`}
                                style={{
                                    borderColor: 'rgba(16,185,129,0.25)',
                                    borderTopColor: CloudUI.accent,
                                }}
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
                            <div css={tw`mb-3 flex flex-wrap gap-x-4 gap-y-1 text-xs`} style={{ color: CloudUI.textMuted }}>
                                <span>
                                    Moy. IN <strong style={{ color: CloudUI.textSecondary }}>{formatMbps(metrics.avgIn)}</strong>
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
                            <div css={tw`h-72 w-full`}>
                                <Line data={chartData} options={chartOptions} />
                            </div>
                            <p css={tw`mt-3 text-xs`} style={{ color: CloudUI.textMuted }}>
                                Source : trafic firewall du VPS lié ({row.service?.name || row.service?.uuid}). Les
                                plages &gt; 24 h utilisent l’historique disponible côté serveur.
                            </p>
                        </>
                    )}
                </div>
            </Panel>
        </div>
    );
};

const KpiCard = ({
    icon,
    label,
    value,
    hint,
}: {
    icon: typeof faArrowUp;
    label: string;
    value: string | null;
    hint: string;
}) => (
    <div
        css={tw`rounded-md border px-4 py-4`}
        style={{
            background: CloudUI.surface,
            borderColor: CloudUI.border,
            boxShadow: cloudPanelStyle.boxShadow,
        }}
    >
        <div css={tw`flex items-stretch gap-3`}>
            <span
                css={tw`flex w-14 flex-shrink-0 items-center justify-center self-stretch rounded-md`}
                style={{ background: CloudUI.accentMuted, color: CloudUI.accent }}
            >
                <FontAwesomeIcon icon={icon} css={tw`text-lg`} />
            </span>
            <div css={tw`min-w-0 pl-0.5`}>
                <p css={tw`text-sm font-medium`} style={{ color: CloudUI.textMuted }}>
                    {label}
                </p>
                <p
                    css={tw`mt-1.5 text-2xl font-bold tracking-tight tabular-nums`}
                    style={{ color: CloudUI.accent, fontFamily: CloudUI.fontMono }}
                >
                    {value === null ? (
                        <span css={tw`inline-flex h-8 w-8 items-center justify-center`} aria-hidden>
                            <span
                                css={tw`h-5 w-5 animate-spin rounded-full border-2`}
                                style={{
                                    borderColor: 'rgba(16,185,129,0.25)',
                                    borderTopColor: CloudUI.accent,
                                }}
                            />
                        </span>
                    ) : (
                        value
                    )}
                </p>
                <p css={tw`mt-1 text-sm`} style={{ color: CloudUI.textMuted }}>
                    {hint}
                </p>
            </div>
        </div>
    </div>
);
