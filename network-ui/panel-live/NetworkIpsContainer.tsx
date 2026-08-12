import React, { useEffect, useMemo, useState } from 'react';
import tw from 'twin.macro';
import { Link } from 'react-router-dom';
import useSWR from 'swr';
import * as Icon from 'react-feather';
import useFlash from '@/plugins/useFlash';
import Spinner from '@/components/elements/Spinner';
import NetworkNavTabs from '@/components/network/NetworkNavTabs';
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
    setDdosFilterMode,
    updateNetworkRdns,
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
    PrimaryButton,
    SearchField,
    SegmentedControl,
    StatCard,
    Td,
    Toolbar,
    copyText,
    formatWhen,
} from '@/components/network/NetworkUi';

type IpFilter = 'all' | 'always_on' | 'attacked' | 'dynamic';

export default () => {
    const { clearFlashes, clearAndAddHttpError, addFlash } = useFlash();
    const { data: ips, error, mutate } = useSWR<NetworkIpRow[]>('network-ips', getNetworkIps, {
        revalidateOnFocus: true,
    });
    const { data: modes, mutate: mutateModes } = useSWR<DdosFilterMode[]>('network-ddos-modes', getDdosFilterModes);
    const { data: incidents } = useSWR<DdosIncident[]>('network-ddos-incidents', getDdosIncidents);

    const [q, setQ] = useState('');
    const [ipFilter, setIpFilter] = useState<IpFilter>('all');
    const [editing, setEditing] = useState<NetworkIpRow | null>(null);
    const [hostname, setHostname] = useState('');
    const [saving, setSaving] = useState(false);
    const [copied, setCopied] = useState<string | null>(null);
    const [busyIp, setBusyIp] = useState<string | null>(null);

    useEffect(() => {
        if (error) clearAndAddHttpError({ error });
        else clearFlashes();
    }, [error]);

    const modeByIp = useMemo(() => {
        const map: Record<string, DdosFilterMode> = {};
        (modes || []).forEach((m) => {
            map[m.ip] = m;
        });
        return map;
    }, [modes]);

    const lastAttackByIp = useMemo(() => {
        const map: Record<string, DdosIncident> = {};
        (incidents || []).forEach((inc) => {
            const bare = String(inc.ip || '').split('/')[0];
            const prev = map[bare];
            if (!prev || String(inc.incident_start || '') > String(prev.incident_start || '')) {
                map[bare] = inc;
            }
        });
        return map;
    }, [incidents]);

    const filtered = useMemo(() => {
        let list = ips || [];
        if (ipFilter === 'always_on') list = list.filter((r) => modeByIp[r.ip]?.filter_mode === 'always_on');
        if (ipFilter === 'dynamic') list = list.filter((r) => (modeByIp[r.ip]?.filter_mode || 'dynamic') !== 'always_on');
        if (ipFilter === 'attacked') list = list.filter((r) => !!lastAttackByIp[r.ip]);

        const needle = q.trim().toLowerCase();
        if (!needle) return list;
        return list.filter((row) => {
            const last = lastAttackByIp[row.ip];
            const hay = [
                row.ip,
                row.service.name,
                row.reverse_dns.live || '',
                row.reverse_dns.preferred || '',
                modeByIp[row.ip]?.filter_mode || '',
                last?.attack_type || '',
            ]
                .join(' ')
                .toLowerCase();
            return hay.includes(needle);
        });
    }, [ips, q, modeByIp, lastAttackByIp, ipFilter]);

    const stats = useMemo(() => {
        const list = ips || [];
        const vms = new Set(list.map((r) => r.service.uuid)).size;
        const withPtr = list.filter((r) => r.reverse_dns.live || r.reverse_dns.preferred).length;
        const alwaysOn = list.filter((r) => modeByIp[r.ip]?.filter_mode === 'always_on').length;
        const hit = list.filter((r) => !!lastAttackByIp[r.ip]).length;
        return { total: list.length, vms, withPtr, alwaysOn, hit };
    }, [ips, modeByIp, lastAttackByIp]);

    if (!ips) {
        return (
            <div css={tw`py-32 flex justify-center`}>
                <Spinner size="large" />
            </div>
        );
    }

    const openEdit = (row: NetworkIpRow) => {
        setEditing(row);
        setHostname(row.reverse_dns.preferred || row.reverse_dns.live || '');
    };

    const saveRdns = async () => {
        if (!editing) return;
        setSaving(true);
        try {
            await updateNetworkRdns(editing.ip, hostname.trim() || null);
            await mutate();
            setEditing(null);
            addFlash({ key: 'network:ips', type: 'success', message: 'Reverse DNS enregistré.' });
        } catch (e) {
            clearAndAddHttpError({ key: 'network:ips', error: e });
        } finally {
            setSaving(false);
        }
    };

    const onCopy = async (ip: string) => {
        const ok = await copyText(ip);
        if (ok) {
            setCopied(ip);
            window.setTimeout(() => setCopied((c) => (c === ip ? null : c)), 1200);
        }
    };

    const toggleMode = async (ip: string, current?: string) => {
        const next = current === 'always_on' ? 'dynamic' : 'always_on';
        if (modeByIp[ip]?.filter_mode_locked) return;
        setBusyIp(ip);
        try {
            await setDdosFilterMode(ip, next);
            await mutateModes();
            addFlash({ key: 'network:ips', type: 'success', message: `${ip} → ${next}` });
        } catch (e) {
            clearAndAddHttpError({ key: 'network:ips', error: e });
        } finally {
            setBusyIp(null);
        }
    };

    const filterOptions: { id: IpFilter; label: string }[] = [
        { id: 'all', label: 'Toutes' },
        { id: 'dynamic', label: 'Dynamic' },
        { id: 'always_on', label: 'Always-on' },
        { id: 'attacked', label: 'Attaquées' },
    ];

    return (
        <NetworkPage>
            <NetworkHeader
                icon={Icon.Globe}
                title="Adresse IP"
                subtitle="Gérez vos IPs dédiées LumenVM : reverse DNS, protection DDoS et rattachement aux VPS."
            />

            <NetworkNavTabs active="ips" />

            <div css={tw`grid grid-cols-2 xl:grid-cols-4 gap-2 sm:gap-4`}>
                <StatCard label="IPs dédiées" value={stats.total} hint={`${stats.vms} VPS rattachés`} icon={<Icon.Globe size={18} />} />
                <StatCard
                    label="Reverse DNS"
                    value={stats.withPtr}
                    hint={stats.total ? `${Math.round((stats.withPtr / stats.total) * 100)} % configurés` : '—'}
                    icon={<Icon.Type size={18} />}
                    tone="ok"
                />
                <StatCard
                    label="Always-on"
                    value={stats.alwaysOn}
                    hint="Filtre DDoS permanent"
                    icon={<Icon.Shield size={18} />}
                    tone={stats.alwaysOn ? 'warn' : 'default'}
                />
                <StatCard
                    label="Déjà attaquées"
                    value={stats.hit}
                    hint="Historique Packets Decreaser"
                    icon={<Icon.Activity size={18} />}
                    tone={stats.hit ? 'danger' : 'ok'}
                />
            </div>

            <Panel padded={false}>
                <div css={tw`px-4 sm:px-6 lg:px-8 pt-4 sm:pt-6 lg:pt-8 pb-4 sm:pb-5`}>
                    <Toolbar>
                        <div css={tw`flex flex-col gap-3 min-w-0 flex-1 w-full`}>
                            <SearchField value={q} onChange={setQ} placeholder="IP, VPS ou PTR…" />
                            <SegmentedControl value={ipFilter} onChange={setIpFilter} options={filterOptions} />
                        </div>
                        <p
                            css={tw`text-xs sm:text-sm m-0 flex-shrink-0 text-center sm:text-left`}
                            style={{ color: CloudUI.textMuted }}
                        >
                            {filtered.length} résultat{filtered.length > 1 ? 's' : ''}
                        </p>
                    </Toolbar>
                </div>

                {filtered.length === 0 ? (
                    <EmptyState
                        icon={<Icon.Globe size={36} />}
                        title="Aucune IP trouvée"
                        description="Assigne une IP dédiée depuis l’onglet Réseau d’un VPS LumenVM."
                    />
                ) : (
                    <>
                        <DataTable
                            headers={[
                                { key: 'ip', label: 'Adresse IP', width: '18%' },
                                { key: 'service', label: 'Instance', width: '14%' },
                                { key: 'ptr', label: 'Reverse DNS', width: '20%' },
                                { key: 'mode', label: 'Protection', width: '12%' },
                                { key: 'attack', label: 'Attaque', width: '14%' },
                                { key: 'actions', label: 'Actions', width: '22%', align: 'right' },
                            ]}
                        >
                            {filtered.map((row) => {
                                const mode = modeByIp[row.ip]?.filter_mode || 'dynamic';
                                const locked = !!modeByIp[row.ip]?.filter_mode_locked;
                                const last = lastAttackByIp[row.ip];
                                const ptr = row.reverse_dns.preferred || row.reverse_dns.live;
                                const ddosLink = last
                                    ? `/network/ddos?ip=${encodeURIComponent(row.ip)}&incident=${encodeURIComponent(last.incident_id)}`
                                    : `/network/ddos?ip=${encodeURIComponent(row.ip)}`;

                                return (
                                    <tr key={row.ip}>
                                        <Td>
                                            <div css={tw`flex items-center gap-1.5 min-w-0`}>
                                                <span css={tw`min-w-0 truncate`}>
                                                    <MonoIp>{row.ip}</MonoIp>
                                                </span>
                                                <button
                                                    type="button"
                                                    title={copied === row.ip ? 'Copié' : 'Copier'}
                                                    aria-label="Copier l’IP"
                                                    onClick={() => onCopy(row.ip)}
                                                    css={tw`inline-flex items-center justify-center rounded-md border-0 cursor-pointer flex-shrink-0`}
                                                    style={{
                                                        background: 'rgba(255,255,255,0.04)',
                                                        color: CloudUI.textMuted,
                                                        border: `1px solid ${HMS.cardBorder}`,
                                                        width: 28,
                                                        height: 28,
                                                    }}
                                                >
                                                    {copied === row.ip ? <Icon.Check size={12} /> : <Icon.Copy size={12} />}
                                                </button>
                                            </div>
                                            {row.service.is_primary ? (
                                                <div css={tw`mt-1`}>
                                                    <Badge tone="accent">IP primaire</Badge>
                                                </div>
                                            ) : null}
                                        </Td>
                                        <Td>
                                            <Link
                                                to={`/server/${row.service.uuid}`}
                                                css={tw`no-underline text-sm font-medium`}
                                                style={{ color: CloudUI.accentHover }}
                                            >
                                                {row.service.name}
                                            </Link>
                                            <MetaLine>{row.routed ? 'Routée vers le VPS' : 'Non routée'}</MetaLine>
                                        </Td>
                                        <Td>
                                            <p
                                                css={tw`m-0 text-sm font-mono truncate`}
                                                title={ptr || 'Non défini'}
                                                style={{ color: ptr ? CloudUI.text : CloudUI.textMuted }}
                                            >
                                                {ptr || 'Non défini'}
                                            </p>
                                        </Td>
                                        <Td>
                                            <Badge tone={mode === 'always_on' ? 'warn' : 'neutral'}>
                                                {mode === 'always_on' ? 'Always-on' : 'Dynamic'}
                                            </Badge>
                                            {locked ? (
                                                <div css={tw`mt-1`}>
                                                    <Badge tone="danger">Verrouillé</Badge>
                                                </div>
                                            ) : null}
                                        </Td>
                                        <Td>
                                            {last ? (
                                                <>
                                                    <Badge tone={!last.incident_stop ? 'danger' : 'warn'}>
                                                        {!last.incident_stop
                                                            ? 'En cours'
                                                            : last.attack_type || last.diversion_reason || 'Attaque'}
                                                    </Badge>
                                                    <MetaLine>
                                                        {formatWhen(last.incident_start)}
                                                        {last.max_bps_formattet ? ` · ${last.max_bps_formattet}` : ''}
                                                    </MetaLine>
                                                </>
                                            ) : (
                                                <span css={tw`text-sm`} style={{ color: CloudUI.textMuted }}>
                                                    Aucune
                                                </span>
                                            )}
                                        </Td>
                                        <Td align="right">
                                            <Link
                                                to={`/network/ips/${encodeURIComponent(row.ip)}`}
                                                css={tw`inline-flex items-center justify-center px-2.5 py-1.5 rounded-lg text-xs font-semibold no-underline whitespace-nowrap max-w-full`}
                                                style={{
                                                    background: CloudUI.accent,
                                                    color: '#fff',
                                                    minHeight: 34,
                                                }}
                                            >
                                                Gérer ce préfixe
                                            </Link>
                                        </Td>
                                    </tr>
                                );
                            })}
                        </DataTable>

                        <div css={tw`lg:hidden px-3 sm:px-4 pb-4 space-y-3`}>
                            {filtered.map((row) => {
                                const mode = modeByIp[row.ip]?.filter_mode || 'dynamic';
                                const locked = !!modeByIp[row.ip]?.filter_mode_locked;
                                const last = lastAttackByIp[row.ip];
                                const ptr = row.reverse_dns.preferred || row.reverse_dns.live;
                                const ddosLink = last
                                    ? `/network/ddos?ip=${encodeURIComponent(row.ip)}&incident=${encodeURIComponent(last.incident_id)}`
                                    : `/network/ddos?ip=${encodeURIComponent(row.ip)}`;

                                return (
                                    <MobileCard key={row.ip}>
                                        <div css={tw`flex items-start justify-between gap-3`}>
                                            <div css={tw`min-w-0 flex-1`}>
                                                <div css={tw`flex items-center gap-2 flex-wrap`}>
                                                    <MonoIp>{row.ip}</MonoIp>
                                                    <button
                                                        type="button"
                                                        aria-label="Copier l’IP"
                                                        onClick={() => onCopy(row.ip)}
                                                        css={tw`inline-flex items-center justify-center rounded-md border-0 cursor-pointer flex-shrink-0`}
                                                        style={{
                                                            background: 'rgba(255,255,255,0.04)',
                                                            color: CloudUI.textMuted,
                                                            border: `1px solid ${HMS.cardBorder}`,
                                                            width: 36,
                                                            height: 36,
                                                        }}
                                                    >
                                                        {copied === row.ip ? <Icon.Check size={14} /> : <Icon.Copy size={14} />}
                                                    </button>
                                                </div>
                                                <Link
                                                    to={`/server/${row.service.uuid}`}
                                                    css={tw`inline-flex items-center gap-1 text-sm no-underline mt-2 font-medium`}
                                                    style={{ color: CloudUI.accentHover }}
                                                >
                                                    {row.service.name}
                                                    <Icon.ChevronRight size={14} />
                                                </Link>
                                            </div>
                                            <Badge tone={mode === 'always_on' ? 'warn' : 'neutral'}>
                                                {mode === 'always_on' ? 'Always-on' : 'Dynamic'}
                                            </Badge>
                                        </div>

                                        {(row.service.is_primary || locked || !row.routed) && (
                                            <div css={tw`flex flex-wrap gap-2`}>
                                                {row.service.is_primary ? <Badge tone="accent">IP primaire</Badge> : null}
                                                {locked ? <Badge tone="danger">Verrouillé</Badge> : null}
                                                {!row.routed ? <Badge tone="neutral">Non routée</Badge> : null}
                                            </div>
                                        )}

                                        <MobileMetaGrid
                                            items={[
                                                {
                                                    label: 'Reverse DNS',
                                                    value: (
                                                        <span
                                                            css={tw`font-mono text-xs break-all`}
                                                            style={{ color: ptr ? CloudUI.text : CloudUI.textMuted }}
                                                        >
                                                            {ptr || 'Non défini'}
                                                        </span>
                                                    ),
                                                },
                                                {
                                                    label: 'Attaque',
                                                    value: last ? (
                                                        <span>
                                                            {!last.incident_stop ? (
                                                                <span style={{ color: CloudUI.danger }}>En cours · </span>
                                                            ) : null}
                                                            {formatWhen(last.incident_start)}
                                                            {last.max_bps_formattet ? (
                                                                <span css={tw`block mt-1`} style={{ color: CloudUI.textMuted }}>
                                                                    {last.max_bps_formattet}
                                                                </span>
                                                            ) : null}
                                                        </span>
                                                    ) : (
                                                        'Aucune'
                                                    ),
                                                },
                                            ]}
                                        />

                                        <Link
                                            to={`/network/ips/${encodeURIComponent(row.ip)}`}
                                            css={tw`w-full inline-flex items-center justify-center gap-2 px-3 py-2.5 rounded-lg text-sm font-medium no-underline`}
                                            style={{
                                                background: CloudUI.accent,
                                                color: '#fff',
                                                minHeight: 44,
                                            }}
                                        >
                                            Gérer ce préfixe
                                        </Link>
                                    </MobileCard>
                                );
                            })}
                        </div>
                    </>
                )}
            </Panel>

            <HmsModal visible={!!editing} onClose={() => setEditing(null)}>
                {editing ? (
                    <div css={tw`p-5 sm:p-8 space-y-5`}>
                        <div>
                            <h3 css={tw`text-xl font-semibold m-0 pr-8`} style={{ color: CloudUI.text }}>
                                Reverse DNS
                            </h3>
                            <p css={tw`text-sm m-0 mt-2`} style={{ color: CloudUI.textMuted }}>
                                Adresse IP{' '}
                                <code style={{ fontFamily: CloudUI.fontMono, color: CloudUI.text }}>{editing.ip}</code>
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
                            <GhostButton onClick={() => setEditing(null)}>Annuler</GhostButton>
                            <PrimaryButton onClick={saveRdns} disabled={saving}>
                                {saving ? 'Enregistrement…' : 'Enregistrer'}
                            </PrimaryButton>
                        </div>
                    </div>
                ) : null}
            </HmsModal>
        </NetworkPage>
    );
};
