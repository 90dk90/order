import React, { useEffect, useMemo, useState } from 'react';
import tw from 'twin.macro';
import { Link, useHistory, useLocation } from 'react-router-dom';
import useSWR from 'swr';
import * as Icon from 'react-feather';
import useFlash from '@/plugins/useFlash';
import Spinner from '@/components/elements/Spinner';
import NetworkNavTabs from '@/components/network/NetworkNavTabs';
import NetworkIncidentModal from '@/components/network/NetworkIncidentModal';
import { HMS } from '@/components/hms/hmsTheme';
import { CloudUI } from '@/components/hms/cloudUi';
import { useStoreState } from 'easy-peasy';
import {
    DdosFilterMode,
    DdosIncident,
    getDdosFilterModes,
    getDdosIncidents,
    getNetworkIps,
    NetworkIpRow,
    setDdosFilterMode,
} from '@/api/network';
import {
    Badge,
    DataTable,
    EmptyState,
    GhostButton,
    MetaLine,
    MobileCard,
    MobileMetaGrid,
    MonoIp,
    NetworkHeader,
    NetworkPage,
    Panel,
    SearchField,
    SelectField,
    SegmentedControl,
    Td,
    durationMin,
    formatWhen,
    severityOfBps,
} from '@/components/network/NetworkUi';

type Period = '7d' | '30d' | '90d' | 'all';

const exportCsv = (rows: DdosIncident[]) => {
    const header = [
        'incident_id',
        'ip',
        'attack_type',
        'protocol',
        'incident_start',
        'incident_stop',
        'max_bps',
        'max_pps',
        'max_bps_formattet',
        'max_pps_formattet',
        'host_group',
    ];
    const esc = (v: unknown) => {
        const s = v == null ? '' : String(v);
        return `"${s.replace(/"/g, '""')}"`;
    };
    const lines = [header.join(',')].concat(
        rows.map((r) =>
            [
                r.incident_id,
                r.ip,
                r.attack_type || r.diversion_reason || '',
                r.protocol || '',
                r.incident_start || '',
                r.incident_stop || '',
                r.max_bps ?? '',
                r.max_pps ?? '',
                r.max_bps_formattet || '',
                r.max_pps_formattet || '',
                r.host_group || '',
            ]
                .map(esc)
                .join(',')
        )
    );
    const blob = new Blob([lines.join('\n')], { type: 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `ddos-incidents-${new Date().toISOString().slice(0, 10)}.csv`;
    a.click();
    URL.revokeObjectURL(url);
};

const periodStartMs = (period: Period): number | null => {
    if (period === 'all') return null;
    const days = period === '7d' ? 7 : period === '30d' ? 30 : 90;
    return Date.now() - days * 24 * 60 * 60 * 1000;
};

const Metric = ({
    label,
    value,
    hint,
    tone = 'default',
}: {
    label: string;
    value: string | number;
    hint?: string;
    tone?: 'default' | 'ok' | 'warn' | 'danger';
}) => {
    const color =
        tone === 'ok'
            ? CloudUI.success
            : tone === 'warn'
              ? CloudUI.warning
              : tone === 'danger'
                ? CloudUI.danger
                : CloudUI.text;
    return (
        <div css={tw`min-w-0 py-1`}>
            <p
                css={tw`m-0 text-[11px] font-semibold uppercase tracking-wider`}
                style={{ color: CloudUI.textMuted, letterSpacing: '0.08em' }}
            >
                {label}
            </p>
            <p css={tw`m-0 mt-1 text-2xl font-semibold tabular-nums tracking-tight`} style={{ color }}>
                {value}
            </p>
            {hint ? (
                <p css={tw`m-0 mt-0.5 text-xs truncate`} style={{ color: CloudUI.textMuted }}>
                    {hint}
                </p>
            ) : null}
        </div>
    );
};

const StatusDot = ({
    tone,
    label,
}: {
    tone: 'ok' | 'warn' | 'danger' | 'neutral';
    label: string;
}) => {
    const color =
        tone === 'ok'
            ? CloudUI.success
            : tone === 'warn'
              ? CloudUI.warning
              : tone === 'danger'
                ? CloudUI.danger
                : CloudUI.textMuted;
    return (
        <span css={tw`inline-flex items-center gap-2 text-sm`} style={{ color: CloudUI.textSecondary }}>
            <span
                css={tw`inline-block rounded-full flex-shrink-0`}
                style={{ width: 7, height: 7, background: color, boxShadow: `0 0 0 3px ${color}22` }}
            />
            {label}
        </span>
    );
};

const HoverRow = ({
    children,
    onClick,
}: {
    children: React.ReactNode;
    onClick?: () => void;
}) => {
    const [hover, setHover] = useState(false);
    return (
        <tr
            role={onClick ? 'button' : undefined}
            tabIndex={onClick ? 0 : undefined}
            onClick={onClick}
            onKeyDown={
                onClick
                    ? (e) => {
                          if (e.key === 'Enter' || e.key === ' ') {
                              e.preventDefault();
                              onClick();
                          }
                      }
                    : undefined
            }
            onMouseEnter={() => setHover(true)}
            onMouseLeave={() => setHover(false)}
            style={{
                background: hover ? 'rgba(255,255,255,0.025)' : 'transparent',
                transition: 'background 0.12s ease',
                cursor: onClick ? 'pointer' : undefined,
            }}
        >
            {children}
        </tr>
    );
};

export default () => {
    const { clearFlashes, clearAndAddHttpError, addFlash } = useFlash();
    const rootAdmin = useStoreState((state) => !!state.user.data?.rootAdmin);
    const location = useLocation();
    const history = useHistory();

    const params = useMemo(() => new URLSearchParams(location.search), [location.search]);
    const initialIp = params.get('ip') || '';
    const initialIncident = params.get('incident') || '';

    const [q, setQ] = useState('');
    const [historyQ, setHistoryQ] = useState(initialIp);
    const [activeOnly, setActiveOnly] = useState(false);
    const [period, setPeriod] = useState<Period>('30d');
    const [attackType, setAttackType] = useState('all');
    const [busyIp, setBusyIp] = useState<string | null>(null);
    const [selected, setSelected] = useState<DdosIncident | null>(null);
    const [refreshMs, setRefreshMs] = useState(0);
    const [deepLinked, setDeepLinked] = useState(false);

    const {
        data: incidents,
        error: incidentsError,
        mutate: mutateIncidents,
    } = useSWR<DdosIncident[]>('network-ddos-incidents', getDdosIncidents, {
        revalidateOnFocus: true,
        refreshInterval: refreshMs,
    });

    useEffect(() => {
        const active = (incidents || []).some((i) => !i.incident_stop);
        setRefreshMs(active ? 15000 : 0);
    }, [incidents]);

    const {
        data: modes,
        error: modesError,
        mutate: mutateModes,
    } = useSWR<DdosFilterMode[]>('network-ddos-modes', getDdosFilterModes, {
        revalidateOnFocus: true,
    });
    const { data: ips } = useSWR<NetworkIpRow[]>('network-ips', getNetworkIps);

    useEffect(() => {
        const err = incidentsError || modesError;
        if (err) clearAndAddHttpError({ error: err });
        else clearFlashes();
    }, [incidentsError, modesError]);

    useEffect(() => {
        if (deepLinked || !incidents || !initialIncident) return;
        const found = incidents.find((i) => i.incident_id === initialIncident);
        if (found) {
            setSelected(found);
            setDeepLinked(true);
        }
    }, [incidents, initialIncident, deepLinked]);

    const modeByIp = useMemo(() => {
        const map: Record<string, DdosFilterMode> = {};
        (modes || []).forEach((m) => {
            map[m.ip] = m;
        });
        return map;
    }, [modes]);

    const ownedIpSet = useMemo(() => new Set((ips || []).map((i) => i.ip)), [ips]);

    const attackTypes = useMemo(() => {
        const set = new Set<string>();
        (incidents || []).forEach((i) => {
            const t = i.attack_type || i.diversion_reason;
            if (t) set.add(t);
        });
        return [...set].sort();
    }, [incidents]);

    const filteredIps = useMemo(() => {
        const list = ips || [];
        const needle = q.trim().toLowerCase();
        if (!needle) return list;
        return list.filter((row) => {
            const mode = modeByIp[row.ip]?.filter_mode || '';
            return `${row.ip} ${row.service.name} ${mode}`.toLowerCase().includes(needle);
        });
    }, [ips, q, modeByIp]);

    const sortedIncidents = useMemo(() => {
        const start = periodStartMs(period);
        let list = [...(incidents || [])].sort((a, b) =>
            String(b.incident_start || '').localeCompare(String(a.incident_start || ''))
        );
        if (start != null) {
            list = list.filter((i) => {
                const t = Date.parse(i.incident_start || '');
                return Number.isFinite(t) && t >= start;
            });
        }
        if (activeOnly) list = list.filter((i) => !i.incident_stop);
        if (attackType !== 'all') {
            list = list.filter((i) => (i.attack_type || i.diversion_reason || '') === attackType);
        }
        const needle = historyQ.trim().toLowerCase();
        if (needle) {
            list = list.filter((i) =>
                `${i.ip} ${i.attack_type || ''} ${i.diversion_reason || ''} ${i.protocol || ''} ${i.host_group || ''}`
                    .toLowerCase()
                    .includes(needle)
            );
        }
        return list;
    }, [incidents, activeOnly, historyQ, period, attackType]);

    const overview = useMemo(() => {
        const list = ips || [];
        const alwaysOn = list.filter((r) => modeByIp[r.ip]?.filter_mode === 'always_on').length;
        const scoped = sortedIncidents;
        const peak = Math.max(0, ...scoped.map((i) => i.max_bps || 0));
        const peakLabel = scoped.find((i) => (i.max_bps || 0) === peak)?.max_bps_formattet || '—';
        const active = (incidents || []).filter((i) => !i.incident_stop).length;
        return {
            protectedIps: list.length,
            alwaysOn,
            incidents: scoped.length,
            peakLabel,
            active,
        };
    }, [ips, modeByIp, sortedIncidents, incidents]);

    const toggleMode = async (ip: string, current?: string) => {
        const next = current === 'always_on' ? 'dynamic' : 'always_on';
        setBusyIp(ip);
        try {
            await setDdosFilterMode(ip, next);
            await mutateModes();
            await mutateIncidents();
            addFlash({ key: 'network:ddos', type: 'success', message: `${ip} → ${next}` });
        } catch (e) {
            clearAndAddHttpError({ key: 'network:ddos', error: e });
        } finally {
            setBusyIp(null);
        }
    };

    const clearQuery = () => {
        if (location.search) history.replace('/network/ddos');
        setHistoryQ('');
        setDeepLinked(true);
    };

    if (!incidents || !modes || !ips) {
        return (
            <div css={tw`py-32 flex justify-center`}>
                <Spinner size="large" />
            </div>
        );
    }

    const periodOptions: { id: Period; label: string }[] = [
        { id: '7d', label: '7 j' },
        { id: '30d', label: '30 j' },
        { id: '90d', label: '90 j' },
        { id: 'all', label: 'Tout' },
    ];

    const periodHint = period === 'all' ? 'Toute la période' : `Période ${period}`;

    return (
        <NetworkPage>
            <div css={tw`flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between`}>
                <NetworkHeader
                    icon={Icon.Shield}
                    title="Attaques DDoS"
                    subtitle="Mitigation Packets Decreaser, modes de filtre et historique d’incidents."
                />
                {overview.active > 0 ? (
                    <div
                        css={tw`inline-flex items-center gap-2 px-3 py-2 rounded-lg text-sm font-semibold self-start sm:self-auto`}
                        style={{
                            background: 'rgba(239,68,68,0.12)',
                            color: CloudUI.danger,
                            border: '1px solid rgba(239,68,68,0.28)',
                        }}
                    >
                        <span
                            css={tw`inline-block rounded-full`}
                            style={{
                                width: 8,
                                height: 8,
                                background: CloudUI.danger,
                                boxShadow: `0 0 0 3px rgba(239,68,68,0.25)`,
                            }}
                        />
                        {overview.active} attaque{overview.active > 1 ? 's' : ''} en cours
                    </div>
                ) : null}
            </div>

            <NetworkNavTabs active="ddos" />

            <div
                css={tw`rounded-xl px-4 sm:px-6 py-4 grid grid-cols-2 md:grid-cols-3 xl:grid-cols-5 gap-4 sm:gap-5`}
                style={{
                    background: CloudUI.surface,
                    border: `1px solid ${HMS.cardBorder}`,
                }}
            >
                <Metric label="IPs protégées" value={overview.protectedIps} hint="Sur ce compte" />
                <Metric
                    label="Always-on"
                    value={overview.alwaysOn}
                    hint="Filtres permanents"
                    tone={overview.alwaysOn ? 'warn' : 'default'}
                />
                <Metric label="Incidents" value={overview.incidents} hint={periodHint} tone="ok" />
                <Metric label="Pic maximal" value={overview.peakLabel} hint="Sur la période filtrée" tone="danger" />
                <Metric
                    label="En cours"
                    value={overview.active}
                    hint={overview.active ? 'Attaques actives' : 'Aucune attaque active'}
                    tone={overview.active ? 'danger' : 'ok'}
                />
            </div>

            <Panel padded={false}>
                <div
                    css={tw`px-4 sm:px-6 py-4 sm:py-5 flex flex-col lg:flex-row lg:items-end lg:justify-between gap-3`}
                    style={{ borderBottom: `1px solid ${HMS.cardBorder}` }}
                >
                    <div css={tw`min-w-0`}>
                        <h2 css={tw`m-0 text-base font-semibold tracking-tight`} style={{ color: CloudUI.text }}>
                            Mode filtre par IP
                        </h2>
                        <p css={tw`m-0 mt-1 text-sm leading-relaxed max-w-2xl`} style={{ color: CloudUI.textMuted }}>
                            <strong style={{ color: CloudUI.textSecondary }}>dynamic</strong> mitige à la détection ·{' '}
                            <strong style={{ color: CloudUI.textSecondary }}>always-on</strong> filtre en permanence
                        </p>
                    </div>
                    <div css={tw`w-full lg:w-72 flex-shrink-0`}>
                        <SearchField value={q} onChange={setQ} placeholder="Filtrer une IP ou une instance…" />
                    </div>
                </div>

                {filteredIps.length === 0 ? (
                    <EmptyState
                        icon={<Icon.Globe size={32} />}
                        title="Aucune IP"
                        description="Aucune IP à afficher pour ce filtre."
                    />
                ) : (
                    <>
                        <DataTable
                            headers={[
                                { key: 'ip', label: 'Adresse IP', width: '28%' },
                                { key: 'vps', label: 'Instance', width: '28%' },
                                { key: 'mode', label: 'Mode', width: '18%' },
                                { key: 'act', label: '', width: '26%', align: 'right' },
                            ]}
                        >
                            {filteredIps.map((row) => {
                                const mode = modeByIp[row.ip]?.filter_mode || 'dynamic';
                                const locked = !!modeByIp[row.ip]?.filter_mode_locked;
                                return (
                                    <HoverRow key={row.ip}>
                                        <Td>
                                            <div css={tw`flex items-center gap-2 flex-wrap`}>
                                                <MonoIp>{row.ip}</MonoIp>
                                                {locked ? <Badge tone="danger">Verrouillé</Badge> : null}
                                            </div>
                                        </Td>
                                        <Td>
                                            <Link
                                                to={`/server/${row.service.uuid}`}
                                                css={tw`text-sm no-underline font-medium block truncate`}
                                                style={{ color: CloudUI.text }}
                                                title={row.service.name}
                                            >
                                                {row.service.name}
                                            </Link>
                                        </Td>
                                        <Td>
                                            <StatusDot
                                                tone={mode === 'always_on' ? 'warn' : 'ok'}
                                                label={mode === 'always_on' ? 'Always-on' : 'Dynamic'}
                                            />
                                        </Td>
                                        <Td align="right">
                                            <div css={tw`flex justify-end`}>
                                                <GhostButton
                                                    compact
                                                    disabled={locked || busyIp === row.ip}
                                                    onClick={() => toggleMode(row.ip, mode)}
                                                >
                                                    {busyIp === row.ip
                                                        ? '…'
                                                        : mode === 'always_on'
                                                          ? '→ Dynamic'
                                                          : '→ Always-on'}
                                                </GhostButton>
                                            </div>
                                        </Td>
                                    </HoverRow>
                                );
                            })}
                        </DataTable>

                        <div css={tw`lg:hidden px-3 sm:px-4 pb-4 space-y-3`}>
                            {filteredIps.map((row) => {
                                const mode = modeByIp[row.ip]?.filter_mode || 'dynamic';
                                const locked = !!modeByIp[row.ip]?.filter_mode_locked;
                                return (
                                    <MobileCard key={row.ip}>
                                        <div css={tw`flex items-start justify-between gap-3`}>
                                            <div css={tw`min-w-0 flex-1`}>
                                                <MonoIp>{row.ip}</MonoIp>
                                                <Link
                                                    to={`/server/${row.service.uuid}`}
                                                    css={tw`inline-flex items-center gap-1 text-sm no-underline mt-2 font-medium`}
                                                    style={{ color: CloudUI.text }}
                                                >
                                                    {row.service.name}
                                                    <Icon.ChevronRight size={14} />
                                                </Link>
                                            </div>
                                            <div css={tw`flex flex-col items-end gap-2 flex-shrink-0`}>
                                                <StatusDot
                                                    tone={mode === 'always_on' ? 'warn' : 'ok'}
                                                    label={mode === 'always_on' ? 'Always-on' : 'Dynamic'}
                                                />
                                                {locked ? <Badge tone="danger">Verrouillé</Badge> : null}
                                            </div>
                                        </div>
                                        {!locked ? (
                                            <GhostButton
                                                disabled={busyIp === row.ip}
                                                onClick={() => toggleMode(row.ip, mode)}
                                            >
                                                <Icon.RefreshCw size={15} />
                                                {busyIp === row.ip
                                                    ? 'Changement…'
                                                    : mode === 'always_on'
                                                      ? 'Passer en Dynamic'
                                                      : 'Passer en Always-on'}
                                            </GhostButton>
                                        ) : (
                                            <p css={tw`text-xs m-0`} style={{ color: CloudUI.textMuted }}>
                                                Mode verrouillé — impossible de le changer depuis le panel.
                                            </p>
                                        )}
                                    </MobileCard>
                                );
                            })}
                        </div>
                    </>
                )}
            </Panel>

            <Panel padded={false}>
                <div
                    css={tw`px-4 sm:px-6 py-4 sm:py-5 space-y-4`}
                    style={{ borderBottom: `1px solid ${HMS.cardBorder}` }}
                >
                    <div css={tw`flex flex-col sm:flex-row sm:items-start sm:justify-between gap-3`}>
                        <div css={tw`min-w-0`}>
                            <h2 css={tw`m-0 text-base font-semibold tracking-tight`} style={{ color: CloudUI.text }}>
                                Historique des attaques
                            </h2>
                            <p css={tw`m-0 mt-1 text-sm`} style={{ color: CloudUI.textMuted }}>
                                {overview.active
                                    ? 'Rafraîchissement auto toutes les 15 s pendant une attaque en cours.'
                                    : 'Sélectionnez un incident pour le détail, le graphique et les sources.'}
                            </p>
                        </div>
                        <div css={tw`flex flex-wrap items-center gap-2 flex-shrink-0`}>
                            <GhostButton
                                compact
                                disabled={sortedIncidents.length === 0}
                                onClick={() => exportCsv(sortedIncidents)}
                            >
                                <Icon.Download size={14} /> CSV
                            </GhostButton>
                            {initialIp || initialIncident || historyQ ? (
                                <GhostButton compact onClick={clearQuery}>
                                    <Icon.X size={14} /> Reset
                                </GhostButton>
                            ) : null}
                        </div>
                    </div>

                    <div css={tw`flex flex-col xl:flex-row gap-3 xl:items-center`}>
                        <div css={tw`flex-1 min-w-0 xl:max-w-sm`}>
                            <SearchField
                                value={historyQ}
                                onChange={setHistoryQ}
                                placeholder="IP, type, protocole…"
                            />
                        </div>
                        <div css={tw`grid grid-cols-1 sm:grid-cols-2 gap-2 xl:w-[28rem]`}>
                            <SelectField value={attackType} onChange={setAttackType}>
                                <option value="all">Tous les types</option>
                                {attackTypes.map((t) => (
                                    <option key={t} value={t}>
                                        {t}
                                    </option>
                                ))}
                            </SelectField>
                            <GhostButton onClick={() => setActiveOnly((v) => !v)} title="Filtrer les attaques en cours">
                                <Icon.Zap size={15} />
                                {activeOnly ? 'En cours seulement' : 'Tous les statuts'}
                            </GhostButton>
                        </div>
                        <div css={tw`xl:w-72 flex-shrink-0`}>
                            <SegmentedControl value={period} onChange={setPeriod} options={periodOptions} />
                        </div>
                    </div>
                </div>

                {sortedIncidents.length === 0 ? (
                    <EmptyState
                        icon={<Icon.Shield size={36} />}
                        title="Aucun incident"
                        description={
                            activeOnly || historyQ || attackType !== 'all' || period !== 'all'
                                ? 'Aucun résultat pour ce filtre.'
                                : 'Aucune attaque enregistrée pour le moment.'
                        }
                    />
                ) : (
                    <>
                        <DataTable
                            headers={[
                                { key: 'ip', label: 'Adresse IP', width: '22%' },
                                { key: 'type', label: 'Type', width: '16%' },
                                { key: 'when', label: 'Période', width: '22%' },
                                { key: 'bps', label: 'Pic débit', width: '14%', align: 'right' },
                                { key: 'pps', label: 'Pic PPS', width: '14%', align: 'right' },
                                { key: 'go', label: '', width: '12%', align: 'right' },
                            ]}
                        >
                            {sortedIncidents.map((inc) => {
                                const sev = severityOfBps(inc.max_bps);
                                const mins = durationMin(inc.incident_start, inc.incident_stop);
                                const bare = String(inc.ip || '').split('/')[0];
                                const owner = (ips || []).find((i) => i.ip === bare);
                                const infra = rootAdmin && !ownedIpSet.has(bare);
                                const accent =
                                    sev === 'danger'
                                        ? CloudUI.danger
                                        : sev === 'warn'
                                          ? CloudUI.warning
                                          : CloudUI.success;

                                return (
                                    <HoverRow key={inc.incident_id} onClick={() => setSelected(inc)}>
                                        <Td accent={accent}>
                                            <div css={tw`flex items-center gap-2 flex-wrap`}>
                                                <MonoIp>{inc.ip}</MonoIp>
                                                {!inc.incident_stop ? <Badge tone="danger">En cours</Badge> : null}
                                                {infra ? <Badge tone="warn">Infra</Badge> : null}
                                            </div>
                                            {owner ? (
                                                <Link
                                                    to={`/server/${owner.service.uuid}`}
                                                    onClick={(e) => e.stopPropagation()}
                                                    css={tw`text-sm no-underline inline-block mt-1`}
                                                    style={{ color: CloudUI.textMuted }}
                                                >
                                                    {owner.service.name}
                                                </Link>
                                            ) : null}
                                        </Td>
                                        <Td>
                                            <p css={tw`m-0 text-sm font-medium`} style={{ color: CloudUI.text }}>
                                                {inc.attack_type || inc.diversion_reason || 'attack'}
                                            </p>
                                            {inc.protocol ? <MetaLine>Protocole {inc.protocol}</MetaLine> : null}
                                        </Td>
                                        <Td>
                                            <p css={tw`m-0 text-sm`} style={{ color: CloudUI.textSecondary }}>
                                                {formatWhen(inc.incident_start)}
                                            </p>
                                            <MetaLine>
                                                {inc.incident_stop
                                                    ? `Fin ${formatWhen(inc.incident_stop)}`
                                                    : 'Toujours active'}
                                                {mins ? ` · ${mins} min` : ''}
                                            </MetaLine>
                                        </Td>
                                        <Td align="right">
                                            <span
                                                css={tw`text-base font-semibold tabular-nums`}
                                                style={{ color: CloudUI.text }}
                                            >
                                                {inc.max_bps_formattet || '—'}
                                            </span>
                                        </Td>
                                        <Td align="right">
                                            <span
                                                css={tw`text-sm tabular-nums`}
                                                style={{ color: CloudUI.textMuted }}
                                            >
                                                {inc.max_pps_formattet || '—'}
                                            </span>
                                        </Td>
                                        <Td align="right">
                                            <span
                                                css={tw`inline-flex items-center gap-1 text-xs font-semibold`}
                                                style={{ color: CloudUI.accentHover }}
                                            >
                                                Détail <Icon.ChevronRight size={14} />
                                            </span>
                                        </Td>
                                    </HoverRow>
                                );
                            })}
                        </DataTable>

                        <div css={tw`lg:hidden px-3 sm:px-4 pb-4 space-y-3`}>
                            {sortedIncidents.map((inc) => {
                                const sev = severityOfBps(inc.max_bps);
                                const mins = durationMin(inc.incident_start, inc.incident_stop);
                                const bare = String(inc.ip || '').split('/')[0];
                                const owner = (ips || []).find((i) => i.ip === bare);
                                const accent =
                                    sev === 'danger'
                                        ? CloudUI.danger
                                        : sev === 'warn'
                                          ? CloudUI.warning
                                          : CloudUI.success;

                                return (
                                    <MobileCard
                                        key={inc.incident_id}
                                        accent={accent}
                                        onClick={() => setSelected(inc)}
                                    >
                                        <div css={tw`flex items-start justify-between gap-3`}>
                                            <div css={tw`min-w-0 flex-1`}>
                                                <div css={tw`flex items-center gap-2 flex-wrap`}>
                                                    <MonoIp>{inc.ip}</MonoIp>
                                                    {!inc.incident_stop ? (
                                                        <Badge tone="danger">En cours</Badge>
                                                    ) : null}
                                                </div>
                                                {owner ? (
                                                    <p
                                                        css={tw`m-0 mt-2 text-sm truncate font-medium`}
                                                        style={{ color: CloudUI.text }}
                                                    >
                                                        {owner.service.name}
                                                    </p>
                                                ) : null}
                                            </div>
                                            <Icon.ChevronRight
                                                size={20}
                                                style={{ color: CloudUI.textMuted, marginTop: 2, flexShrink: 0 }}
                                            />
                                        </div>

                                        <div css={tw`flex flex-wrap gap-2`}>
                                            <Badge
                                                tone={
                                                    sev === 'danger' ? 'danger' : sev === 'warn' ? 'warn' : 'ok'
                                                }
                                            >
                                                {inc.attack_type || inc.diversion_reason || 'attack'}
                                            </Badge>
                                            {inc.protocol ? <Badge tone="neutral">{inc.protocol}</Badge> : null}
                                        </div>

                                        <MobileMetaGrid
                                            items={[
                                                { label: 'Début', value: formatWhen(inc.incident_start) },
                                                {
                                                    label: 'Durée',
                                                    value: mins
                                                        ? `${mins} min`
                                                        : inc.incident_stop
                                                          ? '—'
                                                          : 'En cours',
                                                },
                                                {
                                                    label: 'Pic débit',
                                                    value: (
                                                        <span
                                                            css={tw`font-semibold`}
                                                            style={{ color: CloudUI.text }}
                                                        >
                                                            {inc.max_bps_formattet || '—'}
                                                        </span>
                                                    ),
                                                },
                                                {
                                                    label: 'Pic PPS',
                                                    value: inc.max_pps_formattet || '—',
                                                },
                                            ]}
                                        />
                                    </MobileCard>
                                );
                            })}
                        </div>
                    </>
                )}
            </Panel>

            <NetworkIncidentModal
                incident={selected}
                onClose={() => {
                    setSelected(null);
                    if (initialIncident)
                        history.replace(
                            historyQ ? `/network/ddos?ip=${encodeURIComponent(historyQ)}` : '/network/ddos'
                        );
                }}
            />
        </NetworkPage>
    );
};
