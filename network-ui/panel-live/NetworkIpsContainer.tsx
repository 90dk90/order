import React, { useEffect, useMemo, useState } from 'react';
import tw from 'twin.macro';
import { Link } from 'react-router-dom';
import useSWR from 'swr';
import * as Icon from 'react-feather';
import useFlash from '@/plugins/useFlash';
import Spinner from '@/components/elements/Spinner';
import NetworkNavTabs from '@/components/network/NetworkNavTabs';
import { HMS } from '@/components/hms/hmsTheme';
import { CloudUI } from '@/components/hms/cloudUi';
import {
    DdosFilterMode,
    DdosIncident,
    getDdosFilterModes,
    getDdosIncidents,
    getNetworkIps,
    NetworkIpRow,
} from '@/api/network';
import {
    Badge,
    DataTable,
    EmptyState,
    GhostLink,
    MetaLine,
    MobileCard,
    MobileMetaGrid,
    MonoIp,
    NetworkHeader,
    NetworkPage,
    Panel,
    SearchField,
    SegmentedControl,
    Td,
    copyText,
    formatWhen,
} from '@/components/network/NetworkUi';

type IpFilter = 'all' | 'always_on' | 'attacked' | 'dynamic';

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
            <p
                css={tw`m-0 mt-1 text-2xl font-semibold tabular-nums tracking-tight`}
                style={{ color }}
            >
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
    size = 28,
}: {
    value: string;
    copied: boolean;
    onCopy: (v: string) => void;
    size?: number;
}) => (
    <button
        type="button"
        title={copied ? 'Copié' : 'Copier'}
        aria-label="Copier l’IP"
        onClick={() => onCopy(value)}
        css={tw`inline-flex items-center justify-center rounded-md border-0 cursor-pointer flex-shrink-0 transition-colors`}
        style={{
            background: copied ? CloudUI.accentMuted : 'rgba(255,255,255,0.03)',
            color: copied ? CloudUI.accentHover : CloudUI.textMuted,
            border: `1px solid ${copied ? 'rgba(16,185,129,0.3)' : HMS.cardBorder}`,
            width: size,
            height: size,
        }}
    >
        {copied ? <Icon.Check size={12} /> : <Icon.Copy size={12} />}
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

export default () => {
    const { clearFlashes, clearAndAddHttpError } = useFlash();
    const { data: ips, error } = useSWR<NetworkIpRow[]>('network-ips', getNetworkIps, {
        revalidateOnFocus: true,
    });
    const { data: modes } = useSWR<DdosFilterMode[]>('network-ddos-modes', getDdosFilterModes);
    const { data: incidents } = useSWR<DdosIncident[]>('network-ddos-incidents', getDdosIncidents);

    const [q, setQ] = useState('');
    const [ipFilter, setIpFilter] = useState<IpFilter>('all');
    const [copied, setCopied] = useState<string | null>(null);

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

    const onCopy = async (ip: string) => {
        const ok = await copyText(ip);
        if (ok) {
            setCopied(ip);
            window.setTimeout(() => setCopied((c) => (c === ip ? null : c)), 1200);
        }
    };

    if (!ips) {
        return (
            <div css={tw`py-32 flex justify-center`}>
                <Spinner size="large" />
            </div>
        );
    }

    const filterOptions: { id: IpFilter; label: string }[] = [
        { id: 'all', label: 'Toutes' },
        { id: 'dynamic', label: 'Dynamic' },
        { id: 'always_on', label: 'Always-on' },
        { id: 'attacked', label: 'Attaquées' },
    ];

    return (
        <NetworkPage>
            <div
                css={tw`flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between`}
            >
                <NetworkHeader
                    icon={Icon.Globe}
                    title="Adresses IP"
                    subtitle="Préfixes dédiés, reverse DNS et protection DDoS rattachés à vos instances."
                />
                <p
                    css={tw`m-0 text-sm sm:text-right flex-shrink-0`}
                    style={{ color: CloudUI.textMuted }}
                >
                    <span css={tw`font-semibold`} style={{ color: CloudUI.text }}>
                        {filtered.length}
                    </span>{' '}
                    affichée{filtered.length > 1 ? 's' : ''}
                    {filtered.length !== stats.total ? ` / ${stats.total}` : ''}
                </p>
            </div>

            <NetworkNavTabs active="ips" />

            {/* Metrics strip — cloud-console density */}
            <div
                css={tw`rounded-xl px-4 sm:px-6 py-4 grid grid-cols-2 lg:grid-cols-4 gap-4 sm:gap-6`}
                style={{
                    background: CloudUI.surface,
                    border: `1px solid ${HMS.cardBorder}`,
                }}
            >
                <Metric label="Préfixes" value={stats.total} hint={`${stats.vms} instance${stats.vms > 1 ? 's' : ''}`} />
                <Metric
                    label="Reverse DNS"
                    value={stats.withPtr}
                    hint={stats.total ? `${Math.round((stats.withPtr / stats.total) * 100)} % configurés` : '—'}
                    tone="ok"
                />
                <Metric
                    label="Always-on"
                    value={stats.alwaysOn}
                    hint="Mitigation permanente"
                    tone={stats.alwaysOn ? 'warn' : 'default'}
                />
                <Metric
                    label="Attaquées"
                    value={stats.hit}
                    hint="Historique DDoS"
                    tone={stats.hit ? 'danger' : 'ok'}
                />
            </div>

            <Panel padded={false}>
                <div
                    css={tw`px-4 sm:px-6 py-4 sm:py-5 flex flex-col xl:flex-row xl:items-center gap-3 xl:gap-4`}
                    style={{ borderBottom: `1px solid ${HMS.cardBorder}` }}
                >
                    <div css={tw`flex-1 min-w-0 xl:max-w-md`}>
                        <SearchField value={q} onChange={setQ} placeholder="Rechercher une IP, un VPS ou un PTR…" />
                    </div>
                    <div css={tw`xl:flex-1 min-w-0`}>
                        <SegmentedControl value={ipFilter} onChange={setIpFilter} options={filterOptions} />
                    </div>
                </div>

                {filtered.length === 0 ? (
                    <EmptyState
                        icon={<Icon.Globe size={36} />}
                        title="Aucune adresse IP"
                        description={
                            q || ipFilter !== 'all'
                                ? 'Aucun résultat pour ces filtres. Modifiez la recherche ou réinitialisez les filtres.'
                                : 'Assignez une IP dédiée depuis l’onglet Réseau d’une instance LumenVM.'
                        }
                    />
                ) : (
                    <>
                        <DataTable
                            headers={[
                                { key: 'ip', label: 'Adresse IP', width: '24%' },
                                { key: 'service', label: 'Instance', width: '18%' },
                                { key: 'ptr', label: 'Reverse DNS', width: '24%' },
                                { key: 'mode', label: 'Protection', width: '14%' },
                                { key: 'attack', label: 'DDoS', width: '12%' },
                                { key: 'actions', label: '', width: '8%', align: 'right' },
                            ]}
                        >
                            {filtered.map((row) => {
                                const mode = modeByIp[row.ip]?.filter_mode || 'dynamic';
                                const locked = !!modeByIp[row.ip]?.filter_mode_locked;
                                const last = lastAttackByIp[row.ip];
                                const ptr = row.reverse_dns.preferred || row.reverse_dns.live;
                                const manageTo = `/network/ips/${encodeURIComponent(row.ip)}`;

                                return (
                                    <HoverRow key={row.ip}>
                                        <Td>
                                            <div css={tw`flex items-center gap-2.5 min-w-0`}>
                                                <Link
                                                    to={manageTo}
                                                    css={tw`no-underline min-w-0 truncate`}
                                                    title={row.ip}
                                                >
                                                    <MonoIp>{row.ip}</MonoIp>
                                                </Link>
                                                <CopyIconButton
                                                    value={row.ip}
                                                    copied={copied === row.ip}
                                                    onCopy={onCopy}
                                                />
                                            </div>
                                            <div css={tw`mt-1.5 flex flex-wrap items-center gap-1.5`}>
                                                {row.service.is_primary ? (
                                                    <Badge tone="accent">Primaire</Badge>
                                                ) : null}
                                                {!row.routed ? <Badge tone="neutral">Non routée</Badge> : null}
                                            </div>
                                        </Td>
                                        <Td>
                                            <Link
                                                to={`/server/${row.service.uuid}`}
                                                css={tw`no-underline text-sm font-medium block truncate`}
                                                style={{ color: CloudUI.text }}
                                                title={row.service.name}
                                            >
                                                {row.service.name}
                                            </Link>
                                            <MetaLine>
                                                {row.routed ? 'Routée vers l’instance' : 'Sans route active'}
                                            </MetaLine>
                                        </Td>
                                        <Td>
                                            <p
                                                css={tw`m-0 text-sm font-mono truncate`}
                                                title={ptr || undefined}
                                                style={{
                                                    color: ptr ? CloudUI.textSecondary : CloudUI.textMuted,
                                                }}
                                            >
                                                {ptr || '—'}
                                            </p>
                                        </Td>
                                        <Td>
                                            <StatusDot
                                                tone={mode === 'always_on' ? 'warn' : 'ok'}
                                                label={mode === 'always_on' ? 'Always-on' : 'Dynamic'}
                                            />
                                            {locked ? (
                                                <div css={tw`mt-1`}>
                                                    <Badge tone="danger">Verrouillé</Badge>
                                                </div>
                                            ) : null}
                                        </Td>
                                        <Td>
                                            {last ? (
                                                <div>
                                                    <StatusDot
                                                        tone={!last.incident_stop ? 'danger' : 'warn'}
                                                        label={!last.incident_stop ? 'En cours' : 'Historique'}
                                                    />
                                                    <MetaLine>{formatWhen(last.incident_start)}</MetaLine>
                                                </div>
                                            ) : (
                                                <span css={tw`text-sm`} style={{ color: CloudUI.textMuted }}>
                                                    —
                                                </span>
                                            )}
                                        </Td>
                                        <Td align="right">
                                            <div css={tw`flex justify-end`}>
                                                <GhostLink compact to={manageTo} title="Gérer ce préfixe">
                                                    Gérer
                                                    <Icon.ChevronRight size={13} />
                                                </GhostLink>
                                            </div>
                                        </Td>
                                    </HoverRow>
                                );
                            })}
                        </DataTable>

                        <div css={tw`lg:hidden px-3 sm:px-4 pb-4 space-y-3`}>
                            {filtered.map((row) => {
                                const mode = modeByIp[row.ip]?.filter_mode || 'dynamic';
                                const locked = !!modeByIp[row.ip]?.filter_mode_locked;
                                const last = lastAttackByIp[row.ip];
                                const ptr = row.reverse_dns.preferred || row.reverse_dns.live;
                                const manageTo = `/network/ips/${encodeURIComponent(row.ip)}`;

                                return (
                                    <MobileCard key={row.ip}>
                                        <div css={tw`flex items-start justify-between gap-3`}>
                                            <div css={tw`min-w-0 flex-1`}>
                                                <div css={tw`flex items-center gap-2`}>
                                                    <MonoIp>{row.ip}</MonoIp>
                                                    <CopyIconButton
                                                        value={row.ip}
                                                        copied={copied === row.ip}
                                                        onCopy={onCopy}
                                                        size={32}
                                                    />
                                                </div>
                                                <Link
                                                    to={`/server/${row.service.uuid}`}
                                                    css={tw`inline-flex items-center gap-1 text-sm no-underline mt-2 font-medium`}
                                                    style={{ color: CloudUI.text }}
                                                >
                                                    {row.service.name}
                                                    <Icon.ChevronRight size={14} />
                                                </Link>
                                            </div>
                                            <StatusDot
                                                tone={mode === 'always_on' ? 'warn' : 'ok'}
                                                label={mode === 'always_on' ? 'Always-on' : 'Dynamic'}
                                            />
                                        </div>

                                        {(row.service.is_primary || locked || !row.routed) && (
                                            <div css={tw`flex flex-wrap gap-2`}>
                                                {row.service.is_primary ? (
                                                    <Badge tone="accent">Primaire</Badge>
                                                ) : null}
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
                                                            style={{
                                                                color: ptr ? CloudUI.text : CloudUI.textMuted,
                                                            }}
                                                        >
                                                            {ptr || '—'}
                                                        </span>
                                                    ),
                                                },
                                                {
                                                    label: 'DDoS',
                                                    value: last ? (
                                                        <span>
                                                            {!last.incident_stop ? (
                                                                <span style={{ color: CloudUI.danger }}>
                                                                    En cours ·{' '}
                                                                </span>
                                                            ) : null}
                                                            {formatWhen(last.incident_start)}
                                                        </span>
                                                    ) : (
                                                        '—'
                                                    ),
                                                },
                                            ]}
                                        />

                                        <GhostLink fullWidth to={manageTo} title="Gérer ce préfixe">
                                            Gérer ce préfixe
                                            <Icon.ChevronRight size={14} />
                                        </GhostLink>
                                    </MobileCard>
                                );
                            })}
                        </div>
                    </>
                )}
            </Panel>
        </NetworkPage>
    );
};
