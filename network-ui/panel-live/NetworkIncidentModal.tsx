import React, { useEffect, useMemo, useState } from 'react';
import tw from 'twin.macro';
import { Line } from 'react-chartjs-2';
import {
    CategoryScale,
    Chart as ChartJS,
    Filler,
    Legend,
    LinearScale,
    LineElement,
    PointElement,
    Tooltip,
} from 'chart.js';
import * as Icon from 'react-feather';
import HmsModal from '@/components/hms/HmsModal';
import Spinner from '@/components/elements/Spinner';
import { CloudUI } from '@/components/hms/cloudUi';
import { HMS } from '@/components/hms/hmsTheme';
import {
    DdosIncident,
    DdosIncidentDetails,
    getDdosIncident,
    getDdosIncidentChart,
} from '@/api/network';
import { Badge, durationMin, formatWhen, severityOfBps } from '@/components/network/NetworkUi';

ChartJS.register(CategoryScale, LinearScale, PointElement, LineElement, Filler, Tooltip, Legend);

type Props = {
    incident: DdosIncident | null;
    onClose: () => void;
};

const formatBps = (v: number) => {
    if (v >= 1e9) return `${(v / 1e9).toFixed(2)} Gbps`;
    if (v >= 1e6) return `${(v / 1e6).toFixed(1)} Mbps`;
    if (v >= 1e3) return `${(v / 1e3).toFixed(0)} Kbps`;
    return `${v} bps`;
};

const formatPps = (v: number) => {
    if (v >= 1e6) return `${(v / 1e6).toFixed(2)} Mpps`;
    if (v >= 1e3) return `${(v / 1e3).toFixed(1)} Kpps`;
    return `${v} pps`;
};

export default ({ incident, onClose }: Props) => {
    const [detail, setDetail] = useState<DdosIncidentDetails | null>(null);
    const [chartUrl, setChartUrl] = useState<string | null>(null);
    const [error, setError] = useState<string | null>(null);
    const [loading, setLoading] = useState(false);
    const [tab, setTab] = useState<'chart' | 'flows'>('chart');

    useEffect(() => {
        if (!incident) {
            setDetail(null);
            setChartUrl(null);
            setError(null);
            return;
        }
        let cancelled = false;
        let objectUrl: string | null = null;
        setLoading(true);
        setError(null);
        setTab('chart');

        (async () => {
            try {
                const [d, c] = await Promise.all([
                    getDdosIncident(incident.incident_id),
                    getDdosIncidentChart(incident.incident_id).catch(() => null),
                ]);
                if (cancelled) return;
                setDetail(d);
                if (c?.base64) {
                    const bin = atob(c.base64);
                    const bytes = new Uint8Array(bin.length);
                    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
                    objectUrl = URL.createObjectURL(new Blob([bytes], { type: c.content_type || 'image/png' }));
                    setChartUrl(objectUrl);
                }
            } catch (e: any) {
                if (!cancelled) setError(e?.message || 'Impossible de charger le détail.');
            } finally {
                if (!cancelled) setLoading(false);
            }
        })();

        return () => {
            cancelled = true;
            if (objectUrl) URL.revokeObjectURL(objectUrl);
        };
    }, [incident?.incident_id]);

    const lineData = useMemo(() => {
        const bytes = detail?.timestamps_bytes || [];
        const packets = detail?.timestamps_packets || [];
        if (!bytes.length && !packets.length) return null;
        const labels = (bytes.length ? bytes : packets).map((p) => {
            try {
                return new Date(p.time).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
            } catch {
                return p.time;
            }
        });
        return {
            labels,
            datasets: [
                {
                    label: 'Bits/s',
                    data: bytes.map((p) => p.value),
                    borderColor: CloudUI.danger,
                    backgroundColor: 'rgba(239,68,68,0.15)',
                    fill: true,
                    tension: 0.25,
                    pointRadius: 0,
                    yAxisID: 'y',
                },
                {
                    label: 'Packets/s',
                    data: packets.map((p) => p.value),
                    borderColor: CloudUI.accentHover,
                    backgroundColor: 'transparent',
                    fill: false,
                    tension: 0.25,
                    pointRadius: 0,
                    yAxisID: 'y1',
                },
            ],
        };
    }, [detail]);

    const topSources = useMemo(() => {
        const dump = detail?.packet_dump || [];
        const map = new Map<string, { ip: string; country?: string; asn?: number; packets: number; bytes: number }>();
        dump.forEach((f) => {
            const ip = f.source_ip || '?';
            const cur = map.get(ip) || { ip, country: f.source_country, asn: f.source_asn, packets: 0, bytes: 0 };
            cur.packets += f.packets || 0;
            cur.bytes += f.length || 0;
            map.set(ip, cur);
        });
        return [...map.values()].sort((a, b) => b.packets - a.packets).slice(0, 12);
    }, [detail]);

    const sev = severityOfBps(detail?.max_bps ?? incident?.max_bps);
    const mins = durationMin(detail?.incident_start || incident?.incident_start, detail?.incident_stop ?? incident?.incident_stop);

    return (
        <HmsModal visible={!!incident} onClose={onClose} maxWidth="80rem">
            <div css={tw`p-4 sm:p-6 lg:p-8 space-y-5 sm:space-y-6`}>
                <div css={tw`pr-8`}>
                    <div css={tw`flex flex-wrap items-center gap-2 mb-2`}>
                        <Badge tone="accent">Détail attaque</Badge>
                        {!incident?.incident_stop && !detail?.incident_stop ? <Badge tone="danger">En cours</Badge> : null}
                        <Badge tone={sev === 'danger' ? 'danger' : sev === 'warn' ? 'warn' : 'ok'}>
                            {detail?.attack_type || incident?.attack_type || 'attack'}
                        </Badge>
                    </div>
                    <h2 css={tw`text-lg sm:text-xl font-semibold m-0 break-all`} style={{ color: CloudUI.text, fontFamily: CloudUI.fontMono }}>
                        {detail?.ip || incident?.ip}
                    </h2>
                    <p css={tw`text-sm m-0 mt-1`} style={{ color: CloudUI.textMuted }}>
                        {formatWhen(detail?.incident_start || incident?.incident_start)}
                        {' → '}
                        {(detail?.incident_stop ?? incident?.incident_stop)
                            ? formatWhen(detail?.incident_stop ?? incident?.incident_stop)
                            : 'en cours'}
                        {mins ? ` · ${mins} min` : ''}
                        {(detail?.protocol || incident?.protocol) ? ` · ${detail?.protocol || incident?.protocol}` : ''}
                    </p>
                </div>

                <div css={tw`grid grid-cols-2 sm:grid-cols-4 gap-2`}>
                    {[
                        { label: 'Pic bps', value: detail?.max_bps_formattet || incident?.max_bps_formattet || '—' },
                        { label: 'Pic pps', value: detail?.max_pps_formattet || incident?.max_pps_formattet || '—' },
                        { label: 'Groupe', value: detail?.host_group || incident?.host_group || '—' },
                        {
                            label: 'Port source #1',
                            value: detail?.most_used_source_port != null ? String(detail.most_used_source_port) : '—',
                        },
                    ].map((s) => (
                        <div
                            key={s.label}
                            css={tw`rounded-lg px-3 py-2`}
                            style={{ background: HMS.inputBg, border: `1px solid ${HMS.cardBorder}` }}
                        >
                            <p css={tw`text-[11px] m-0`} style={{ color: CloudUI.textMuted }}>
                                {s.label}
                            </p>
                            <p css={tw`text-sm font-semibold m-0 mt-0.5 tabular-nums`} style={{ color: CloudUI.text }}>
                                {s.value}
                            </p>
                        </div>
                    ))}
                </div>

                {loading ? (
                    <div css={tw`py-16 flex justify-center`}>
                        <Spinner size="large" />
                    </div>
                ) : error ? (
                    <p css={tw`text-sm m-0`} style={{ color: CloudUI.danger }}>
                        {error}
                    </p>
                ) : (
                    <>
                        <div css={tw`flex gap-2`}>
                            <button
                                type="button"
                                onClick={() => setTab('chart')}
                                css={tw`flex-1 sm:flex-none px-3 py-2.5 rounded-lg text-sm font-medium border-0 cursor-pointer`}
                                style={{
                                    background: tab === 'chart' ? CloudUI.accent : 'rgba(255,255,255,0.04)',
                                    color: tab === 'chart' ? '#fff' : CloudUI.textSecondary,
                                    border: `1px solid ${HMS.cardBorder}`,
                                    minHeight: 44,
                                    WebkitTapHighlightColor: 'transparent',
                                }}
                            >
                                Graphique
                            </button>
                            <button
                                type="button"
                                onClick={() => setTab('flows')}
                                css={tw`flex-1 sm:flex-none px-3 py-2.5 rounded-lg text-sm font-medium border-0 cursor-pointer`}
                                style={{
                                    background: tab === 'flows' ? CloudUI.accent : 'rgba(255,255,255,0.04)',
                                    color: tab === 'flows' ? '#fff' : CloudUI.textSecondary,
                                    border: `1px solid ${HMS.cardBorder}`,
                                    minHeight: 44,
                                    WebkitTapHighlightColor: 'transparent',
                                }}
                            >
                                Sources ({topSources.length})
                            </button>
                        </div>

                        {tab === 'chart' ? (
                            <div css={tw`space-y-4`}>
                                {lineData ? (
                                    <div
                                        css={tw`rounded-lg p-3`}
                                        style={{ background: HMS.inputBg, border: `1px solid ${HMS.cardBorder}` }}
                                    >
                                        <Line
                                            data={lineData}
                                            options={{
                                                responsive: true,
                                                maintainAspectRatio: true,
                                                interaction: { mode: 'index', intersect: false },
                                                plugins: {
                                                    legend: {
                                                        labels: { color: CloudUI.textMuted, boxWidth: 12 },
                                                    },
                                                    tooltip: {
                                                        callbacks: {
                                                            label: (ctx) => {
                                                                const v = Number(ctx.parsed.y || 0);
                                                                return ctx.dataset.yAxisID === 'y1'
                                                                    ? `${ctx.dataset.label}: ${formatPps(v)}`
                                                                    : `${ctx.dataset.label}: ${formatBps(v)}`;
                                                            },
                                                        },
                                                    },
                                                },
                                                scales: {
                                                    x: {
                                                        ticks: { color: CloudUI.textMuted, maxRotation: 0, autoSkipPadding: 12 },
                                                        grid: { color: 'rgba(255,255,255,0.04)' },
                                                    },
                                                    y: {
                                                        position: 'left',
                                                        ticks: {
                                                            color: CloudUI.textMuted,
                                                            callback: (v) => formatBps(Number(v)),
                                                        },
                                                        grid: { color: 'rgba(255,255,255,0.06)' },
                                                    },
                                                    y1: {
                                                        position: 'right',
                                                        ticks: {
                                                            color: CloudUI.textMuted,
                                                            callback: (v) => formatPps(Number(v)),
                                                        },
                                                        grid: { drawOnChartArea: false },
                                                    },
                                                },
                                            }}
                                        />
                                    </div>
                                ) : null}
                                {chartUrl ? (
                                    <div>
                                        <p css={tw`text-xs m-0 mb-2`} style={{ color: CloudUI.textMuted }}>
                                            Export mitigation
                                        </p>
                                        <img
                                            src={chartUrl}
                                            alt="Graphique d’incident"
                                            css={tw`w-full rounded-lg`}
                                            style={{ border: `1px solid ${HMS.cardBorder}`, background: '#0b1220' }}
                                        />
                                    </div>
                                ) : null}
                                {!lineData && !chartUrl ? (
                                    <p css={tw`text-sm m-0`} style={{ color: CloudUI.textMuted }}>
                                        Pas de série temporelle pour cet incident.
                                    </p>
                                ) : null}
                            </div>
                        ) : topSources.length === 0 ? (
                            <p css={tw`text-sm py-8 text-center m-0`} style={{ color: CloudUI.textMuted }}>
                                Pas de dump de flux pour cet incident.
                            </p>
                        ) : (
                            <div css={tw`space-y-2`}>
                                {topSources.map((s, idx) => (
                                    <div
                                        key={s.ip}
                                        css={tw`rounded-lg px-3 py-3`}
                                        style={{ background: HMS.inputBg, border: `1px solid ${HMS.cardBorder}` }}
                                    >
                                        <div css={tw`flex items-start justify-between gap-3`}>
                                            <div css={tw`min-w-0`}>
                                                <div css={tw`flex flex-wrap items-center gap-2`}>
                                                    <span
                                                        css={tw`text-[11px] font-medium tabular-nums`}
                                                        style={{ color: CloudUI.textMuted }}
                                                    >
                                                        #{idx + 1}
                                                    </span>
                                                    <code
                                                        css={tw`text-sm font-semibold break-all`}
                                                        style={{ color: CloudUI.text, fontFamily: CloudUI.fontMono }}
                                                    >
                                                        {s.ip}
                                                    </code>
                                                </div>
                                                <div
                                                    css={tw`mt-2 grid grid-cols-2 gap-x-3 gap-y-1.5 text-xs sm:flex sm:flex-wrap sm:gap-x-4`}
                                                    style={{ color: CloudUI.textMuted }}
                                                >
                                                    <span>
                                                        Pays{' '}
                                                        <strong style={{ color: CloudUI.textSecondary }}>
                                                            {s.country || '—'}
                                                        </strong>
                                                    </span>
                                                    <span>
                                                        ASN{' '}
                                                        <strong style={{ color: CloudUI.textSecondary }}>
                                                            {s.asn ?? '—'}
                                                        </strong>
                                                    </span>
                                                </div>
                                            </div>
                                            <div css={tw`text-right flex-shrink-0`}>
                                                <p
                                                    css={tw`text-base font-bold tabular-nums m-0 leading-none`}
                                                    style={{ color: CloudUI.text }}
                                                >
                                                    {s.packets.toLocaleString('fr-FR')}
                                                </p>
                                                <p css={tw`text-[11px] m-0 mt-1`} style={{ color: CloudUI.textMuted }}>
                                                    packets
                                                </p>
                                            </div>
                                        </div>
                                    </div>
                                ))}
                            </div>
                        )}
                    </>
                )}

                <div css={tw`flex justify-end`}>
                    <button
                        type="button"
                        onClick={onClose}
                        css={tw`inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium border-0 cursor-pointer`}
                        style={{ background: 'rgba(255,255,255,0.04)', color: CloudUI.textSecondary, border: `1px solid ${HMS.cardBorder}` }}
                    >
                        <Icon.X size={14} /> Fermer
                    </button>
                </div>
            </div>
        </HmsModal>
    );
};
