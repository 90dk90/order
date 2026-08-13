import React, { useEffect, useMemo, useState } from "react";
import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import {
  faBolt,
  faClock,
  faGaugeHigh,
  faShieldHalved,
} from "@fortawesome/free-solid-svg-icons";
import type { DdosIncident } from "@/api/network";
import { getDdosIncident } from "@/api/network";
import {
  DigiAlert,
  DigiBadge,
  DigiButton,
  DigiEmpty,
  DigiModal,
  DigiSpinner,
  DigiTableWrap,
  DigiTd,
  DigiTh,
  DigiTr,
} from "./DigiUi";
import { durationMin, formatWhen, severityOfBps } from "@/components/network/NetworkUi";

type Props = {
  incident: DdosIncident | null;
  onClose: () => void;
};

type FlowRow = {
  time?: string | null;
  src?: string | null;
  dst?: string | null;
  proto?: string | null;
  packets?: number | null;
  asn?: string | number | null;
};

function asRecord(v: unknown): Record<string, unknown> | null {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
}

function pickFlows(detail: unknown): FlowRow[] {
  const root = asRecord(detail);
  if (!root) return [];
  const candidates = [root.flows, root.sources, root.attack_sources, asRecord(root.data)?.flows];
  for (const c of candidates) {
    if (Array.isArray(c)) {
      return c.map((row) => {
        const r = asRecord(row) || {};
        return {
          time: (r.time ?? r.timestamp ?? r.ts ?? null) as string | null,
          src: (r.src ?? r.source ?? r.src_ip ?? null) as string | null,
          dst: (r.dst ?? r.destination ?? r.dst_ip ?? null) as string | null,
          proto: (r.proto ?? r.protocol ?? null) as string | null,
          packets: typeof r.packets === "number" ? r.packets : typeof r.pps === "number" ? r.pps : null,
          asn: (r.asn ?? r.src_asn ?? null) as string | number | null,
        };
      });
    }
  }
  return [];
}

export default function NetworkIncidentModal({ incident, onClose }: Props) {
  const open = Boolean(incident);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [detail, setDetail] = useState<unknown>(null);
  const [tab, setTab] = useState<"overview" | "flows">("overview");

  useEffect(() => {
    if (!incident) {
      setDetail(null);
      setError(null);
      setLoading(false);
      setTab("overview");
      return;
    }

    let cancelled = false;
    setLoading(true);
    setError(null);
    setDetail(null);
    setTab("overview");

    void (async () => {
      try {
        const res = await getDdosIncident(String(incident.id));
        if (cancelled) return;
        setDetail(res);
      } catch (e) {
        if (cancelled) return;
        setError(e instanceof Error ? e.message : "Impossible de charger le détail de l'attaque.");
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [incident]);

  const severity = useMemo(() => {
    if (!incident) return severityOfBps(0);
    return severityOfBps(Number(incident.peak_bps || 0));
  }, [incident]);

  const flows = useMemo(() => pickFlows(detail), [detail]);

  if (!incident) return null;

  const peakGbps = Number(incident.peak_bps || 0) / 1e9;
  const peakMbps = Number(incident.peak_mbps || 0) || peakGbps * 1000;
  const duration = durationMin(incident.started_at, incident.ended_at);
  const stillActive = !incident.ended_at;

  return (
    <DigiModal
      open={open}
      onClose={onClose}
      title={`Détail de l'attaque #${incident.id}`}
      description={`Consultez le détail de l'attaque DDoS sur ${incident.ip || "—"} : pic de trafic, chronologie et sources identifiées.`}
      size="xl"
      footer={
        <DigiButton type="button" variant="secondary" onClick={onClose}>
          Fermer
        </DigiButton>
      }
    >
      <div className="space-y-5">
        <div className="flex flex-wrap items-center gap-2">
          <DigiBadge tone={severity.tone}>{severity.label}</DigiBadge>
          {stillActive ? <DigiBadge tone="amber">En cours</DigiBadge> : <DigiBadge tone="zinc">Terminée</DigiBadge>}
          {incident.attack_type ? <DigiBadge tone="sky">{incident.attack_type}</DigiBadge> : null}
        </div>

        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <div className="rounded-xl border border-zinc-200 bg-zinc-50/70 p-4 dark:border-zinc-800 dark:bg-zinc-900/40">
            <div className="flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
              <FontAwesomeIcon icon={faBolt} className="h-3.5 w-3.5 text-emerald-600 dark:text-emerald-400" />
              Cible
            </div>
            <p className="mt-2 font-mono text-sm font-semibold text-zinc-900 dark:text-zinc-100">{incident.ip || "—"}</p>
          </div>
          <div className="rounded-xl border border-zinc-200 bg-zinc-50/70 p-4 dark:border-zinc-800 dark:bg-zinc-900/40">
            <div className="flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
              <FontAwesomeIcon icon={faClock} className="h-3.5 w-3.5 text-emerald-600 dark:text-emerald-400" />
              Début
            </div>
            <p className="mt-2 text-sm font-semibold text-zinc-900 dark:text-zinc-100">{formatWhen(incident.started_at)}</p>
            <p className="mt-1 text-xs text-zinc-500 dark:text-zinc-400">
              Fin : {incident.ended_at ? formatWhen(incident.ended_at) : "—"}
            </p>
          </div>
          <div className="rounded-xl border border-zinc-200 bg-zinc-50/70 p-4 dark:border-zinc-800 dark:bg-zinc-900/40">
            <div className="flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
              <FontAwesomeIcon icon={faGaugeHigh} className="h-3.5 w-3.5 text-emerald-600 dark:text-emerald-400" />
              Pic débit
            </div>
            <p className="mt-2 text-sm font-semibold text-zinc-900 dark:text-zinc-100">
              {peakGbps >= 0.01 ? `${peakGbps.toFixed(2)} Gbps` : `${peakMbps.toFixed(1)} Mbps`}
            </p>
            <p className="mt-1 text-xs text-zinc-500 dark:text-zinc-400">Mesure agrégée de l&apos;événement</p>
          </div>
          <div className="rounded-xl border border-zinc-200 bg-zinc-50/70 p-4 dark:border-zinc-800 dark:bg-zinc-900/40">
            <div className="flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
              <FontAwesomeIcon icon={faShieldHalved} className="h-3.5 w-3.5 text-emerald-600 dark:text-emerald-400" />
              Pic PPS
            </div>
            <p className="mt-2 text-sm font-semibold text-zinc-900 dark:text-zinc-100">
              {Number(incident.peak_pps || 0).toLocaleString("fr-FR")}
            </p>
            <p className="mt-1 text-xs text-zinc-500 dark:text-zinc-400">
              Durée : {duration != null ? `${duration} min` : "—"}
            </p>
          </div>
        </div>

        <div className="flex flex-wrap gap-2 border-b border-zinc-200 pb-2 dark:border-zinc-800">
          <button
            type="button"
            onClick={() => setTab("overview")}
            className={
              tab === "overview"
                ? "rounded-lg bg-emerald-600 px-3 py-1.5 text-sm font-semibold text-white"
                : "rounded-lg px-3 py-1.5 text-sm font-medium text-zinc-600 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-800"
            }
          >
            Contexte
          </button>
          <button
            type="button"
            onClick={() => setTab("flows")}
            className={
              tab === "flows"
                ? "rounded-lg bg-emerald-600 px-3 py-1.5 text-sm font-semibold text-white"
                : "rounded-lg px-3 py-1.5 text-sm font-medium text-zinc-600 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-800"
            }
          >
            Sources ({flows.length})
          </button>
        </div>

        {loading ? (
          <div className="flex items-center justify-center gap-3 py-10 text-sm text-zinc-500 dark:text-zinc-400">
            <DigiSpinner className="h-5 w-5" />
            Chargement du détail…
          </div>
        ) : null}

        {error ? <DigiAlert tone="amber" title="Détail partiel" description={error} /> : null}

        {!loading && tab === "overview" ? (
          <div className="rounded-xl border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-950/40">
            <h3 className="text-sm font-semibold text-zinc-900 dark:text-zinc-100">Contexte de détection</h3>
            <dl className="mt-4 grid gap-3 sm:grid-cols-2">
              <div>
                <dt className="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-400">Événement DDoS</dt>
                <dd className="mt-1 text-sm text-zinc-800 dark:text-zinc-200">#{incident.id}</dd>
              </div>
              <div>
                <dt className="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-400">Cible</dt>
                <dd className="mt-1 font-mono text-sm text-zinc-800 dark:text-zinc-200">{incident.ip || "—"}</dd>
              </div>
              <div>
                <dt className="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-400">Direction</dt>
                <dd className="mt-1 text-sm text-zinc-800 dark:text-zinc-200">Entrant</dd>
              </div>
              <div>
                <dt className="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-400">Sévérrité</dt>
                <dd className="mt-1 text-sm text-zinc-800 dark:text-zinc-200">{severity.label}</dd>
              </div>
            </dl>
            <p className="mt-4 text-sm text-zinc-600 dark:text-zinc-300">
              Fenêtre d&apos;attaque : {formatWhen(incident.started_at)}
              {incident.ended_at ? ` → ${formatWhen(incident.ended_at)}` : " (toujours active)"}
            </p>
          </div>
        ) : null}

        {!loading && tab === "flows" ? (
          flows.length === 0 ? (
            <DigiEmpty
              title="Aucune source identifiée"
              description="Aucune source n'a été renvoyée pour cette attaque."
            />
          ) : (
            <DigiTableWrap>
              <table className="min-w-full divide-y divide-zinc-200 dark:divide-zinc-800">
                <thead className="bg-zinc-50 dark:bg-zinc-900/50">
                  <tr>
                    <DigiTh>Date</DigiTh>
                    <DigiTh>Source</DigiTh>
                    <DigiTh>Destination</DigiTh>
                    <DigiTh>Protocole</DigiTh>
                    <DigiTh>Paquets</DigiTh>
                    <DigiTh>ASN</DigiTh>
                  </tr>
                </thead>
                <tbody className="divide-y divide-zinc-200 bg-white dark:divide-zinc-800 dark:bg-zinc-950">
                  {flows.map((flow, idx) => (
                    <DigiTr key={`${flow.src || "src"}-${idx}`}>
                      <DigiTd className="whitespace-nowrap text-zinc-600 dark:text-zinc-300">
                        {flow.time ? formatWhen(String(flow.time)) : "—"}
                      </DigiTd>
                      <DigiTd className="font-mono text-zinc-900 dark:text-zinc-100">{flow.src || "—"}</DigiTd>
                      <DigiTd className="font-mono text-zinc-600 dark:text-zinc-300">{flow.dst || "—"}</DigiTd>
                      <DigiTd className="text-zinc-700 dark:text-zinc-200">{flow.proto || "—"}</DigiTd>
                      <DigiTd className="tabular-nums text-zinc-700 dark:text-zinc-200">
                        {flow.packets != null ? Number(flow.packets).toLocaleString("fr-FR") : "—"}
                      </DigiTd>
                      <DigiTd className="text-zinc-600 dark:text-zinc-300">{flow.asn != null ? String(flow.asn) : "—"}</DigiTd>
                    </DigiTr>
                  ))}
                </tbody>
              </table>
            </DigiTableWrap>
          )
        ) : null}
      </div>
    </DigiModal>
  );
}
