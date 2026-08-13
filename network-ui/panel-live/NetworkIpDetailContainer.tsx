import React, { Fragment, useEffect, useMemo, useState } from 'react';
import tw from 'twin.macro';
import { useParams, useHistory, useLocation } from 'react-router-dom';
import useSWR from 'swr';
import * as Icon from 'react-feather';
import useFlash from '@/plugins/useFlash';
import Spinner from '@/components/elements/Spinner';
import NetworkNavTabs from '@/components/network/NetworkNavTabs';
import NetworkIpStatsTab from '@/components/network/NetworkIpStatsTab';
import NetworkIpAnalysisTab from '@/components/network/NetworkIpAnalysisTab';
import HmsModal from '@/components/hms/HmsModal';
import { HMS } from '@/components/hms/hmsTheme';
import { CloudUI } from '@/components/hms/cloudUi';
import {
    DdosFilterMode,
    DdosIncident,
    getDdosFilterModes,
    getDdosIncidents,
    getNetworkIps,
    NetworkIpRow,
    updateNetworkRdns,
} from '@/api/network';
import {
    Badge,
    DataTable,
    EmptyState,
    GhostButton,
    GhostLink,
    NetworkHeader,
    NetworkPage,
    Panel,
    PrimaryButton,
    SearchField,
    Td,
    copyText,
    formatWhen,
} from '@/components/network/NetworkUi';

type PrefixTab = 'general' | 'stats' | 'analysis' | 'attacks';

const cidrLabel = (ip: string) => (ip.includes('/') ? ip : `${ip}/32`);
const bareIp = (ip: string) => ip.split('/')[0] || ip;

const inAddrArpa = (ip: string) => {
    const parts = bareIp(ip).split('.');
    if (parts.length !== 4) return '—';
    return `${parts[2]}.${parts[1]}.${parts[0]}.in-addr.arpa`;
};

const gatewayFromPrefix = (ip: string) => {
    const bare = bareIp(ip);
    const parts = bare.split('.');
    if (parts.length !== 4) return '—';
    return `${parts[0]}.${parts[1]}.${parts[2]}.1`;
};

const maskFromPrefix = (ip: string) => {
    if (cidrLabel(ip).endsWith('/32')) return '255.255.255.255';
    return '—';
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

const CopyIconButton = ({
    value,
    copied,
    onCopy,
}: {
    value: string;
    copied: boolean;
    onCopy: (v: string) => void;
}) => (
    <button
        type="button"
        title={copied ? 'Copié' : 'Copier'}
        onClick={() => onCopy(value)}
        css={tw`inline-flex items-center justify-center rounded-lg border-0 cursor-pointer transition-colors flex-shrink-0`}
        style={{
            width: 34,
            height: 34,
            background: copied ? CloudUI.accentMuted : 'rgba(255,255,255,0.03)',
            color: copied ? CloudUI.accentHover : CloudUI.textMuted,
            border: `1px solid ${copied ? 'rgba(16,185,129,0.35)' : HMS.cardBorder}`,
        }}
    >
        {copied ? <Icon.Check size={14} /> : <Icon.Copy size={14} />}
    </button>
);

const HoverRow = ({ children }: { children: React.ReactNode }) => {
    const [hover, setHover] = useState(false);
    return (
        <tr
            onMouseEnter={() => setHover(true)}
            onMouseLeave={() => setHover(false)}
            style={{
                background: hover ? 'rgba(255,255,255,0.025)' : 'transparent',
                transition: 'background 0.12s ease',
            }}
        >
            {children}
        </tr>
    );
};

const DefRow = ({
    label,
    children,
    last,
}: {
    label: string;
    children: React.ReactNode;
    last?: boolean;
}) => (
    <div
        css={tw`flex items-center justify-between gap-4 px-4 sm:px-6 py-3.5`}
        style={{ borderBottom: last ? 'none' : `1px solid ${HMS.cardBorder}` }}
    >
        <dt css={tw`m-0 text-sm`} style={{ color: CloudUI.textMuted }}>
            {label}
        </dt>
        <dd css={tw`m-0 text-right min-w-0`}>{children}</dd>
    </div>
);

export default () => {
    const { ipId } = useParams<{ ipId: string }>();
    const history = useHistory();
    const location = useLocation();
    const decoded = useMemo(() => {
        try {
            return decodeURIComponent(ipId || '');
        } catch {
            return ipId || '';
        }
    }, [ipId]);

    const { clearFlashes, clearAndAddHttpError, addFlash } = useFlash();
    const { data: ips, error, mutate } = useSWR<NetworkIpRow[]>('network-ips', getNetworkIps, {
        revalidateOnFocus: true,
    });
    const { data: modes } = useSWR<DdosFilterMode[]>('network-ddos-modes', getDdosFilterModes);
    const { data: incidents } = useSWR<DdosIncident[]>('network-ddos-incidents', getDdosIncidents);

    const [editOpen, setEditOpen] = useState(false);
    const [hostname, setHostname] = useState('');
    const [saving, setSaving] = useState(false);
    const [copied, setCopied] = useState<string | null>(null);
    const [ptrFilter, setPtrFilter] = useState('');
    const [selected, setSelected] = useState(false);

    const basePath = `/network/ips/${encodeURIComponent(decoded)}`;
    const tab: PrefixTab = location.pathname.endsWith('/stats')
        ? 'stats'
        : location.pathname.endsWith('/analysis')
          ? 'analysis'
          : location.pathname.endsWith('/attacks')
            ? 'attacks'
            : 'general';
    const setTab = (next: PrefixTab) => {
        if (next === 'general') history.push(basePath);
        else history.push(`${basePath}/${next}`);
    };

    const row = useMemo(() => {
        if (!ips || !decoded) return null;
        return (
            ips.find(
                (r) =>
                    r.ip === decoded ||
                    bareIp(r.ip) === bareIp(decoded) ||
                    cidrLabel(r.ip) === decoded ||
                    cidrLabel(r.ip) === cidrLabel(decoded)
            ) || null
        );
    }, [ips, decoded]);

    const modeByIp = useMemo(() => {
        const map: Record<string, DdosFilterMode> = {};
        (modes || []).forEach((m) => {
            map[m.ip] = m;
        });
        return map;
    }, [modes]);

    useEffect(() => {
        setSelected(false);
        setPtrFilter('');
    }, [decoded]);

    useEffect(() => {
        if (error) clearAndAddHttpError({ error });
        else clearFlashes();
    }, [error]);

    const relatedIncidents = useMemo(() => {
        if (!row || !incidents) return [];
        const target = bareIp(row.ip).toLowerCase();
        return incidents.filter((i) => {
            const ip = String(i.ip || '')
                .split('/')[0]
                .toLowerCase();
            return !ip || ip === target || ip.includes(target) || target.includes(ip);
        });
    }, [incidents, row]);

    const activeIncidents = useMemo(
        () => relatedIncidents.filter((i) => !i.incident_stop).length,
        [relatedIncidents]
    );

    if (!ips && !error) {
        return (
            <div css={tw`py-24 flex justify-center`}>
                <Spinner size={'large'} />
            </div>
        );
    }

    if (!row) {
        return (
            <NetworkPage>
                <NetworkNavTabs active="ips" />
                <EmptyState
                    icon={<Icon.Globe size={36} />}
                    title="Préfixe introuvable"
                    description="Cette adresse IP n’appartient pas à votre compte ou n’est plus disponible."
                />
                <div css={tw`mt-4`}>
                    <GhostButton onClick={() => history.push('/network/ips')}>
                        <Icon.ArrowLeft size={14} />
                        Retour aux IPs
                    </GhostButton>
                </div>
            </NetworkPage>
        );
    }

    const label = cidrLabel(row.ip);
    const ipBare = bareIp(row.ip);
    const ptr = row.reverse_dns?.preferred || row.reverse_dns?.live || '';
    const zone = inAddrArpa(row.ip);
    const filterMode = modeByIp[row.ip]?.filter_mode || 'dynamic';
    const alwaysOn = filterMode === 'always_on';
    const ptrVisible =
        !ptrFilter.trim() ||
        ipBare.toLowerCase().includes(ptrFilter.toLowerCase()) ||
        ptr.toLowerCase().includes(ptrFilter.toLowerCase());

    const tabs: { id: PrefixTab; label: string }[] = [
        { id: 'general', label: 'Informations générales' },
        { id: 'stats', label: 'Statistiques' },
        { id: 'analysis', label: 'Analyse' },
        { id: 'attacks', label: 'Attaques' },
    ];

    const onCopy = async (value: string) => {
        const ok = await copyText(value);
        if (ok) {
            setCopied(value);
            window.setTimeout(() => setCopied((c) => (c === value ? null : c)), 1400);
        }
    };

    const openEdit = () => {
        setHostname(row.reverse_dns?.preferred || row.reverse_dns?.live || '');
        setEditOpen(true);
    };

    const saveRdns = async () => {
        setSaving(true);
        try {
            await updateNetworkRdns(row.ip, hostname.trim() || null);
            await mutate();
            setEditOpen(false);
            addFlash({ key: 'network:ips', type: 'success', message: 'Reverse DNS enregistré.' });
        } catch (e) {
            clearAndAddHttpError({ key: 'network:ips', error: e });
        } finally {
            setSaving(false);
        }
    };

    const downloadCsv = () => {
        if (!selected) return;
        const lines = ['IP,Zone,PTR', `${ipBare},${zone},"${String(ptr).replace(/"/g, '""')}"`];
        const blob = new Blob([lines.join('\n')], { type: 'text/csv;charset=utf-8' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = `ptr-${ipBare}.csv`;
        a.click();
        URL.revokeObjectURL(url);
    };

    return (
        <NetworkPage>
            <div css={tw`flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between`}>
                <div css={tw`min-w-0`}>
                    <NetworkHeader
                        icon={Icon.Globe}
                        title={label}
                        subtitle="Configuration réseau, reverse DNS et protection DDoS de ce préfixe."
                    />
                    <div css={tw`mt-3 flex flex-wrap items-center gap-3`}>
                        <StatusDot tone={row.routed ? 'ok' : 'neutral'} label={row.routed ? 'Routé' : 'Non routé'} />
                        <StatusDot
                            tone={alwaysOn ? 'warn' : 'ok'}
                            label={alwaysOn ? 'Always-on' : 'Dynamic'}
                        />
                        <span css={tw`text-sm truncate`} style={{ color: CloudUI.textMuted }}>
                            {row.service?.name || (row.routed ? 'Service routé' : 'Non routé')}
                        </span>
                    </div>
                </div>
                <div css={tw`flex flex-wrap items-center gap-2 flex-shrink-0`}>
                    <CopyIconButton value={label} copied={copied === label} onCopy={onCopy} />
                    <GhostLink compact to="/network/ips">
                        <Icon.ArrowLeft size={13} />
                        Retour
                    </GhostLink>
                </div>
            </div>

            <NetworkNavTabs active="ips" />

            <div
                css={tw`rounded-xl px-4 sm:px-6 py-4 grid grid-cols-2 lg:grid-cols-4 gap-4 sm:gap-6`}
                style={{
                    background: CloudUI.surface,
                    border: `1px solid ${HMS.cardBorder}`,
                }}
            >
                <Metric
                    label="Routage"
                    value={row.routed ? 'Actif' : 'Inactif'}
                    hint={row.service?.name || (row.routed ? 'Service lié' : 'Sans service')}
                    tone={row.routed ? 'ok' : 'default'}
                />
                <Metric
                    label="Anti-DDoS"
                    value={alwaysOn ? 'Always-on' : 'Dynamic'}
                    hint="Protection anti-DDoS"
                    tone={alwaysOn ? 'warn' : 'ok'}
                />
                <Metric
                    label="Reverse DNS"
                    value={ptr ? 'OK' : '—'}
                    hint={ptr || 'Non défini'}
                    tone={ptr ? 'ok' : 'default'}
                />
                <Metric
                    label="Attaques"
                    value={relatedIncidents.length}
                    hint={
                        activeIncidents
                            ? `${activeIncidents} en cours`
                            : relatedIncidents.length
                              ? 'Historique'
                              : 'Aucune'
                    }
                    tone={activeIncidents ? 'danger' : relatedIncidents.length ? 'warn' : 'ok'}
                />
            </div>

            <div
                css={tw`flex p-1 rounded-xl gap-1 w-full overflow-x-auto`}
                style={{ background: HMS.inputBg, border: `1px solid ${HMS.cardBorder}` }}
                role="tablist"
            >
                {tabs.map((t) => {
                    const active = tab === t.id;
                    return (
                        <button
                            key={t.id}
                            type="button"
                            role="tab"
                            aria-selected={active}
                            onClick={() => setTab(t.id)}
                            css={tw`flex-1 px-2 sm:px-3 py-2 rounded-lg text-xs sm:text-sm font-medium whitespace-nowrap border-0 cursor-pointer transition-colors text-center`}
                            style={{
                                background: active ? CloudUI.accentMuted : 'transparent',
                                color: active ? CloudUI.accentHover : CloudUI.textMuted,
                                boxShadow: active ? 'inset 0 0 0 1px rgba(16,185,129,0.28)' : 'none',
                                minHeight: 40,
                            }}
                        >
                            {t.label}
                            {t.id === 'attacks' && relatedIncidents.length ? (
                                <span
                                    css={tw`ml-1.5 inline-flex items-center justify-center rounded-md px-1.5 text-[10px] font-semibold tabular-nums`}
                                    style={{
                                        background: activeIncidents
                                            ? 'rgba(239,68,68,0.18)'
                                            : 'rgba(255,255,255,0.06)',
                                        color: activeIncidents ? CloudUI.danger : CloudUI.textMuted,
                                    }}
                                >
                                    {relatedIncidents.length}
                                </span>
                            ) : null}
                        </button>
                    );
                })}
            </div>

            {tab === 'general' ? (
                <Fragment>
                    <div css={tw`grid grid-cols-1 lg:grid-cols-2 gap-4 sm:gap-5`}>
                        <Panel padded={false}>
                            <div
                                css={tw`px-4 sm:px-6 py-4 border-b`}
                                style={{ borderColor: HMS.cardBorder }}
                            >
                                <h2 css={tw`m-0 text-base font-semibold tracking-tight`} style={{ color: CloudUI.text }}>
                                    Configuration réseau
                                </h2>
                                <p css={tw`m-0 mt-1 text-sm`} style={{ color: CloudUI.textMuted }}>
                                    Paramètres d&apos;adressage pour {ipBare}
                                </p>
                            </div>
                            <dl css={tw`m-0`}>
                                <DefRow label="Masque">
                                    <span css={tw`font-mono text-sm font-medium`} style={{ color: CloudUI.text }}>
                                        {maskFromPrefix(row.ip)}
                                    </span>
                                </DefRow>
                                <DefRow label="Passerelle">
                                    <span css={tw`inline-flex items-center gap-2`}>
                                        <span css={tw`font-mono text-sm font-medium`} style={{ color: CloudUI.text }}>
                                            {gatewayFromPrefix(row.ip)}
                                        </span>
                                        <CopyIconButton
                                            value={gatewayFromPrefix(row.ip)}
                                            copied={copied === gatewayFromPrefix(row.ip)}
                                            onCopy={onCopy}
                                        />
                                    </span>
                                </DefRow>
                                <DefRow label="DNS">
                                    <span css={tw`inline-flex items-center gap-2`}>
                                        <span css={tw`font-mono text-sm font-medium`} style={{ color: CloudUI.text }}>
                                            1.1.1.1
                                        </span>
                                        <CopyIconButton
                                            value="1.1.1.1"
                                            copied={copied === '1.1.1.1'}
                                            onCopy={onCopy}
                                        />
                                    </span>
                                </DefRow>
                                <DefRow label="Anti-DDoS">
                                    <Badge tone="ok">
                                        <Icon.Shield size={11} />
                                        Activé
                                    </Badge>
                                </DefRow>
                                <DefRow label="MAC" last>
                                    <span css={tw`font-mono text-sm font-medium`} style={{ color: CloudUI.text }}>
                                        00:00:00:00:00:00
                                    </span>
                                </DefRow>
                            </dl>
                        </Panel>

                        <Panel padded={false}>
                            <div
                                css={tw`px-4 sm:px-6 py-4 border-b`}
                                style={{ borderColor: HMS.cardBorder }}
                            >
                                <h2 css={tw`m-0 text-base font-semibold tracking-tight`} style={{ color: CloudUI.text }}>
                                    Statut routage
                                </h2>
                                <p css={tw`m-0 mt-1 text-sm`} style={{ color: CloudUI.textMuted }}>
                                    Instance et état de publication BGP
                                </p>
                            </div>
                            <div css={tw`px-4 sm:px-6 py-5 space-y-4`}>
                                <div css={tw`flex items-start justify-between gap-4`}>
                                    <p css={tw`m-0 text-sm leading-relaxed`} style={{ color: CloudUI.textMuted }}>
                                        {row.routed
                                            ? 'Ce préfixe est actuellement routé vers un service.'
                                            : 'Aucune route active détectée pour ce préfixe.'}
                                    </p>
                                    <StatusDot
                                        tone={row.routed ? 'ok' : 'neutral'}
                                        label={row.routed ? 'Routé' : 'Non routé'}
                                    />
                                </div>

                                {row.service?.uuid ? (
                                    <div
                                        css={tw`rounded-xl px-4 py-4 flex flex-col sm:flex-row sm:items-center gap-3`}
                                        style={{
                                            background: 'rgba(255,255,255,0.02)',
                                            border: `1px solid ${HMS.cardBorder}`,
                                        }}
                                    >
                                        <div
                                            css={tw`w-10 h-10 rounded-lg flex items-center justify-center flex-shrink-0`}
                                            style={{
                                                background: CloudUI.accentMuted,
                                                color: CloudUI.accentHover,
                                                border: '1px solid rgba(16,185,129,0.28)',
                                            }}
                                        >
                                            <Icon.Server size={18} />
                                        </div>
                                        <div css={tw`min-w-0 flex-1`}>
                                            <p
                                                css={tw`m-0 text-[11px] font-semibold uppercase tracking-wider`}
                                                style={{ color: CloudUI.textMuted, letterSpacing: '0.08em' }}
                                            >
                                                Service routé
                                            </p>
                                            <p
                                                css={tw`m-0 mt-0.5 text-base font-semibold truncate`}
                                                style={{ color: CloudUI.text }}
                                            >
                                                {row.service.name || row.service.uuidShort || row.service.uuid}
                                            </p>
                                            <p
                                                css={tw`m-0 mt-0.5 text-xs font-mono truncate`}
                                                style={{ color: CloudUI.textMuted }}
                                            >
                                                {row.service.uuidShort || row.service.uuid}
                                            </p>
                                        </div>
                                        <GhostLink compact to={`/server/${row.service.uuid}`}>
                                            Ouvrir
                                            <Icon.ExternalLink size={12} />
                                        </GhostLink>
                                    </div>
                                ) : (
                                    <EmptyState
                                        icon={<Icon.Server size={28} />}
                                        title="Non routé"
                                        description="Aucune instance n’est associée à ce préfixe pour le moment."
                                    />
                                )}
                            </div>
                        </Panel>
                    </div>

                    <Panel padded={false}>
                        <div
                            css={tw`px-4 sm:px-6 py-4 sm:py-5 flex flex-col lg:flex-row lg:items-end lg:justify-between gap-3`}
                            style={{ borderBottom: `1px solid ${HMS.cardBorder}` }}
                        >
                            <div css={tw`min-w-0`}>
                                <h2 css={tw`m-0 text-base font-semibold tracking-tight`} style={{ color: CloudUI.text }}>
                                    PTR / Reverse DNS
                                </h2>
                                <p css={tw`m-0 mt-1 text-sm leading-relaxed max-w-2xl`} style={{ color: CloudUI.textMuted }}>
                                    Associez un hostname à {ipBare} pour le reverse DNS.
                                </p>
                            </div>
                            <div css={tw`w-full lg:w-72 flex-shrink-0`}>
                                <SearchField
                                    value={ptrFilter}
                                    onChange={setPtrFilter}
                                    placeholder="Filtrer par IP ou hostname…"
                                />
                            </div>
                        </div>

                        <div
                            css={tw`flex flex-wrap items-center justify-between gap-2 px-4 sm:px-6 py-3`}
                            style={{
                                borderBottom: `1px solid ${HMS.cardBorder}`,
                                background: 'rgba(255,255,255,0.015)',
                            }}
                        >
                            <div css={tw`flex flex-wrap gap-2`}>
                                <GhostButton compact onClick={() => setSelected(true)}>
                                    Sélectionner
                                </GhostButton>
                                <GhostButton compact disabled={!selected} onClick={() => setSelected(false)}>
                                    Retirer
                                </GhostButton>
                            </div>
                            <GhostButton compact disabled={!selected} onClick={downloadCsv}>
                                <Icon.Download size={13} />
                                CSV
                            </GhostButton>
                        </div>

                        {ptrVisible ? (
                            <DataTable
                                headers={[
                                    { key: 'cb', label: '', width: '6%' },
                                    { key: 'ip', label: 'IP', width: '18%' },
                                    { key: 'zone', label: 'Zone', width: '28%' },
                                    { key: 'ptr', label: 'État PTR', width: '30%' },
                                    { key: 'act', label: '', width: '18%', align: 'right' },
                                ]}
                            >
                                <HoverRow>
                                    <Td>
                                        <input
                                            type="checkbox"
                                            checked={selected}
                                            onChange={(e) => setSelected(e.target.checked)}
                                        />
                                    </Td>
                                    <Td>
                                        <span css={tw`font-mono text-sm font-medium`} style={{ color: CloudUI.text }}>
                                            {ipBare}
                                        </span>
                                    </Td>
                                    <Td>
                                        <span css={tw`font-mono text-xs`} style={{ color: CloudUI.textMuted }}>
                                            {zone}
                                        </span>
                                    </Td>
                                    <Td>
                                        {ptr ? (
                                            <span
                                                css={tw`font-mono text-sm break-all`}
                                                style={{ color: CloudUI.textSecondary }}
                                            >
                                                {ptr}
                                            </span>
                                        ) : (
                                            <Badge tone="neutral">Non défini</Badge>
                                        )}
                                    </Td>
                                    <Td align="right">
                                        <GhostButton compact onClick={openEdit}>
                                            <Icon.Edit3 size={13} />
                                            Modifier
                                        </GhostButton>
                                    </Td>
                                </HoverRow>
                            </DataTable>
                        ) : (
                            <p
                                css={tw`hidden lg:block m-0 py-10 text-center text-sm`}
                                style={{ color: CloudUI.textMuted }}
                            >
                                Aucun PTR à afficher
                            </p>
                        )}

                        <div css={tw`lg:hidden px-4 py-4 space-y-3`}>
                            {ptrVisible ? (
                                <div
                                    css={tw`rounded-xl p-4 space-y-3`}
                                    style={{ border: `1px solid ${HMS.cardBorder}` }}
                                >
                                    <div css={tw`flex items-center justify-between gap-3`}>
                                        <label css={tw`inline-flex items-center gap-2 text-sm`} style={{ color: CloudUI.textSecondary }}>
                                            <input
                                                type="checkbox"
                                                checked={selected}
                                                onChange={(e) => setSelected(e.target.checked)}
                                            />
                                            Sélection
                                        </label>
                                        <GhostButton compact onClick={openEdit}>
                                            <Icon.Edit3 size={13} />
                                            Modifier
                                        </GhostButton>
                                    </div>
                                    <div>
                                        <p
                                            css={tw`m-0 text-[11px] font-semibold uppercase tracking-wider`}
                                            style={{ color: CloudUI.textMuted }}
                                        >
                                            IP
                                        </p>
                                        <p css={tw`m-0 mt-1 font-mono text-sm`} style={{ color: CloudUI.text }}>
                                            {ipBare}
                                        </p>
                                    </div>
                                    <div>
                                        <p
                                            css={tw`m-0 text-[11px] font-semibold uppercase tracking-wider`}
                                            style={{ color: CloudUI.textMuted }}
                                        >
                                            Zone
                                        </p>
                                        <p css={tw`m-0 mt-1 font-mono text-xs`} style={{ color: CloudUI.textMuted }}>
                                            {zone}
                                        </p>
                                    </div>
                                    <div>
                                        <p
                                            css={tw`m-0 text-[11px] font-semibold uppercase tracking-wider`}
                                            style={{ color: CloudUI.textMuted }}
                                        >
                                            PTR
                                        </p>
                                        <p css={tw`m-0 mt-1 font-mono text-sm break-all`} style={{ color: CloudUI.textSecondary }}>
                                            {ptr || 'Non défini'}
                                        </p>
                                    </div>
                                </div>
                            ) : (
                                <p css={tw`m-0 text-sm text-center py-6`} style={{ color: CloudUI.textMuted }}>
                                    Aucun PTR à afficher
                                </p>
                            )}
                        </div>

                        <div
                            css={tw`px-4 sm:px-6 py-3 text-xs border-t`}
                            style={{ color: CloudUI.textMuted, borderColor: HMS.cardBorder }}
                        >
                            {selected ? '1 ligne sélectionnée.' : 'Aucune ligne sélectionnée.'}
                        </div>
                    </Panel>
                </Fragment>
            ) : null}

            {tab === 'stats' ? <NetworkIpStatsTab row={row} prefixLabel={label} /> : null}

            {tab === 'analysis' ? <NetworkIpAnalysisTab row={row} prefixLabel={label} /> : null}

            {tab === 'attacks' ? (
                <Panel padded={false}>
                    <div
                        css={tw`px-4 sm:px-6 py-4 sm:py-5 flex flex-col sm:flex-row sm:items-end sm:justify-between gap-3`}
                        style={{ borderBottom: `1px solid ${HMS.cardBorder}` }}
                    >
                        <div>
                            <h2 css={tw`m-0 text-base font-semibold tracking-tight`} style={{ color: CloudUI.text }}>
                                Historique des attaques
                            </h2>
                            <p css={tw`m-0 mt-1 text-sm`} style={{ color: CloudUI.textMuted }}>
                                Événements DDoS enregistrés pour {label}
                            </p>
                        </div>
                        <GhostLink compact to={`/network/ddos?ip=${encodeURIComponent(row.ip)}`}>
                            Voir toutes
                            <Icon.ArrowRight size={12} />
                        </GhostLink>
                    </div>
                    {relatedIncidents.length === 0 ? (
                        <EmptyState
                            icon={<Icon.Shield size={36} />}
                            title="Aucune attaque"
                            description="Aucune attaque enregistrée pour cette période."
                        />
                    ) : (
                        <>
                            <DataTable
                                headers={[
                                    { key: 'start', label: 'Début', width: '22%' },
                                    { key: 'end', label: 'Fin', width: '22%' },
                                    { key: 'type', label: 'Type', width: '22%' },
                                    { key: 'bps', label: 'Débit', width: '18%' },
                                    { key: 'act', label: '', width: '16%', align: 'right' },
                                ]}
                            >
                                {relatedIncidents.map((inc) => (
                                    <HoverRow key={inc.incident_id}>
                                        <Td>
                                            <span css={tw`text-sm`} style={{ color: CloudUI.textSecondary }}>
                                                {formatWhen(inc.incident_start)}
                                            </span>
                                        </Td>
                                        <Td>
                                            <span css={tw`text-sm`} style={{ color: CloudUI.textSecondary }}>
                                                {inc.incident_stop ? formatWhen(inc.incident_stop) : '—'}
                                            </span>
                                        </Td>
                                        <Td>
                                            {!inc.incident_stop ? (
                                                <Badge tone="danger">En cours</Badge>
                                            ) : (
                                                <Badge tone="warn">
                                                    {inc.attack_type || inc.diversion_reason || 'Attaque'}
                                                </Badge>
                                            )}
                                        </Td>
                                        <Td>
                                            <span css={tw`text-sm tabular-nums`} style={{ color: CloudUI.textSecondary }}>
                                                {inc.max_bps_formattet || '—'}
                                            </span>
                                        </Td>
                                        <Td align="right">
                                            <GhostLink
                                                compact
                                                to={`/network/ddos?ip=${encodeURIComponent(row.ip)}&incident=${encodeURIComponent(inc.incident_id)}`}
                                            >
                                                Voir
                                            </GhostLink>
                                        </Td>
                                    </HoverRow>
                                ))}
                            </DataTable>
                            <div css={tw`lg:hidden px-4 py-4 space-y-3`}>
                                {relatedIncidents.map((inc) => (
                                    <div
                                        key={inc.incident_id}
                                        css={tw`rounded-xl p-4 space-y-2`}
                                        style={{ border: `1px solid ${HMS.cardBorder}` }}
                                    >
                                        <div css={tw`flex items-center justify-between gap-2`}>
                                            {!inc.incident_stop ? (
                                                <Badge tone="danger">En cours</Badge>
                                            ) : (
                                                <Badge tone="warn">
                                                    {inc.attack_type || inc.diversion_reason || 'Attaque'}
                                                </Badge>
                                            )}
                                            <span css={tw`text-sm tabular-nums`} style={{ color: CloudUI.textSecondary }}>
                                                {inc.max_bps_formattet || '—'}
                                            </span>
                                        </div>
                                        <p css={tw`m-0 text-sm`} style={{ color: CloudUI.textMuted }}>
                                            {formatWhen(inc.incident_start)}
                                            {inc.incident_stop ? ` → ${formatWhen(inc.incident_stop)}` : ''}
                                        </p>
                                        <GhostLink
                                            fullWidth
                                            to={`/network/ddos?ip=${encodeURIComponent(row.ip)}&incident=${encodeURIComponent(inc.incident_id)}`}
                                        >
                                            Voir l&apos;attaque
                                        </GhostLink>
                                    </div>
                                ))}
                            </div>
                        </>
                    )}
                </Panel>
            ) : null}

            <HmsModal visible={editOpen} onClose={() => setEditOpen(false)} maxWidth="28rem">
                <div css={tw`p-5 sm:p-6`}>
                    <div css={tw`flex items-start gap-3.5 pr-8`}>
                        <div
                            css={tw`w-11 h-11 rounded-full flex items-center justify-center flex-shrink-0`}
                            style={{
                                background: 'rgba(245,158,11,0.14)',
                                color: CloudUI.warning,
                                border: '1px solid rgba(245,158,11,0.28)',
                            }}
                        >
                            <Icon.AlertTriangle size={20} strokeWidth={1.75} />
                        </div>
                        <div css={tw`min-w-0 pt-0.5`}>
                            <h3
                                css={tw`text-base sm:text-lg font-semibold m-0 tracking-tight`}
                                style={{ color: CloudUI.text }}
                            >
                                Modifier le PTR / Reverse DNS
                            </h3>
                            <p css={tw`text-sm m-0 mt-1.5 leading-relaxed`} style={{ color: CloudUI.textMuted }}>
                                Mettez à jour le PTR de cette IP. Cette action impacte directement la résolution
                                reverse DNS.
                            </p>
                        </div>
                    </div>

                    <div css={tw`mt-5 space-y-4`}>
                        <div
                            css={tw`rounded-xl px-3.5 py-3 text-xs leading-relaxed`}
                            style={{
                                background: 'rgba(245,158,11,0.08)',
                                border: '1px solid rgba(245,158,11,0.22)',
                                color: '#fbbf24',
                            }}
                        >
                            Utilisez un FQDN valide (ex.&nbsp;: <span css={tw`font-mono`}>host.example.com</span>).
                            Une mauvaise valeur peut perturber la délivrabilité mail et certains contrôles réseau.
                        </div>

                        <div
                            css={tw`rounded-xl px-4 py-3.5 space-y-3`}
                            style={{
                                background: 'rgba(255,255,255,0.02)',
                                border: `1px solid ${HMS.cardBorder}`,
                            }}
                        >
                            <div css={tw`flex items-start justify-between gap-3`}>
                                <div css={tw`min-w-0`}>
                                    <p
                                        css={tw`m-0 text-[11px] font-semibold uppercase tracking-wider`}
                                        style={{ color: CloudUI.textMuted, letterSpacing: '0.12em' }}
                                    >
                                        Adresse IP
                                    </p>
                                    <p
                                        css={tw`m-0 mt-1 font-mono text-sm font-medium truncate`}
                                        style={{ color: CloudUI.text }}
                                    >
                                        {ipBare}
                                    </p>
                                </div>
                                <CopyIconButton
                                    value={ipBare}
                                    copied={copied === ipBare}
                                    onCopy={onCopy}
                                />
                            </div>
                            <div
                                css={tw`pt-3`}
                                style={{ borderTop: `1px solid ${HMS.cardBorder}` }}
                            >
                                <p
                                    css={tw`m-0 text-[11px] font-semibold uppercase tracking-wider`}
                                    style={{ color: CloudUI.textMuted, letterSpacing: '0.12em' }}
                                >
                                    PTR actuel
                                </p>
                                <p
                                    css={tw`m-0 mt-1 font-mono text-sm break-all`}
                                    style={{ color: ptr ? CloudUI.textSecondary : CloudUI.textMuted }}
                                >
                                    {ptr || 'Non défini'}
                                </p>
                            </div>
                        </div>

                        <label css={tw`block`} htmlFor="ptr-target">
                            <span
                                css={tw`block text-sm font-medium mb-2`}
                                style={{ color: CloudUI.textSecondary }}
                            >
                                Nom d&apos;hôte cible (FQDN)
                            </span>
                            <input
                                id="ptr-target"
                                value={hostname}
                                onChange={(e) => setHostname(e.target.value)}
                                placeholder="ex: srv01.example.com"
                                autoCapitalize="none"
                                autoCorrect="off"
                                spellCheck={false}
                                inputMode="url"
                                autoFocus
                                css={tw`w-full rounded-xl px-3.5 py-3 outline-none text-sm transition-shadow`}
                                style={{
                                    background: HMS.inputBg,
                                    color: CloudUI.text,
                                    border: `1px solid ${HMS.cardBorder}`,
                                    minHeight: 46,
                                    fontFamily: CloudUI.fontMono,
                                    boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.02)',
                                }}
                                onFocus={(e) => {
                                    e.currentTarget.style.borderColor = 'rgba(16,185,129,0.55)';
                                    e.currentTarget.style.boxShadow = '0 0 0 3px rgba(16,185,129,0.16)';
                                }}
                                onBlur={(e) => {
                                    e.currentTarget.style.borderColor = HMS.cardBorder;
                                    e.currentTarget.style.boxShadow = 'inset 0 1px 0 rgba(255,255,255,0.02)';
                                }}
                            />
                            <span
                                css={tw`block mt-2 text-xs leading-relaxed`}
                                style={{ color: CloudUI.textMuted }}
                            >
                                Par défaut : <span css={tw`font-mono`}>vps-XX.1vps.cc</span>. Laissez vide pour
                                rétablir ce PTR.
                            </span>
                        </label>
                    </div>

                    <div
                        css={tw`mt-6 pt-4 flex flex-col-reverse sm:flex-row sm:justify-end gap-2 sm:gap-3`}
                        style={{ borderTop: `1px solid ${HMS.cardBorder}` }}
                    >
                        <GhostButton onClick={() => setEditOpen(false)}>Annuler</GhostButton>
                        <PrimaryButton onClick={saveRdns} disabled={saving}>
                            {saving ? 'Enregistrement…' : 'Enregistrer'}
                        </PrimaryButton>
                    </div>
                </div>
            </HmsModal>
        </NetworkPage>
    );
};
