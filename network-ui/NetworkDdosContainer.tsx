import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Link, useHistory, useLocation } from 'react-router-dom';
import useSWR from 'swr';
import { FontAwesomeIcon } from '@fortawesome/react-fontawesome';
import {
  faShieldAlt,
  faSearch,
  faDownload,
  faSync,
  faFilter,
  faEye,
} from '@fortawesome/free-solid-svg-icons';
import {
  DigiPage,
  DigiCard,
  DigiTableWrap,
  DigiTh,
  DigiTd,
  DigiTr,
  DigiButton,
  DigiInput,
  DigiAlert,
  DigiEmpty,
  DigiSpinner,
  DigiBadge,
} from './DigiUi';
import NetworkNavTabs from './NetworkNavTabs';
import NetworkIncidentModal from './NetworkIncidentModal';
import {
  getDdosIncidents,
  getDdosFilterModes,
  setDdosFilterMode,
  DdosIncident,
  DdosFilterMode,
  DdosFilterModesMap,
} from '@/api/network';

type PeriodKey = '24h' | '7d' | '30d' | '90d' | 'all';

const PERIOD_OPTIONS: { key: PeriodKey; label: string; hours: number | null }[] = [
  { key: '24h', label: '24 h', hours: 24 },
  { key: '7d', label: '7 j', hours: 24 * 7 },
  { key: '30d', label: '30 j', hours: 24 * 30 },
  { key: '90d', label: '90 j', hours: 24 * 90 },
  { key: 'all', label: 'Tout', hours: null },
];

const FILTER_MODE_OPTIONS: { value: DdosFilterMode; label: string; hint: string }[] = [
  { value: 'normal', label: 'Normal', hint: 'Filtrage standard (recommandé)' },
  { value: 'strict', label: 'Strict', hint: 'Plus agressif — peut impacter le trafic légitime' },
  { value: 'off', label: 'Désactivé', hint: 'Aucun filtrage — à utiliser avec précaution' },
];

function formatDate(iso?: string | null) {
  if (!iso) return '—';
  try {
    return new Date(iso).toLocaleString('fr-FR', {
      day: '2-digit',
      month: '2-digit',
      year: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    });
  } catch {
    return iso;
  }
}

function formatDuration(seconds?: number | null) {
  if (seconds == null || Number.isNaN(seconds)) return '—';
  if (seconds < 60) return `${Math.round(seconds)} s`;
  if (seconds < 3600) {
    const m = Math.floor(seconds / 60);
    const s = Math.round(seconds % 60);
    return s > 0 ? `${m} min ${s} s` : `${m} min`;
  }
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  return m > 0 ? `${h} h ${m} min` : `${h} h`;
}

function formatMbps(v?: number | null) {
  if (v == null || Number.isNaN(v)) return '—';
  if (v >= 1000) return `${(v / 1000).toFixed(2)} Gbit/s`;
  return `${v.toFixed(1)} Mbit/s`;
}

function formatPps(v?: number | null) {
  if (v == null || Number.isNaN(v)) return '—';
  if (v >= 1_000_000) return `${(v / 1_000_000).toFixed(2)} M`;
  if (v >= 1_000) return `${(v / 1_000).toFixed(1)} k`;
  return `${Math.round(v)}`;
}

function severityBadge(sev?: string | null) {
  const s = (sev || '').toLowerCase();
  if (s === 'critical' || s === 'high' || s === 'élevé' || s === 'eleve') {
    return <DigiBadge tone="red">{sev || 'Élevé'}</DigiBadge>;
  }
  if (s === 'medium' || s === 'moyen') {
    return <DigiBadge tone="amber">{sev || 'Moyen'}</DigiBadge>;
  }
  if (s === 'low' || s === 'faible') {
    return <DigiBadge tone="zinc">{sev || 'Faible'}</DigiBadge>;
  }
  return <DigiBadge tone="zinc">{sev || '—'}</DigiBadge>;
}

function statusBadge(status?: string | null, ended?: string | null) {
  const active = !ended && (status === 'active' || status === 'ongoing' || status === 'en_cours' || !status);
  if (active && !ended) {
    return <DigiBadge tone="red">En cours</DigiBadge>;
  }
  return <DigiBadge tone="emerald">Terminée</DigiBadge>;
}

function csvEscape(v: unknown) {
  const s = v == null ? '' : String(v);
  if (/[",\n\r]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
  return s;
}

function downloadCsv(filename: string, rows: string[][]) {
  const bom = '\uFEFF';
  const body = rows.map((r) => r.map(csvEscape).join(',')).join('\n');
  const blob = new Blob([bom + body], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

function periodCutoff(key: PeriodKey): number | null {
  const opt = PERIOD_OPTIONS.find((p) => p.key === key);
  if (!opt || opt.hours == null) return null;
  return Date.now() - opt.hours * 3600 * 1000;
}

export default function NetworkDdosContainer() {
  const history = useHistory();
  const location = useLocation();
  const params = useMemo(() => new URLSearchParams(location.search), [location.search]);
  const deepIp = params.get('ip') || '';
  const deepIncident = params.get('incident') || '';

  const [period, setPeriod] = useState<PeriodKey>('30d');
  const [activeOnly, setActiveOnly] = useState(false);
  const [search, setSearch] = useState(deepIp);
  const [typeFilter, setTypeFilter] = useState('');
  const [selected, setSelected] = useState<DdosIncident | null>(null);
  const [modeBusy, setModeBusy] = useState<string | null>(null);
  const [modeError, setModeError] = useState('');
  const [modeOk, setModeOk] = useState('');
  const deepOpened = useRef(false);

  const { data, error, isValidating, mutate } = useSWR('network-ddos-incidents', getDdosIncidents, {
    revalidateOnFocus: true,
    refreshInterval: (latest) => {
      const list = (latest as any)?.incidents as DdosIncident[] | undefined;
      if (!list?.length) return 0;
      const hasActive = list.some((i) => !i.ended_at && (i.status === 'active' || i.status === 'ongoing' || !i.status));
      return hasActive ? 15000 : 0;
    },
  });

  const {
    data: modesData,
    error: modesError,
    mutate: mutateModes,
  } = useSWR('network-ddos-filter-modes', getDdosFilterModes, {
    revalidateOnFocus: true,
  });

  const incidents = data?.incidents || [];
  const filterModes: DdosFilterModesMap = modesData?.modes || {};

  const attackTypes = useMemo(() => {
    const set = new Set<string>();
    incidents.forEach((i) => {
      if (i.attack_type) set.add(i.attack_type);
    });
    return Array.from(set).sort();
  }, [incidents]);

  const filtered = useMemo(() => {
    const cut = periodCutoff(period);
    const q = search.trim().toLowerCase();
    return incidents.filter((i) => {
      if (activeOnly && i.ended_at) return false;
      if (cut) {
        const t = i.started_at ? new Date(i.started_at).getTime() : 0;
        if (t && t < cut) return false;
      }
      if (typeFilter && i.attack_type !== typeFilter) return false;
      if (q) {
        const hay = `${i.target_ip || ''} ${i.attack_type || ''} ${i.id || ''} ${i.severity || ''}`.toLowerCase();
        if (!hay.includes(q)) return false;
      }
      return true;
    });
  }, [incidents, period, activeOnly, search, typeFilter]);

  const stats = useMemo(() => {
    const active = filtered.filter((i) => !i.ended_at).length;
    const peak = filtered.reduce((m, i) => Math.max(m, i.peak_mbps || 0), 0);
    return { total: filtered.length, active, peak };
  }, [filtered]);

  useEffect(() => {
    if (deepOpened.current || !deepIncident || !incidents.length) return;
    const found = incidents.find((i) => String(i.id) === deepIncident);
    if (found) {
      setSelected(found);
      deepOpened.current = true;
    }
  }, [deepIncident, incidents]);

  useEffect(() => {
    if (deepIp && !search) setSearch(deepIp);
  }, [deepIp]); // eslint-disable-line react-hooks/exhaustive-deps

  const onExport = useCallback(() => {
    const rows: string[][] = [
      ['ID', 'IP cible', 'Début', 'Fin', 'Durée (s)', 'Type', 'Pic Mbit/s', 'Pic PPS', 'Sévérité', 'Statut', 'Direction'],
      ...filtered.map((i) => [
        i.id,
        i.target_ip || '',
        i.started_at || '',
        i.ended_at || '',
        String(i.duration_seconds ?? ''),
        i.attack_type || '',
        String(i.peak_mbps ?? ''),
        String(i.peak_pps ?? ''),
        i.severity || '',
        i.ended_at ? 'terminée' : 'en cours',
        i.direction || '',
      ]),
    ];
    downloadCsv(`attaques-ddos-${new Date().toISOString().slice(0, 10)}.csv`, rows);
  }, [filtered]);

  const onSetMode = async (ip: string, mode: DdosFilterMode) => {
    setModeBusy(ip);
    setModeError('');
    setModeOk('');
    try {
      await setDdosFilterMode(ip, mode);
      await mutateModes();
      setModeOk(`Mode filtre mis à jour pour ${ip}.`);
    } catch (e: any) {
      setModeError(e?.message || 'Impossible de modifier le mode de filtrage.');
    } finally {
      setModeBusy(null);
    }
  };

  const openIncident = (inc: DdosIncident) => {
    setSelected(inc);
    const next = new URLSearchParams(location.search);
    next.set('incident', String(inc.id));
    if (inc.target_ip) next.set('ip', inc.target_ip);
    history.replace({ pathname: location.pathname, search: next.toString() });
  };

  const closeIncident = () => {
    setSelected(null);
    const next = new URLSearchParams(location.search);
    next.delete('incident');
    history.replace({ pathname: location.pathname, search: next.toString() });
  };

  const modeEntries = Object.entries(filterModes);

  return (
    <DigiPage
      title="Attaques DDoS"
      description="Historique consolidé des attaques sur vos préfixes et adresses IP."
      icon={<FontAwesomeIcon icon={faShieldAlt} className="h-6 w-6" />}
      tabs={<NetworkNavTabs />}
    >
      {error && (
        <DigiAlert tone="red" className="mb-6">
          Impossible de récupérer les attaques. {(error as any)?.message || ''}
        </DigiAlert>
      )}

      <div className="mb-6 grid gap-4 sm:grid-cols-3">
        <DigiCard className="p-5">
          <p className="text-xs font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
            Attaques listées
          </p>
          <p className="mt-2 text-3xl font-semibold tabular-nums text-zinc-900 dark:text-zinc-100">{stats.total}</p>
        </DigiCard>
        <DigiCard className="p-5">
          <p className="text-xs font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400">En cours</p>
          <p className="mt-2 text-3xl font-semibold tabular-nums text-red-600 dark:text-red-400">{stats.active}</p>
          <p className="mt-1 text-xs text-zinc-500 dark:text-zinc-400">Statut actif ou en cours</p>
        </DigiCard>
        <DigiCard className="p-5">
          <p className="text-xs font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400">Pic observé</p>
          <p className="mt-2 text-3xl font-semibold tabular-nums text-zinc-900 dark:text-zinc-100">
            {formatMbps(stats.peak)}
          </p>
        </DigiCard>
      </div>

      {modeEntries.length > 0 && (
        <DigiCard className="mb-6 overflow-hidden">
          <div className="border-b border-zinc-100 px-5 py-4 dark:border-zinc-800">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div>
                <h2 className="text-base font-semibold text-zinc-900 dark:text-zinc-100">
                  <FontAwesomeIcon icon={faFilter} className="mr-2 text-emerald-600 dark:text-emerald-400" />
                  Mode de filtrage par IP
                </h2>
                <p className="mt-0.5 text-sm text-zinc-500 dark:text-zinc-400">
                  Ajustez le niveau de protection anti-DDoS pour chaque adresse.
                </p>
              </div>
            </div>
            {modeError && (
              <DigiAlert tone="red" className="mt-3">
                {modeError}
              </DigiAlert>
            )}
            {modeOk && (
              <DigiAlert tone="emerald" className="mt-3">
                {modeOk}
              </DigiAlert>
            )}
            {modesError && (
              <DigiAlert tone="amber" className="mt-3">
                Modes de filtre temporairement indisponibles.
              </DigiAlert>
            )}
          </div>
          <div className="divide-y divide-zinc-100 dark:divide-zinc-800">
            {modeEntries.map(([ip, current]) => (
              <div
                key={ip}
                className="flex flex-col gap-3 px-5 py-4 sm:flex-row sm:items-center sm:justify-between"
              >
                <div className="min-w-0">
                  <Link
                    to={`/network/ips/${encodeURIComponent(ip)}`}
                    className="font-mono text-sm font-semibold text-emerald-700 hover:underline dark:text-emerald-400"
                  >
                    {ip}
                  </Link>
                  <p className="mt-0.5 text-xs text-zinc-500 dark:text-zinc-400">
                    {FILTER_MODE_OPTIONS.find((o) => o.value === current)?.hint || ''}
                  </p>
                </div>
                <div className="flex flex-wrap gap-2">
                  {FILTER_MODE_OPTIONS.map((opt) => (
                    <button
                      key={opt.value}
                      type="button"
                      disabled={modeBusy === ip}
                      onClick={() => onSetMode(ip, opt.value)}
                      className={`rounded-md border px-3 py-1.5 text-xs font-semibold transition ${
                        current === opt.value
                          ? 'border-emerald-600 bg-emerald-600 text-white dark:border-emerald-500 dark:bg-emerald-600'
                          : 'border-zinc-200 bg-white text-zinc-700 hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-200 dark:hover:bg-zinc-800'
                      }`}
                    >
                      {modeBusy === ip && current !== opt.value ? '…' : opt.label}
                    </button>
                  ))}
                </div>
              </div>
            ))}
          </div>
        </DigiCard>
      )}

      <DigiCard className="overflow-hidden">
        <div className="border-b border-zinc-100 px-5 py-4 dark:border-zinc-800">
          <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h2 className="text-base font-semibold text-zinc-900 dark:text-zinc-100">Historique des attaques</h2>
              <p className="mt-0.5 text-sm text-zinc-500 dark:text-zinc-400">
                Événements DDoS enregistrés sur l’ensemble de vos adresses IP
              </p>
            </div>
            <div className="flex flex-wrap items-center gap-2">
              <DigiButton
                type="button"
                variant="secondary"
                onClick={() => mutate()}
                disabled={isValidating}
              >
                <FontAwesomeIcon icon={faSync} className={isValidating ? 'animate-spin' : ''} />
                Actualiser
              </DigiButton>
              <DigiButton type="button" variant="secondary" onClick={onExport} disabled={!filtered.length}>
                <FontAwesomeIcon icon={faDownload} />
                Télécharger (CSV)
              </DigiButton>
            </div>
          </div>

          <div className="mt-4 flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
            <div className="flex flex-wrap items-center gap-2" role="group" aria-label="Filtrer les attaques">
              <span className="text-xs font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
                Filtrer
              </span>
              <button
                type="button"
                onClick={() => setActiveOnly(false)}
                className={`rounded-md px-3 py-1.5 text-sm font-semibold transition ${
                  !activeOnly
                    ? 'bg-emerald-600 text-white'
                    : 'bg-zinc-100 text-zinc-700 hover:bg-zinc-200 dark:bg-zinc-800 dark:text-zinc-200 dark:hover:bg-zinc-700'
                }`}
              >
                Toutes
              </button>
              <button
                type="button"
                onClick={() => setActiveOnly(true)}
                className={`rounded-md px-3 py-1.5 text-sm font-semibold transition ${
                  activeOnly
                    ? 'bg-emerald-600 text-white'
                    : 'bg-zinc-100 text-zinc-700 hover:bg-zinc-200 dark:bg-zinc-800 dark:text-zinc-200 dark:hover:bg-zinc-700'
                }`}
              >
                En cours
              </button>
              <div className="ml-1 flex flex-wrap gap-1">
                {PERIOD_OPTIONS.map((p) => (
                  <button
                    key={p.key}
                    type="button"
                    onClick={() => setPeriod(p.key)}
                    className={`rounded-md px-2.5 py-1 text-xs font-semibold transition ${
                      period === p.key
                        ? 'bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900'
                        : 'bg-zinc-100 text-zinc-600 hover:bg-zinc-200 dark:bg-zinc-800 dark:text-zinc-300 dark:hover:bg-zinc-700'
                    }`}
                  >
                    {p.label}
                  </button>
                ))}
              </div>
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <div className="relative min-w-[14rem] flex-1">
                <FontAwesomeIcon
                  icon={faSearch}
                  className="pointer-events-none absolute left-3 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-zinc-400"
                />
                <DigiInput
                  className="pl-9"
                  placeholder="Rechercher (UUID, IP, dates, statut…)"
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                />
              </div>
              {attackTypes.length > 0 && (
                <select
                  className="rounded-md border border-zinc-200 bg-white px-3 py-2 text-sm text-zinc-800 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100"
                  value={typeFilter}
                  onChange={(e) => setTypeFilter(e.target.value)}
                  aria-label="Type d'attaque"
                >
                  <option value="">Tous les types</option>
                  {attackTypes.map((t) => (
                    <option key={t} value={t}>
                      {t}
                    </option>
                  ))}
                </select>
              )}
            </div>
          </div>
        </div>

        {!data && !error ? (
          <div className="flex justify-center py-16">
            <DigiSpinner />
          </div>
        ) : filtered.length === 0 ? (
          <div className="p-8">
            <DigiEmpty
              title="Aucune attaque enregistrée"
              description="Aucune attaque ne correspond à vos filtres sur la période sélectionnée."
            />
          </div>
        ) : (
          <>
            <DigiTableWrap>
              <table className="w-full min-w-[960px] text-left text-sm">
                <thead>
                  <tr className="border-b border-zinc-200 bg-zinc-50/80 text-xs font-semibold uppercase tracking-wide text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900/40 dark:text-zinc-400">
                    <DigiTh>Préfixe / IP</DigiTh>
                    <DigiTh>Début</DigiTh>
                    <DigiTh>Fin</DigiTh>
                    <DigiTh>Durée</DigiTh>
                    <DigiTh>Débit</DigiTh>
                    <DigiTh>PPS</DigiTh>
                    <DigiTh>Direction</DigiTh>
                    <DigiTh>Sévérité</DigiTh>
                    <DigiTh>Statut</DigiTh>
                    <DigiTh className="text-right">Actions</DigiTh>
                  </tr>
                </thead>
                <tbody>
                  {filtered.map((inc) => {
                    const dir = (inc.direction || '').toLowerCase();
                    const dirLabel =
                      dir === 'in' || dir === 'inbound' || dir === 'entrant'
                        ? 'Entrant'
                        : dir === 'out' || dir === 'outbound' || dir === 'sortant'
                          ? 'Sortant'
                          : inc.direction || 'Inconnue';
                    return (
                      <DigiTr key={inc.id}>
                        <DigiTd>
                          <div className="flex flex-col gap-0.5">
                            {inc.target_ip ? (
                              <Link
                                to={`/network/ips/${encodeURIComponent(inc.target_ip)}`}
                                className="font-mono font-medium text-emerald-700 hover:underline dark:text-emerald-400"
                              >
                                {inc.target_ip}
                              </Link>
                            ) : (
                              <span className="text-zinc-400">—</span>
                            )}
                            {inc.attack_type && (
                              <span className="text-xs text-zinc-500 dark:text-zinc-400">{inc.attack_type}</span>
                            )}
                          </div>
                        </DigiTd>
                        <DigiTd className="whitespace-nowrap text-zinc-600 dark:text-zinc-300">
                          {formatDate(inc.started_at)}
                        </DigiTd>
                        <DigiTd className="whitespace-nowrap text-zinc-600 dark:text-zinc-300">
                          {formatDate(inc.ended_at)}
                        </DigiTd>
                        <DigiTd className="tabular-nums text-zinc-600 dark:text-zinc-300">
                          {formatDuration(inc.duration_seconds)}
                        </DigiTd>
                        <DigiTd className="tabular-nums font-medium text-zinc-900 dark:text-zinc-100">
                          {formatMbps(inc.peak_mbps)}
                        </DigiTd>
                        <DigiTd className="tabular-nums text-zinc-600 dark:text-zinc-300">
                          {formatPps(inc.peak_pps)}
                        </DigiTd>
                        <DigiTd className="text-zinc-600 dark:text-zinc-300">{dirLabel}</DigiTd>
                        <DigiTd>{severityBadge(inc.severity)}</DigiTd>
                        <DigiTd>{statusBadge(inc.status, inc.ended_at)}</DigiTd>
                        <DigiTd className="text-right">
                          <DigiButton type="button" variant="secondary" onClick={() => openIncident(inc)}>
                            <FontAwesomeIcon icon={faEye} />
                            Voir l&apos;attaque
                          </DigiButton>
                        </DigiTd>
                      </DigiTr>
                    );
                  })}
                </tbody>
              </table>
            </DigiTableWrap>
            <div className="border-t border-zinc-100 px-5 py-3 text-xs text-zinc-500 dark:border-zinc-800 dark:text-zinc-400">
              {filtered.length} affichée(s) sur {incidents.length}
            </div>
          </>
        )}
      </DigiCard>

      {selected && <NetworkIncidentModal incident={selected} onClose={closeIncident} />}
    </DigiPage>
  );
}
