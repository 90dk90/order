import React, { Fragment, useEffect, useMemo, useState } from 'react';
import tw from 'twin.macro';
import { Link, useParams, useHistory } from 'react-router-dom';
import useSWR from 'swr';
import * as Icon from 'react-feather';
import useFlash from '@/plugins/useFlash';
import Spinner from '@/components/elements/Spinner';
import NetworkNavTabs from '@/components/network/NetworkNavTabs';
import HmsModal from '@/components/hms/HmsModal';
import { HMS, hmsCardStyle } from '@/components/hms/hmsTheme';
import { CloudUI } from '@/components/hms/cloudUi';
import {
    DdosIncident,
    getDdosIncidents,
    getNetworkIps,
    NetworkIpRow,
    updateNetworkRdns,
} from '@/api/network';
import {
    Badge,
    EmptyState,
    GhostButton,
    NetworkHeader,
    NetworkPage,
    Panel,
    PrimaryButton,
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

const cardShell: React.CSSProperties = {
    ...hmsCardStyle,
    overflow: 'hidden',
};

const sectionIconWrap: React.CSSProperties = {
    width: 32,
    height: 32,
    borderRadius: 8,
    display: 'inline-flex',
    alignItems: 'center',
    justifyContent: 'center',
    background: CloudUI.accentMuted,
    color: CloudUI.accentHover,
    border: '1px solid rgba(16,185,129,0.28)',
    flexShrink: 0,
};

export default () => {
    const { ipId } = useParams<{ ipId: string }>();
    const history = useHistory();
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
    const { data: incidents } = useSWR<DdosIncident[]>('network-ddos-incidents', getDdosIncidents);

    const [tab, setTab] = useState<PrefixTab>('general');
    const [editOpen, setEditOpen] = useState(false);
    const [hostname, setHostname] = useState('');
    const [saving, setSaving] = useState(false);
    const [copied, setCopied] = useState(false);
    const [ptrFilter, setPtrFilter] = useState('');
    const [selected, setSelected] = useState(false);

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

    useEffect(() => {
        setTab('general');
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
    const ptr = row.reverse_dns.preferred || row.reverse_dns.live || '';
    const zone = inAddrArpa(row.ip);
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

    const onCopy = async () => {
        const ok = await copyText(label);
        if (ok) {
            setCopied(true);
            window.setTimeout(() => setCopied(false), 1400);
        }
    };

    const openEdit = () => {
        setHostname(row.reverse_dns.preferred || row.reverse_dns.live || '');
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
            <NetworkHeader
                icon={Icon.Globe}
                title={label}
                subtitle="Gérez votre préfixe IP, configurez le reverse DNS et visualisez les statistiques."
            />
            <NetworkNavTabs active="ips" />

            <div
                css={tw`flex flex-wrap gap-1 border-b mb-6`}
                style={{ borderColor: HMS.cardBorder }}
            >
                {tabs.map((t) => {
                    const active = tab === t.id;
                    return (
                        <button
                            key={t.id}
                            type="button"
                            onClick={() => setTab(t.id)}
                            css={tw`px-4 py-3 text-sm font-semibold border-0 border-b-2 rounded-t-lg cursor-pointer bg-transparent`}
                            style={{
                                color: active ? CloudUI.accentHover : CloudUI.textMuted,
                                borderBottomColor: active ? CloudUI.accent : 'transparent',
                            }}
                        >
                            {t.label}
                        </button>
                    );
                })}
            </div>

            {tab === 'general' ? (
                <Fragment>
                    <div style={cardShell}>
                        <div
                            css={tw`flex flex-col gap-5 px-5 py-5 sm:px-8 sm:py-6 sm:flex-row sm:items-center sm:justify-between`}
                        >
                            <div css={tw`flex items-center gap-4 min-w-0`}>
                                <div
                                    css={tw`w-14 h-14 rounded-lg flex items-center justify-center flex-shrink-0`}
                                    style={{
                                        background: CloudUI.accentMuted,
                                        color: CloudUI.accentHover,
                                        border: '1px solid rgba(16,185,129,0.28)',
                                    }}
                                >
                                    <Icon.Globe size={22} />
                                </div>
                                <div css={tw`min-w-0`}>
                                    <p
                                        css={tw`m-0 text-xs font-semibold uppercase`}
                                        style={{ color: CloudUI.textMuted, letterSpacing: '0.14em' }}
                                    >
                                        Détails du préfixe
                                    </p>
                                    <div css={tw`mt-1.5 flex flex-wrap items-center gap-3`}>
                                        <span
                                            css={tw`font-mono text-xl sm:text-2xl font-bold truncate`}
                                            style={{ color: CloudUI.text }}
                                        >
                                            {label}
                                        </span>
                                        <Badge tone={row.routed ? 'ok' : 'neutral'}>
                                            {row.routed ? 'Routé' : 'Non routé'}
                                        </Badge>
                                    </div>
                                </div>
                            </div>
                            <div css={tw`flex flex-wrap items-center gap-2 flex-shrink-0`}>
                                <GhostButton onClick={onCopy}>
                                    {copied ? <Icon.Check size={14} /> : <Icon.Copy size={14} />}
                                    {copied ? 'Copié' : 'Copier'}
                                </GhostButton>
                                <PrimaryButton onClick={() => history.push('/network/ips')}>
                                    <Icon.ArrowLeft size={14} />
                                    Retour aux IPs
                                </PrimaryButton>
                            </div>
                        </div>
                    </div>

                    <div css={tw`grid grid-cols-1 lg:grid-cols-2 gap-5 mt-5`}>
                        <div style={cardShell}>
                            <div
                                css={tw`flex items-center gap-3 px-5 py-4 border-b`}
                                style={{ borderColor: HMS.cardBorder }}
                            >
                                <span style={sectionIconWrap}>
                                    <Icon.GitBranch size={15} />
                                </span>
                                <h2 css={tw`m-0 text-base font-semibold`} style={{ color: CloudUI.text }}>
                                    Configuration réseau
                                </h2>
                            </div>
                            <dl css={tw`m-0`}>
                                {[
                                    { label: 'Masque', value: label.endsWith('/32') ? '255.255.255.255' : '—' },
                                    { label: 'Passerelle', value: '—' },
                                    { label: 'DNS', value: '—' },
                                    { label: 'Anti-DDOS', value: 'Activé', badge: true },
                                    { label: 'MAC', value: '00:00:00:00:00:00' },
                                ].map((item, idx, arr) => (
                                    <div
                                        key={item.label}
                                        css={tw`flex items-center justify-between gap-4 px-5 py-4`}
                                        style={{
                                            borderBottom:
                                                idx === arr.length - 1 ? 'none' : `1px solid ${HMS.cardBorder}`,
                                        }}
                                    >
                                        <dt css={tw`m-0 text-sm`} style={{ color: CloudUI.textMuted }}>
                                            {item.label}
                                        </dt>
                                        <dd css={tw`m-0`}>
                                            {item.badge ? (
                                                <Badge tone="ok">{item.value}</Badge>
                                            ) : (
                                                <span
                                                    css={tw`font-mono text-sm font-medium`}
                                                    style={{ color: CloudUI.text }}
                                                >
                                                    {item.value}
                                                </span>
                                            )}
                                        </dd>
                                    </div>
                                ))}
                            </dl>
                        </div>

                        <div style={cardShell}>
                            <div
                                css={tw`flex items-center gap-3 px-5 py-4 border-b`}
                                style={{ borderColor: HMS.cardBorder }}
                            >
                                <span style={sectionIconWrap}>
                                    <Icon.Server size={15} />
                                </span>
                                <h2 css={tw`m-0 text-base font-semibold`} style={{ color: CloudUI.text }}>
                                    Statut routage
                                </h2>
                            </div>
                            <div css={tw`px-5 py-5`}>
                                <div css={tw`flex items-start justify-between gap-4`}>
                                    <p css={tw`m-0 text-sm leading-relaxed`} style={{ color: CloudUI.textMuted }}>
                                        {row.routed
                                            ? 'Ce préfixe est actuellement routé vers un service.'
                                            : 'Aucune route active détectée pour ce préfixe.'}
                                    </p>
                                    <Badge tone={row.routed ? 'ok' : 'neutral'}>
                                        {row.routed ? 'Routé' : 'Non routé'}
                                    </Badge>
                                </div>
                                <div
                                    css={tw`mt-5 rounded-lg overflow-hidden`}
                                    style={{ border: `1px solid ${HMS.cardBorder}` }}
                                >
                                    <div
                                        css={tw`flex flex-wrap items-center gap-3 px-4 py-4 border-b`}
                                        style={{ borderColor: HMS.cardBorder }}
                                    >
                                        <div
                                            css={tw`w-10 h-10 rounded-lg flex items-center justify-center flex-shrink-0`}
                                            style={{
                                                background: 'rgba(255,255,255,0.04)',
                                                border: `1px solid ${HMS.cardBorder}`,
                                                color: CloudUI.textMuted,
                                            }}
                                        >
                                            <Icon.Server size={18} />
                                        </div>
                                        <div css={tw`min-w-0 flex-1`}>
                                            <p
                                                css={tw`m-0 text-xs font-semibold uppercase`}
                                                style={{ color: CloudUI.textMuted, letterSpacing: '0.12em' }}
                                            >
                                                Service routé
                                            </p>
                                            <p
                                                css={tw`m-0 mt-0.5 text-base font-semibold truncate`}
                                                style={{ color: CloudUI.text }}
                                            >
                                                {row.service.name}
                                            </p>
                                        </div>
                                        <GhostButton onClick={() => history.push(`/server/${row.service.uuid}`)}>
                                            Ouvrir le service
                                            <Icon.ExternalLink size={13} />
                                        </GhostButton>
                                    </div>
                                    <div css={tw`px-4 py-3`}>
                                        <p css={tw`m-0 text-sm`} style={{ color: CloudUI.textMuted }}>
                                            ID {row.service.uuidShort || row.service.uuid}
                                        </p>
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>

                    <div style={{ ...cardShell, marginTop: 20 }}>
                        <div
                            css={tw`flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between px-5 py-5 border-b`}
                            style={{ borderColor: HMS.cardBorder }}
                        >
                            <div css={tw`flex items-start gap-3`}>
                                <span style={sectionIconWrap}>
                                    <Icon.Type size={15} />
                                </span>
                                <div>
                                    <h2 css={tw`m-0 text-base font-semibold`} style={{ color: CloudUI.text }}>
                                        PTR / Reverse DNS
                                    </h2>
                                    <p css={tw`m-0 mt-1 text-sm`} style={{ color: CloudUI.textMuted }}>
                                        Associez un nom d&apos;hôte (PTR) à chaque IP pour le reverse DNS.
                                    </p>
                                </div>
                            </div>
                            <div css={tw`relative w-full sm:max-w-xs`}>
                                <span
                                    css={tw`absolute left-3 top-1/2`}
                                    style={{
                                        color: CloudUI.textMuted,
                                        transform: 'translateY(-50%)',
                                        pointerEvents: 'none',
                                        display: 'inline-flex',
                                    }}
                                >
                                    <Icon.Search size={14} />
                                </span>
                                <input
                                    value={ptrFilter}
                                    onChange={(e) => setPtrFilter(e.target.value)}
                                    placeholder="Filtrer par IP ou hostname…"
                                    css={tw`w-full rounded-lg pl-9 pr-3 py-2.5 text-sm outline-none`}
                                    style={{
                                        background: HMS.inputBg,
                                        color: CloudUI.text,
                                        border: `1px solid ${HMS.cardBorder}`,
                                    }}
                                />
                            </div>
                        </div>

                        <div
                            css={tw`flex flex-wrap items-center justify-between gap-2 px-5 py-3 border-b`}
                            style={{
                                borderColor: HMS.cardBorder,
                                background: 'rgba(255,255,255,0.02)',
                            }}
                        >
                            <div css={tw`flex gap-2`}>
                                <GhostButton onClick={() => setSelected(true)}>Sélectionner tout</GhostButton>
                                <GhostButton disabled={!selected} onClick={() => setSelected(false)}>
                                    Tout retirer
                                </GhostButton>
                            </div>
                            <GhostButton disabled={!selected} onClick={downloadCsv}>
                                <Icon.Download size={13} />
                                Télécharger (CSV)
                            </GhostButton>
                        </div>

                        <div css={tw`overflow-x-auto`}>
                            <table css={tw`w-full min-w-[720px]`}>
                                <thead>
                                    <tr style={{ borderBottom: `1px solid ${HMS.cardBorder}` }}>
                                        {['', 'IP', 'Zone', 'État PTR', 'Gérer'].map((h, i) => (
                                            <th
                                                key={h || 'cb'}
                                                css={tw`px-5 py-3 text-sm font-semibold`}
                                                style={{
                                                    color: CloudUI.textMuted,
                                                    textAlign: i === 4 ? 'right' : 'left',
                                                    width: i === 0 ? 48 : undefined,
                                                }}
                                            >
                                                {h}
                                            </th>
                                        ))}
                                    </tr>
                                </thead>
                                <tbody>
                                    {ptrVisible ? (
                                        <tr style={{ borderBottom: `1px solid ${HMS.cardBorder}` }}>
                                            <td css={tw`px-5 py-4`}>
                                                <input
                                                    type="checkbox"
                                                    checked={selected}
                                                    onChange={(e) => setSelected(e.target.checked)}
                                                />
                                            </td>
                                            <td css={tw`px-5 py-4`}>
                                                <span
                                                    css={tw`font-mono text-sm`}
                                                    style={{ color: CloudUI.text }}
                                                >
                                                    {ipBare}
                                                </span>
                                            </td>
                                            <td
                                                css={tw`px-5 py-4 font-mono text-xs`}
                                                style={{ color: CloudUI.textMuted }}
                                            >
                                                {zone}
                                            </td>
                                            <td css={tw`px-5 py-4`}>
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
                                            </td>
                                            <td css={tw`px-5 py-4 text-right`}>
                                                <GhostButton onClick={openEdit}>
                                                    <Icon.Edit3 size={13} />
                                                    Modifier
                                                </GhostButton>
                                            </td>
                                        </tr>
                                    ) : (
                                        <tr>
                                            <td
                                                colSpan={5}
                                                css={tw`px-5 py-10 text-center text-sm`}
                                                style={{ color: CloudUI.textMuted }}
                                            >
                                                Aucun PTR à afficher
                                            </td>
                                        </tr>
                                    )}
                                </tbody>
                            </table>
                        </div>
                        <div
                            css={tw`px-5 py-3 text-xs border-t`}
                            style={{ color: CloudUI.textMuted, borderColor: HMS.cardBorder }}
                        >
                            {selected ? '1 ligne(s) sélectionnée(s).' : 'Aucune ligne sélectionnée.'}
                        </div>
                    </div>
                </Fragment>
            ) : null}

            {tab === 'stats' ? (
                <Panel>
                    <h2 css={tw`m-0 text-base font-semibold`} style={{ color: CloudUI.text }}>
                        Statistiques réseau
                    </h2>
                    <p css={tw`m-0 mt-1 text-sm`} style={{ color: CloudUI.textMuted }}>
                        Trafic agrégé pour le préfixe {label}
                    </p>
                    <div css={tw`mt-6`}>
                        <EmptyState
                            icon={<Icon.BarChart2 size={36} />}
                            title="Aucune donnée statistique"
                            description="Aucune série statistique n’est encore disponible pour ce préfixe."
                        />
                    </div>
                </Panel>
            ) : null}

            {tab === 'analysis' ? (
                <Panel>
                    <h2 css={tw`m-0 text-base font-semibold`} style={{ color: CloudUI.text }}>
                        Analyse du trafic
                    </h2>
                    <p css={tw`m-0 mt-1 text-sm`} style={{ color: CloudUI.textMuted }}>
                        Trafic applicatif pour {ipBare}
                    </p>
                    <div css={tw`mt-6`}>
                        <EmptyState
                            icon={<Icon.PieChart size={36} />}
                            title="Aucune donnée sur la période"
                            description="L’analyse détaillée n’est pas encore disponible pour ce préfixe."
                        />
                    </div>
                </Panel>
            ) : null}

            {tab === 'attacks' ? (
                <Panel padded={false}>
                    <div
                        css={tw`flex flex-wrap items-center justify-between gap-3 px-5 py-5 border-b`}
                        style={{ borderColor: HMS.cardBorder }}
                    >
                        <div>
                            <h2 css={tw`m-0 text-base font-semibold`} style={{ color: CloudUI.text }}>
                                Historique des attaques
                            </h2>
                            <p css={tw`m-0 mt-1 text-sm`} style={{ color: CloudUI.textMuted }}>
                                Événements DDoS enregistrés pour {label}
                            </p>
                        </div>
                        <Link
                            to={`/network/ddos?ip=${encodeURIComponent(row.ip)}`}
                            css={tw`text-sm font-semibold no-underline`}
                            style={{ color: CloudUI.accentHover }}
                        >
                            Voir toutes les attaques
                        </Link>
                    </div>
                    {relatedIncidents.length === 0 ? (
                        <EmptyState
                            icon={<Icon.Shield size={36} />}
                            title="Aucune attaque"
                            description="Aucune attaque enregistrée pour cette période."
                        />
                    ) : (
                        <div css={tw`overflow-x-auto`}>
                            <table css={tw`w-full min-w-[720px]`}>
                                <thead>
                                    <tr style={{ borderBottom: `1px solid ${HMS.cardBorder}` }}>
                                        {['Début', 'Fin', 'Type', 'Débit', 'Actions'].map((h, i) => (
                                            <th
                                                key={h}
                                                css={tw`px-5 py-3 text-xs font-semibold uppercase`}
                                                style={{
                                                    color: CloudUI.textMuted,
                                                    letterSpacing: '0.08em',
                                                    textAlign: i === 4 ? 'right' : 'left',
                                                }}
                                            >
                                                {h}
                                            </th>
                                        ))}
                                    </tr>
                                </thead>
                                <tbody>
                                    {relatedIncidents.map((inc) => (
                                        <tr
                                            key={inc.incident_id}
                                            style={{ borderBottom: `1px solid ${HMS.cardBorder}` }}
                                        >
                                            <td css={tw`px-5 py-3.5 text-sm`} style={{ color: CloudUI.textSecondary }}>
                                                {formatWhen(inc.incident_start)}
                                            </td>
                                            <td css={tw`px-5 py-3.5 text-sm`} style={{ color: CloudUI.textSecondary }}>
                                                {inc.incident_stop ? formatWhen(inc.incident_stop) : '—'}
                                            </td>
                                            <td css={tw`px-5 py-3.5`}>
                                                <Badge tone={!inc.incident_stop ? 'danger' : 'warn'}>
                                                    {!inc.incident_stop
                                                        ? 'En cours'
                                                        : inc.attack_type || inc.diversion_reason || 'Attaque'}
                                                </Badge>
                                            </td>
                                            <td css={tw`px-5 py-3.5 text-sm`} style={{ color: CloudUI.textSecondary }}>
                                                {inc.max_bps_formattet || '—'}
                                            </td>
                                            <td css={tw`px-5 py-3.5 text-right`}>
                                                <Link
                                                    to={`/network/ddos?ip=${encodeURIComponent(row.ip)}&incident=${encodeURIComponent(inc.incident_id)}`}
                                                    css={tw`text-sm font-semibold no-underline`}
                                                    style={{ color: CloudUI.accentHover }}
                                                >
                                                    Voir l&apos;attaque
                                                </Link>
                                            </td>
                                        </tr>
                                    ))}
                                </tbody>
                            </table>
                        </div>
                    )}
                </Panel>
            ) : null}

            <HmsModal visible={editOpen} onClose={() => setEditOpen(false)}>
                <div css={tw`p-5 sm:p-8 space-y-5`}>
                    <div>
                        <h3 css={tw`text-xl font-semibold m-0 pr-8`} style={{ color: CloudUI.text }}>
                            Modifier le PTR / Reverse DNS
                        </h3>
                        <p css={tw`text-sm m-0 mt-2`} style={{ color: CloudUI.textMuted }}>
                            Adresse IP{' '}
                            <code style={{ fontFamily: CloudUI.fontMono, color: CloudUI.text }}>{row.ip}</code>
                        </p>
                    </div>
                    <label css={tw`block text-sm`} style={{ color: CloudUI.textSecondary }}>
                        Hostname
                        <input
                            value={hostname}
                            onChange={(e) => setHostname(e.target.value)}
                            placeholder="vps.exemple.com"
                            autoCapitalize="none"
                            autoCorrect="off"
                            spellCheck={false}
                            inputMode="url"
                            css={tw`mt-2 w-full rounded-xl px-4 py-3 outline-none text-base`}
                            style={{
                                background: HMS.inputBg,
                                color: HMS.text,
                                border: `1px solid ${HMS.cardBorder}`,
                                minHeight: 48,
                            }}
                        />
                    </label>
                    <p css={tw`text-sm m-0 leading-relaxed`} style={{ color: CloudUI.textMuted }}>
                        Par défaut : vps-XX.1vps.cc. Laisse vide pour rétablir ce PTR.
                    </p>
                    <div css={tw`flex flex-col-reverse sm:flex-row sm:justify-end gap-2 sm:gap-3 pt-2`}>
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
