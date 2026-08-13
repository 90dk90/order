import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { NavLink, useHistory, useParams, useRouteMatch } from 'react-router-dom';
import tw from 'twin.macro';
import { FontAwesomeIcon } from '@fortawesome/react-fontawesome';
import {
    faArrowLeft,
    faCopy,
    faEllipsisH,
    faEye,
    faGlobe,
    faNetworkWired,
    faSearch,
    faShieldAlt,
    faSyncAlt,
} from '@fortawesome/free-solid-svg-icons';
import * as Icon from 'react-feather';
import styled from 'styled-components/macro';
import PageContentBlock from '@/components/elements/PageContentBlock';
import Spinner from '@/components/elements/Spinner';
import { Alert } from '@/components/elements/alert';
import { getNetworkIps, getDdosIncidents, NetworkIpRow, DdosIncident } from '@/api/network';
import { CloudUI } from '@/components/hms/cloudUi';
import {
    NetworkPage,
    NetworkHeader,
    Panel,
    PanelHeader,
    StatCard,
    Badge,
    GhostButton,
    GhostLink,
    PrimaryButton,
    SegmentedControl,
    SearchField,
    Toolbar,
    MobileCard,
    MobileMetaGrid,
    ActionsMenu,
    DataTable,
    Td,
    MonoIp,
    MetaLine,
    EmptyState,
    formatWhen,
    durationMin,
    severityOfBps,
    copyText,
} from '@/components/network/NetworkUi';
import NetworkIpStatsTab from '@/components/network/NetworkIpStatsTab';
import NetworkIpAnalysisTab from '@/components/network/NetworkIpAnalysisTab';

type TabKey = 'general' | 'stats' | 'analysis' | 'attacks';

const TabBar = styled.div`
    ${tw`flex flex-wrap gap-2 border-b mb-6`};
    border-color: ${CloudUI.border};
`;

const TabLink = styled(NavLink)`
    ${tw`inline-flex items-center gap-2 px-4 py-3 text-sm font-semibold border-b-2 border-transparent transition-colors`};
    color: ${CloudUI.textMuted};
    margin-bottom: -1px;

    &:hover {
        color: ${CloudUI.text};
        border-color: ${CloudUI.borderSubtle};
    }
`;

const tabActiveStyle: React.CSSProperties = {
    color: CloudUI.accent,
    borderBottomColor: CloudUI.accent,
};

const Field = styled.div`
    ${tw`rounded-lg border p-4`};
    background: ${CloudUI.surface};
    border-color: ${CloudUI.border};
`;

const FieldLabel = styled.div`
    ${tw`text-xs font-semibold uppercase tracking-wide mb-1`};
    color: ${CloudUI.textMuted};
`;

const FieldValue = styled.div`
    ${tw`text-sm font-medium break-all`};
    color: ${CloudUI.text};
    font-family: ${CloudUI.font};
`;

const Grid2 = styled.div`
    ${tw`grid gap-4`};
    grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
`;

const Grid3 = styled.div`
    ${tw`grid gap-4 mb-6`};
    grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
`;

function cidrLabel(ip: string): string {
    return ip.includes('/') ? ip : `${ip}/32`;
}

function severityTone(bps: number | null | undefined): 'danger' | 'ok' | 'warn' {
    const s = severityOfBps(bps ?? undefined);
    if (s === 'danger') return 'danger';
    if (s === 'warn') return 'warn';
    return 'ok';
}

function severityColor(bps: number | null | undefined): string {
    const t = severityTone(bps);
    if (t === 'danger') return CloudUI.danger;
    if (t === 'warn') return CloudUI.warning;
    return CloudUI.success;
}

function isActiveIncident(i: DdosIncident): boolean {
    return !i.incident_stop;
}

export default () => {
    const history = useHistory();
    const match = useRouteMatch();
    const { ipId } = useParams<{ ipId: string }>();
    const decoded = decodeURIComponent(ipId || '');

    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);
    const [row, setRow] = useState<NetworkIpRow | null>(null);

    const [attacksLoading, setAttacksLoading] = useState(false);
    const [attacksError, setAttacksError] = useState<string | null>(null);
    const [attacks, setAttacks] = useState<DdosIncident[]>([]);
    const [attackFilter, setAttackFilter] = useState<'all' | 'active'>('all');
    const [attackQuery, setAttackQuery] = useState('');
    const [copied, setCopied] = useState(false);

    const base = match.url.replace(/\/(stats|analysis|attacks)$/, '');
    const tab: TabKey = match.url.endsWith('/stats')
        ? 'stats'
        : match.url.endsWith('/analysis')
          ? 'analysis'
          : match.url.endsWith('/attacks')
            ? 'attacks'
            : 'general';

    const prefix = useMemo(() => (row ? cidrLabel(row.ip) : cidrLabel(decoded)), [row, decoded]);

    const loadRow = useCallback(async () => {
        setLoading(true);
        setError(null);
        try {
            const rows = await getNetworkIps();
            const found =
                rows.find((r) => r.ip === decoded) ||
                rows.find((r) => r.ip.split('/')[0] === decoded.split('/')[0]) ||
                null;
            setRow(found);
            if (!found) setError('Adresse IP introuvable.');
        } catch (e: any) {
            setError(e?.message || 'Impossible de charger cette adresse IP.');
            setRow(null);
        } finally {
            setLoading(false);
        }
    }, [decoded]);

    const loadAttacks = useCallback(async () => {
        if (!row) return;
        setAttacksLoading(true);
        setAttacksError(null);
        try {
            const list = await getDdosIncidents();
            const ipBare = row.ip.split('/')[0];
            setAttacks(list.filter((i) => i.ip === row.ip || i.ip === ipBare || i.ip?.startsWith(`${ipBare}/`)));
        } catch (e: any) {
            setAttacksError(e?.message || 'Impossible de récupérer les attaques.');
            setAttacks([]);
        } finally {
            setAttacksLoading(false);
        }
    }, [row]);

    useEffect(() => {
        loadRow();
    }, [loadRow]);

    useEffect(() => {
        if (tab === 'attacks' && row) loadAttacks();
    }, [tab, row, loadAttacks]);

    const activeCount = useMemo(() => attacks.filter(isActiveIncident).length, [attacks]);
    const peakBps = useMemo(
        () => attacks.reduce((m, i) => Math.max(m, Number(i.max_bps) || 0), 0),
        [attacks]
    );

    const filteredAttacks = useMemo(() => {
        const q = attackQuery.trim().toLowerCase();
        return attacks.filter((i) => {
            if (attackFilter === 'active' && !isActiveIncident(i)) return false;
            if (!q) return true;
            const hay = [
                String(i.incident_id || ''),
                i.ip || '',
                i.attack_type || '',
                i.protocol || '',
                i.diversion_reason || '',
                i.incident_start || '',
                i.incident_stop || '',
            ]
                .join(' ')
                .toLowerCase();
            return hay.includes(q);
        });
    }, [attacks, attackFilter, attackQuery]);

    const onCopy = async () => {
        if (!row) return;
        const ok = await copyText(row.ip);
        if (ok) {
            setCopied(true);
            window.setTimeout(() => setCopied(false), 1500);
        }
    };

    if (loading) {
        return (
            <PageContentBlock title={prefix}>
                <div css={tw`flex justify-center py-20`}>
                    <Spinner size={'large'} centered />
                </div>
            </PageContentBlock>
        );
    }

    if (error || !row) {
        return (
            <PageContentBlock title={prefix}>
                <NetworkPage>
                    <Alert type={'danger'}>{error || 'Adresse IP introuvable.'}</Alert>
                    <div css={tw`mt-4`}>
                        <GhostLink to={'/network/ips'}>
                            <FontAwesomeIcon icon={faArrowLeft} /> Retour aux IPs
                        </GhostLink>
                    </div>
                </NetworkPage>
            </PageContentBlock>
        );
    }

    const reverse = row.reverse_dns?.preferred || row.reverse_dns?.live || '—';

    return (
        <PageContentBlock title={prefix} description={'Gérez votre préfixe IP, configurez le reverse DNS et visualisez les statistiques.'}>
            <NetworkPage>
                <div css={tw`mb-4`}>
                    <GhostLink to={'/network/ips'}>
                        <FontAwesomeIcon icon={faArrowLeft} /> Retour aux IPs
                    </GhostLink>
                </div>

                <NetworkHeader
                    icon={Icon.Globe}
                    title={prefix}
                    subtitle={'Gérez votre préfixe IP, configurez le reverse DNS et visualisez les statistiques.'}
                />

                <TabBar>
                    <TabLink to={base} exact style={tab === 'general' ? tabActiveStyle : undefined} activeStyle={tabActiveStyle}>
                        Informations générales
                    </TabLink>
                    <TabLink to={`${base}/stats`} style={tab === 'stats' ? tabActiveStyle : undefined} activeStyle={tabActiveStyle}>
                        Statistiques
                    </TabLink>
                    <TabLink to={`${base}/analysis`} style={tab === 'analysis' ? tabActiveStyle : undefined} activeStyle={tabActiveStyle}>
                        Analyse
                    </TabLink>
                    <TabLink to={`${base}/attacks`} style={tab === 'attacks' ? tabActiveStyle : undefined} activeStyle={tabActiveStyle}>
                        Attaques
                    </TabLink>
                </TabBar>

                {tab === 'general' && (
                    <div css={tw`space-y-6`}>
                        <Panel padded>
                            <PanelHeader title={'Détails du préfixe'} description={'Informations réseau associées à cette adresse.'} />
                            <Grid2>
                                <Field>
                                    <FieldLabel>Adresse</FieldLabel>
                                    <FieldValue css={tw`flex items-center gap-2`}>
                                        <MonoIp>{row.ip}</MonoIp>
                                        <GhostButton compact onClick={onCopy} title={'Copier'}>
                                            <FontAwesomeIcon icon={faCopy} />
                                            {copied ? ' Copié' : ''}
                                        </GhostButton>
                                    </FieldValue>
                                </Field>
                                <Field>
                                    <FieldLabel>Service routé</FieldLabel>
                                    <FieldValue>
                                        {row.routed && row.service?.uuid ? (
                                            <GhostLink to={`/server/${row.service.uuid}`}>
                                                {row.service.name || row.service.uuidShort || row.service.uuid}
                                            </GhostLink>
                                        ) : (
                                            <Badge tone={'neutral'}>Non routé</Badge>
                                        )}
                                    </FieldValue>
                                </Field>
                                <Field>
                                    <FieldLabel>Reverse DNS</FieldLabel>
                                    <FieldValue>{reverse}</FieldValue>
                                </Field>
                                <Field>
                                    <FieldLabel>Allocation</FieldLabel>
                                    <FieldValue>#{row.allocation_id}</FieldValue>
                                </Field>
                                <Field>
                                    <FieldLabel>Anti-DDoS</FieldLabel>
                                    <FieldValue>
                                        <Badge tone={'ok'}>Activé</Badge>
                                    </FieldValue>
                                </Field>
                                <Field>
                                    <FieldLabel>Statut routage</FieldLabel>
                                    <FieldValue>
                                        {row.routed ? (
                                            <>
                                                <Badge tone={'ok'}>Routé</Badge>
                                                <MetaLine css={tw`mt-2`}>Ce préfixe est actuellement routé vers un service.</MetaLine>
                                            </>
                                        ) : (
                                            <>
                                                <Badge tone={'warn'}>Non routé</Badge>
                                                <MetaLine css={tw`mt-2`}>Aucune route active détectée pour ce préfixe.</MetaLine>
                                            </>
                                        )}
                                    </FieldValue>
                                </Field>
                            </Grid2>
                        </Panel>

                        <Panel padded>
                            <PanelHeader
                                title={'PTR / Reverse DNS'}
                                description={'Associez un nom d’hôte (PTR) à chaque IP pour le reverse DNS.'}
                            />
                            <EmptyState
                                icon={<FontAwesomeIcon icon={faGlobe} />}
                                title={'Gestion PTR'}
                                description={
                                    reverse !== '—'
                                        ? `PTR actuel : ${reverse}`
                                        : 'Aucune entrée PTR détectée pour le moment. La modification avancée sera disponible prochainement.'
                                }
                            />
                        </Panel>
                    </div>
                )}

                {tab === 'stats' && <NetworkIpStatsTab row={row} prefixLabel={prefix} />}
                {tab === 'analysis' && <NetworkIpAnalysisTab row={row} prefixLabel={prefix} />}

                {tab === 'attacks' && (
                    <div css={tw`space-y-6`}>
                        <Grid3>
                            <StatCard
                                label={'Attaques listées'}
                                value={String(attacks.length)}
                                icon={<FontAwesomeIcon icon={faShieldAlt} />}
                            />
                            <StatCard
                                label={'En cours'}
                                value={String(activeCount)}
                                hint={'Statut actif ou en cours'}
                                tone={activeCount > 0 ? 'danger' : 'ok'}
                                icon={<FontAwesomeIcon icon={faShieldAlt} />}
                            />
                            <StatCard
                                label={'Pic observé'}
                                value={peakBps > 0 ? `${(peakBps / 1e9).toFixed(2)} Gbps` : '—'}
                                icon={<FontAwesomeIcon icon={faNetworkWired} />}
                            />
                        </Grid3>

                        <Panel padded>
                            <PanelHeader
                                title={'Historique des attaques'}
                                description={`Événements DDoS enregistrés pour ${prefix}`}
                                actions={
                                    <GhostButton onClick={loadAttacks} disabled={attacksLoading} title={'Actualiser'}>
                                        <FontAwesomeIcon icon={faSyncAlt} spin={attacksLoading} /> Actualiser
                                    </GhostButton>
                                }
                            />

                            <Toolbar>
                                <SegmentedControl
                                    value={attackFilter}
                                    onChange={(v) => setAttackFilter(v as 'all' | 'active')}
                                    options={[
                                        { id: 'all', label: 'Toutes' },
                                        { id: 'active', label: 'En cours' },
                                    ]}
                                />
                                <SearchField
                                    value={attackQuery}
                                    onChange={setAttackQuery}
                                    placeholder={'Rechercher (ID, dates, type…)'}
                                />
                            </Toolbar>

                            {attacksError && (
                                <div css={tw`mb-4`}>
                                    <Alert type={'danger'}>{attacksError}</Alert>
                                </div>
                            )}

                            {attacksLoading ? (
                                <div css={tw`flex justify-center py-12`}>
                                    <Spinner centered />
                                </div>
                            ) : filteredAttacks.length === 0 ? (
                                <EmptyState
                                    icon={<FontAwesomeIcon icon={faSearch} />}
                                    title={'Aucune attaque'}
                                    description={'Aucune attaque enregistrée pour cette période.'}
                                />
                            ) : (
                                <>
                                    <div css={tw`hidden md:block`}>
                                        <DataTable
                                            headers={[
                                                { key: 'started', label: 'Début' },
                                                { key: 'ended', label: 'Fin' },
                                                { key: 'duration', label: 'Durée' },
                                                { key: 'gbps', label: 'Débit' },
                                                { key: 'pps', label: 'PPS' },
                                                { key: 'severity', label: 'Sévérité' },
                                                { key: 'status', label: 'Statut' },
                                                { key: 'actions', label: 'Actions', align: 'right' },
                                            ]}
                                        >
                                            {filteredAttacks.map((i) => {
                                                const active = isActiveIncident(i);
                                                const bps = Number(i.max_bps) || 0;
                                                const detailTo = `/network/attacks/${encodeURIComponent(String(i.incident_id))}`;
                                                return (
                                                    <tr key={String(i.incident_id)}>
                                                        <Td>{formatWhen(i.incident_start)}</Td>
                                                        <Td>{active ? '—' : formatWhen(i.incident_stop)}</Td>
                                                        <Td>{durationMin(i.incident_start, i.incident_stop)}</Td>
                                                        <Td accent={severityColor(bps)}>
                                                            {i.max_bps_formattet || (bps ? `${(bps / 1e9).toFixed(2)} Gbps` : '—')}
                                                        </Td>
                                                        <Td>{i.max_pps_formattet || (i.max_pps != null ? String(i.max_pps) : '—')}</Td>
                                                        <Td>
                                                            <Badge tone={severityTone(bps)}>
                                                                {severityTone(bps) === 'danger'
                                                                    ? 'Élevée'
                                                                    : severityTone(bps) === 'warn'
                                                                      ? 'Moyenne'
                                                                      : 'Faible'}
                                                            </Badge>
                                                        </Td>
                                                        <Td>
                                                            <Badge tone={active ? 'danger' : 'neutral'}>
                                                                {active ? 'En cours' : 'Terminée'}
                                                            </Badge>
                                                        </Td>
                                                        <Td align={'right'}>
                                                            <ActionsMenu
                                                                label={'Actions'}
                                                                items={[
                                                                    {
                                                                        key: 'view',
                                                                        label: "Voir l'attaque",
                                                                        icon: faEye,
                                                                        onClick: () => history.push(detailTo),
                                                                    },
                                                                ]}
                                                            />
                                                        </Td>
                                                    </tr>
                                                );
                                            })}
                                        </DataTable>
                                    </div>

                                    <div css={tw`md:hidden space-y-3`}>
                                        {filteredAttacks.map((i) => {
                                            const active = isActiveIncident(i);
                                            const bps = Number(i.max_bps) || 0;
                                            const detailTo = `/network/attacks/${encodeURIComponent(String(i.incident_id))}`;
                                            return (
                                                <MobileCard key={String(i.incident_id)}>
                                                    <div css={tw`flex items-start justify-between gap-3 mb-3`}>
                                                        <div>
                                                            <div css={tw`text-sm font-semibold`} style={{ color: CloudUI.text }}>
                                                                {formatWhen(i.incident_start)}
                                                            </div>
                                                            <MetaLine>{i.attack_type || i.protocol || 'DDoS'}</MetaLine>
                                                        </div>
                                                        <Badge tone={active ? 'danger' : 'neutral'}>
                                                            {active ? 'En cours' : 'Terminée'}
                                                        </Badge>
                                                    </div>
                                                    <MobileMetaGrid
                                                        items={[
                                                            {
                                                                label: 'Débit',
                                                                value: i.max_bps_formattet || (bps ? `${(bps / 1e9).toFixed(2)} Gbps` : '—'),
                                                            },
                                                            {
                                                                label: 'PPS',
                                                                value: i.max_pps_formattet || (i.max_pps != null ? String(i.max_pps) : '—'),
                                                            },
                                                            { label: 'Durée', value: durationMin(i.incident_start, i.incident_stop) },
                                                            {
                                                                label: 'Sévérité',
                                                                value:
                                                                    severityTone(bps) === 'danger'
                                                                        ? 'Élevée'
                                                                        : severityTone(bps) === 'warn'
                                                                          ? 'Moyenne'
                                                                          : 'Faible',
                                                            },
                                                        ]}
                                                    />
                                                    <div css={tw`mt-3 flex justify-end`}>
                                                        <PrimaryButton onClick={() => history.push(detailTo)}>
                                                            <FontAwesomeIcon icon={faEye} /> Voir
                                                        </PrimaryButton>
                                                    </div>
                                                </MobileCard>
                                            );
                                        })}
                                    </div>

                                    <MetaLine css={tw`mt-4`}>
                                        {filteredAttacks.length} affichée(s) sur {attacks.length}
                                    </MetaLine>
                                </>
                            )}
                        </Panel>
                    </div>
                )}
            </NetworkPage>
        </PageContentBlock>
    );
};
