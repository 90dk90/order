"use client";

import { Fragment, useCallback, useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import {
  faArrowUpRightFromSquare,
  faCheck,
  faChevronLeft,
  faCopy,
  faDownload,
  faGlobe,
  faNetworkWired,
  faPencil,
  faPlus,
  faRoute,
  faSearch,
  faServer,
  faShieldHalved,
} from "@fortawesome/free-solid-svg-icons";
import {
  getDdosIncidents,
  getNetworkIps,
  updateNetworkRdns,
  type DdosIncidentSummary,
  type NetworkIpRow,
} from "@/api/network";
import { NetworkNavTabs } from "./NetworkNavTabs";
import {
  DigiPage,
  DigiCard,
  DigiSpinner,
  DigiEmpty,
  DigiButton,
  DigiAlert,
  DigiBadge,
  DigiModal,
  DigiInput,
  DigiTableWrap,
  DigiTh,
  DigiTd,
  DigiTr,
} from "./NetworkUi";
import { cloudUi } from "./cloudUi";

type PrefixTab = "general" | "stats" | "analysis" | "attacks";

function encodeIpId(ip: string): string {
  return encodeURIComponent(ip);
}

function decodeIpId(raw: string | undefined): string | null {
  if (!raw) return null;
  try {
    return decodeURIComponent(raw);
  } catch {
    return raw;
  }
}

function cidrLabel(ip: string): string {
  return ip.includes("/") ? ip : `${ip}/32`;
}

function bareIp(ip: string): string {
  return ip.split("/")[0] ?? ip;
}

function inAddrArpa(ip: string): string {
  const parts = bareIp(ip).split(".");
  if (parts.length !== 4) return "—";
  return `${parts[2]}.${parts[1]}.${parts[0]}.in-addr.arpa`;
}

function CopyButton({
  value,
  label = "Copier",
}: {
  value: string;
  label?: string;
}) {
  const [ok, setOk] = useState(false);
  return (
    <DigiButton
      type="button"
      variant="secondary"
      size="sm"
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(value);
          setOk(true);
          window.setTimeout(() => setOk(false), 1500);
        } catch {
          /* ignore */
        }
      }}
    >
      <FontAwesomeIcon icon={ok ? faCheck : faCopy} className="h-3.5 w-3.5" />
      {ok ? "Copié" : label}
    </DigiButton>
  );
}

function OrderAdditionalIpModal({
  open,
  onClose,
  services,
}: {
  open: boolean;
  onClose: () => void;
  services: { id: string; label: string }[];
}) {
  const [serviceId, setServiceId] = useState("");
  const [qty, setQty] = useState("1");

  useEffect(() => {
    if (open) {
      setServiceId(services[0]?.id ?? "");
      setQty("1");
    }
  }, [open, services]);

  return (
    <DigiModal
      open={open}
      onClose={onClose}
      title="Commander IP supplémentaire"
      description="Sélectionnez le service concerné pour lancer la commande d'une IP supplémentaire."
      footer={
        <>
          <DigiButton type="button" variant="secondary" onClick={onClose}>
            Fermer
          </DigiButton>
          <DigiButton
            type="button"
            onClick={() => {
              window.open(
                "https://client.digi.ovh/submitticket.php?step=2&deptid=1",
                "_blank",
                "noopener,noreferrer",
              );
              onClose();
            }}
          >
            Contacter le support
          </DigiButton>
        </>
      }
    >
      <div className="space-y-4">
        <label className="block text-sm">
          <span className="mb-1.5 block font-medium text-gray-700 dark:text-gray-300">
            Service concerné
          </span>
          <select
            className={cloudUi.select}
            value={serviceId}
            onChange={(e) => setServiceId(e.target.value)}
          >
            <option value="">Sélectionner un service</option>
            {services.map((s) => (
              <option key={s.id} value={s.id}>
                {s.label}
              </option>
            ))}
          </select>
        </label>
        <label className="block text-sm">
          <span className="mb-1.5 block font-medium text-gray-700 dark:text-gray-300">
            Sélectionner la quantité
          </span>
          <DigiInput
            type="number"
            min={1}
            max={16}
            value={qty}
            onChange={setQty}
          />
        </label>
        <DigiAlert variant="info">
          La commande d&apos;IP supplémentaire se finalise via un ticket support
          Digi. Indiquez le service et la quantité souhaités.
        </DigiAlert>
      </div>
    </DigiModal>
  );
}

function EditPtrModal({
  open,
  onClose,
  ip,
  initial,
  onSaved,
}: {
  open: boolean;
  onClose: () => void;
  ip: string;
  initial: string;
  onSaved: (hostname: string) => void;
}) {
  const [value, setValue] = useState(initial);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setValue(initial);
      setError(null);
    }
  }, [open, initial]);

  return (
    <DigiModal
      open={open}
      onClose={onClose}
      title="Modifier le PTR / Reverse DNS"
      description="Mettez à jour le PTR de cette IP. Cette action impacte directement la résolution reverse DNS."
      footer={
        <>
          <DigiButton type="button" variant="secondary" onClick={onClose}>
            Annuler
          </DigiButton>
          <DigiButton
            type="button"
            disabled={saving || !value.trim()}
            onClick={async () => {
              setSaving(true);
              setError(null);
              try {
                const hostname = value.trim();
                await updateNetworkRdns(ip, hostname);
                onSaved(hostname);
                onClose();
              } catch (e) {
                setError(
                  e instanceof Error
                    ? e.message
                    : "Impossible de sauvegarder l'entrée PTR.",
                );
              } finally {
                setSaving(false);
              }
            }}
          >
            {saving ? "Enregistrement…" : "Enregistrer"}
          </DigiButton>
        </>
      }
    >
      <div className="space-y-3">
        <p className="font-mono text-sm text-gray-600 dark:text-gray-400">{ip}</p>
        <label className="block text-sm">
          <span className="mb-1.5 block font-medium text-gray-700 dark:text-gray-300">
            Nom d&apos;hôte cible (FQDN)
          </span>
          <DigiInput
            value={value}
            onChange={setValue}
            placeholder="ex: srv01.example.com."
          />
        </label>
        <DigiAlert variant="warning">
          Attention : utilisez un FQDN valide (ex: host.example.com). Une mauvaise
          valeur peut perturber la délivrabilité mail et certains contrôles
          réseau.
        </DigiAlert>
        {error ? <DigiAlert variant="error">{error}</DigiAlert> : null}
      </div>
    </DigiModal>
  );
}

function IpListView({
  rows,
  onOrderClick,
}: {
  rows: NetworkIpRow[];
  onOrderClick: () => void;
}) {
  return (
    <DigiPage>
      <NetworkNavTabs />
      <div className="mb-6 flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-3">
            <span className="inline-flex shrink-0 text-emerald-700 dark:text-emerald-400">
              <FontAwesomeIcon icon={faNetworkWired} className="h-6 w-6" />
            </span>
            <h1 className="text-2xl font-semibold tracking-tight text-gray-900 sm:text-3xl dark:text-gray-100">
              Adresses IP
            </h1>
          </div>
          <p className="mt-1.5 text-base text-gray-600 dark:text-gray-300">
            Adresses IP associées à vos services actifs et suspendus.
          </p>
        </div>
      </div>

      <DigiCard>
        <div className="mb-4 flex justify-end">
          <DigiButton type="button" onClick={onOrderClick}>
            <FontAwesomeIcon icon={faPlus} className="h-4 w-4" />
            Commander IP supplémentaire
          </DigiButton>
        </div>

        {rows.length === 0 ? (
          <DigiEmpty
            title="Aucune adresse IP"
            description="Aucune adresse IP trouvée pour vos services actifs/suspendus."
          />
        ) : (
          <DigiTableWrap>
            <table className="w-full min-w-[760px] text-sm">
              <thead>
                <tr className="border-b border-gray-200 bg-gray-50/80 text-left text-xs font-semibold tracking-[0.08em] text-gray-500 uppercase dark:border-gray-800 dark:bg-gray-900/30 dark:text-gray-400">
                  <DigiTh>Adresse IP</DigiTh>
                  <DigiTh>Région</DigiTh>
                  <DigiTh>Service routé</DigiTh>
                  <DigiTh>Reverse DNS</DigiTh>
                  <DigiTh className="text-right">Actions</DigiTh>
                </tr>
              </thead>
              <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
                {rows.map((row) => {
                  const region =
                    (row as NetworkIpRow & { region?: string }).region ?? "—";
                  const serviceHref = row.service?.id
                    ? `/services/${encodeURIComponent(row.service.id)}`
                    : null;
                  return (
                    <DigiTr key={row.ip}>
                      <DigiTd className="font-mono text-gray-900 dark:text-gray-100">
                        <Link
                          to={`/network/ips/${encodeIpId(row.ip)}`}
                          className="hover:text-emerald-700 dark:hover:text-emerald-400"
                        >
                          {cidrLabel(row.ip)}
                        </Link>
                      </DigiTd>
                      <DigiTd className="font-medium text-gray-600 dark:text-gray-400">
                        {region}
                      </DigiTd>
                      <DigiTd>
                        {row.service ? (
                          <div className="flex flex-col gap-1">
                            <span className="font-medium text-gray-900 dark:text-gray-100">
                              {row.service.name}
                            </span>
                            {serviceHref ? (
                              <Link
                                to={serviceHref}
                                className="text-xs font-semibold text-emerald-700 hover:underline dark:text-emerald-400"
                              >
                                Ouvrir le service
                              </Link>
                            ) : null}
                          </div>
                        ) : (
                          <span className="text-gray-400 dark:text-gray-600">—</span>
                        )}
                      </DigiTd>
                      <DigiTd className="max-w-[14rem] truncate text-gray-600 dark:text-gray-400">
                        {row.reverse_dns?.trim() || (
                          <span className="text-gray-400 dark:text-gray-600">—</span>
                        )}
                      </DigiTd>
                      <DigiTd className="text-right">
                        <Link
                          to={`/network/ips/${encodeIpId(row.ip)}`}
                          className="inline-flex items-center justify-center rounded-lg border border-gray-200 bg-white px-3 py-2 text-sm font-semibold text-gray-700 transition hover:bg-gray-50 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800"
                        >
                          Gérer ce préfixe
                        </Link>
                      </DigiTd>
                    </DigiTr>
                  );
                })}
              </tbody>
            </table>
          </DigiTableWrap>
        )}
      </DigiCard>
    </DigiPage>
  );
}

function PrefixDetailView({
  row,
  tab,
  onTabChange,
  incidents,
  incidentsLoading,
  onRowPatched,
}: {
  row: NetworkIpRow;
  tab: PrefixTab;
  onTabChange: (t: PrefixTab) => void;
  incidents: DdosIncidentSummary[];
  incidentsLoading: boolean;
  onRowPatched: (next: NetworkIpRow) => void;
}) {
  const [ptrFilter, setPtrFilter] = useState("");
  const [selected, setSelected] = useState(false);
  const [editOpen, setEditOpen] = useState(false);
  const ipBare = bareIp(row.ip);
  const label = cidrLabel(row.ip);
  const ptr = row.reverse_dns?.trim() ?? "";
  const zone = inAddrArpa(row.ip);
  const mask =
    (row as NetworkIpRow & { netmask?: string }).netmask ??
    (row.ip.includes("/") && row.ip.endsWith("/32")
      ? "255.255.255.255"
      : "—");
  const gateway =
    (row as NetworkIpRow & { gateway?: string }).gateway ?? "—";
  const dns = (row as NetworkIpRow & { dns?: string }).dns ?? "—";
  const macRaw = (row as NetworkIpRow & { mac?: string }).mac?.trim();
  const mac = macRaw || "00:00:00:00:00:00";
  const antiDdos =
    (row as NetworkIpRow & { anti_ddos?: boolean }).anti_ddos ?? true;

  const ptrVisible =
    !ptrFilter.trim() ||
    ipBare.toLowerCase().includes(ptrFilter.toLowerCase()) ||
    ptr.toLowerCase().includes(ptrFilter.toLowerCase());

  const tabs: { id: PrefixTab; label: string }[] = [
    { id: "general", label: "Informations générales" },
    { id: "stats", label: "Statistiques" },
    { id: "analysis", label: "Analyse" },
    { id: "attacks", label: "Attaques" },
  ];

  const relatedIncidents = useMemo(
    () =>
      incidents.filter((i) => {
        const target = (i.target_ip || "").toLowerCase();
        return target.includes(ipBare.toLowerCase()) || !target;
      }),
    [incidents, ipBare],
  );

  const downloadCsv = () => {
    if (!selected) return;
    const lines = ["IP,Zone,PTR", `${ipBare},${zone},"${ptr.replace(/"/g, '""')}"`];
    const blob = new Blob([lines.join("\n")], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `ptr-${ipBare}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <DigiPage>
      <NetworkNavTabs />
      <div className="mb-6">
        <div className="flex flex-wrap items-center gap-3">
          <span className="inline-flex shrink-0 text-emerald-700 dark:text-emerald-400">
            <FontAwesomeIcon icon={faNetworkWired} className="h-6 w-6" />
          </span>
          <h1 className="text-2xl font-semibold tracking-tight text-gray-900 sm:text-3xl dark:text-gray-100">
            {label}
          </h1>
        </div>
        <p className="mt-1.5 text-base text-gray-600 dark:text-gray-300">
          Gérez votre préfixe IP, configurez le reverse DNS et visualisez les
          statistiques.
        </p>
      </div>

      <div className="-mb-px flex flex-wrap gap-2 border-b border-gray-200 dark:border-gray-800">
        {tabs.map((t) => {
          const active = tab === t.id;
          return (
            <button
              key={t.id}
              type="button"
              onClick={() => onTabChange(t.id)}
              className={[
                "inline-flex items-center gap-2 rounded-t-lg border-b-2 px-4 py-3 text-sm font-semibold transition",
                active
                  ? "border-emerald-600 text-emerald-700 dark:border-emerald-400 dark:text-emerald-300"
                  : "border-transparent text-gray-500 hover:border-gray-300 hover:text-gray-800 dark:text-gray-400 dark:hover:border-gray-700 dark:hover:text-gray-200",
              ].join(" ")}
              aria-current={active ? "page" : undefined}
            >
              {t.label}
            </button>
          );
        })}
      </div>

      <div className="mt-8 space-y-7">
        {tab === "general" ? (
          <Fragment>
            <div className="rounded-xl border border-zinc-200 bg-white shadow-sm dark:border-zinc-800 dark:bg-zinc-950/40">
              <div className="flex flex-col gap-5 px-6 py-6 sm:flex-row sm:items-center sm:justify-between sm:px-8">
                <div className="flex min-w-0 items-center gap-5">
                  <div className="flex h-14 w-14 shrink-0 items-center justify-center rounded-xl border border-zinc-200 bg-zinc-50 text-emerald-700 dark:border-zinc-700 dark:bg-zinc-900 dark:text-emerald-400">
                    <FontAwesomeIcon icon={faNetworkWired} className="h-6 w-6" />
                  </div>
                  <div className="min-w-0">
                    <p className="text-xs font-medium tracking-widest text-zinc-400 uppercase dark:text-zinc-500">
                      Détails du préfixe
                    </p>
                    <div className="mt-1.5 flex flex-wrap items-center gap-3">
                      <span className="truncate font-mono text-2xl font-bold text-zinc-900 dark:text-zinc-100">
                        {label}
                      </span>
                      {row.routed ? (
                        <DigiBadge tone="emerald" dot uppercase>
                          Routé
                        </DigiBadge>
                      ) : (
                        <DigiBadge tone="zinc" dot uppercase>
                          Non routé
                        </DigiBadge>
                      )}
                    </div>
                  </div>
                </div>
                <div className="flex shrink-0 flex-wrap items-center gap-3">
                  <CopyButton value={label} />
                  <Link to="/network/ips">
                    <DigiButton type="button" variant="primary">
                      <FontAwesomeIcon
                        icon={faArrowUpRightFromSquare}
                        className="h-3.5 w-3.5"
                      />
                      Retour aux IPs
                    </DigiButton>
                  </Link>
                </div>
              </div>
            </div>

            <div className="grid grid-cols-1 gap-8 lg:grid-cols-2">
              <div className="rounded-xl border border-zinc-200 bg-white shadow-sm dark:border-zinc-800 dark:bg-zinc-950/40">
                <div className="flex items-center gap-3 border-b border-zinc-100 px-6 py-5 dark:border-zinc-800">
                  <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-emerald-50 text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-400">
                    <FontAwesomeIcon icon={faRoute} className="h-4 w-4" />
                  </div>
                  <h2 className="text-base font-semibold text-zinc-800 dark:text-zinc-200">
                    Configuration réseau
                  </h2>
                </div>
                <dl className="divide-y divide-zinc-100 dark:divide-zinc-800">
                  {[
                    { icon: faGlobe, label: "Masque", value: mask },
                    { icon: faRoute, label: "Passerelle", value: gateway },
                    { icon: faGlobe, label: "DNS", value: dns },
                    {
                      icon: faShieldHalved,
                      label: "Anti-DDOS",
                      value: antiDdos ? "Activé" : "Désactivé",
                      badge: true as const,
                      ok: antiDdos,
                    },
                    { icon: faServer, label: "MAC", value: mac },
                  ].map((item) => (
                    <div
                      key={item.label}
                      className="flex items-center justify-between gap-4 px-6 py-5"
                    >
                      <dt className="flex items-center gap-3 text-base text-zinc-500 dark:text-zinc-400">
                        <FontAwesomeIcon
                          icon={item.icon}
                          className="h-4 w-4 shrink-0 text-zinc-400 dark:text-zinc-500"
                        />
                        {item.label}
                      </dt>
                      <dd>
                        {"badge" in item && item.badge ? (
                          <span
                            className={`inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-[11px] font-semibold tracking-wide uppercase ${
                              item.ok
                                ? "border-emerald-200 bg-emerald-50 text-emerald-800 dark:border-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-300"
                                : "border-zinc-200 bg-zinc-50 text-zinc-700 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"
                            }`}
                          >
                            <FontAwesomeIcon
                              icon={faShieldHalved}
                              className="h-3 w-3"
                            />
                            {item.value}
                          </span>
                        ) : (
                          <span className="font-mono text-base font-medium text-zinc-900 dark:text-zinc-100">
                            {item.value}
                          </span>
                        )}
                      </dd>
                    </div>
                  ))}
                </dl>
              </div>

              <div className="rounded-xl border border-zinc-200 bg-white shadow-sm dark:border-zinc-800 dark:bg-zinc-950/40">
                <div className="flex items-center gap-3 border-b border-zinc-100 px-6 py-5 dark:border-zinc-800">
                  <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-emerald-50 text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-400">
                    <FontAwesomeIcon icon={faServer} className="h-4 w-4" />
                  </div>
                  <h2 className="text-base font-semibold text-zinc-800 dark:text-zinc-200">
                    Statut routage
                  </h2>
                </div>
                <div className="px-6 py-6">
                  <div className="flex items-start justify-between gap-5">
                    <p className="text-base text-zinc-500 dark:text-zinc-400">
                      {row.routed
                        ? "Ce préfixe est actuellement routé vers un service."
                        : "Aucune route active détectée pour ce préfixe."}
                    </p>
                    <DigiBadge
                      tone={row.routed ? "emerald" : "zinc"}
                      dot
                      uppercase
                    >
                      {row.routed ? "Routé" : "Non routé"}
                    </DigiBadge>
                  </div>
                  {row.service ? (
                    <div className="mt-6 rounded-xl border border-zinc-200 dark:border-zinc-700">
                      <div className="flex flex-wrap items-center gap-4 border-b border-zinc-100 px-5 py-4 dark:border-zinc-800">
                        <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg border border-zinc-200 bg-zinc-50 text-zinc-500 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400">
                          <FontAwesomeIcon icon={faServer} className="h-5 w-5" />
                        </div>
                        <div className="min-w-0 flex-1">
                          <p className="text-xs font-medium tracking-widest text-zinc-400 uppercase dark:text-zinc-500">
                            Service routé
                          </p>
                          <p className="mt-0.5 truncate text-base font-semibold text-zinc-900 dark:text-zinc-100">
                            {row.service.name}
                          </p>
                        </div>
                        <Link
                          to={`/services/${encodeURIComponent(row.service.id)}`}
                        >
                          <DigiButton type="button" variant="secondary" size="sm">
                            Ouvrir le service
                            <FontAwesomeIcon
                              icon={faArrowUpRightFromSquare}
                              className="h-3.5 w-3.5"
                            />
                          </DigiButton>
                        </Link>
                      </div>
                      <div className="px-5 py-3">
                        <p className="text-sm text-zinc-400 dark:text-zinc-500">
                          ID {row.service.id}
                        </p>
                      </div>
                    </div>
                  ) : null}
                </div>
              </div>
            </div>

            <div className="rounded-xl border border-zinc-200 bg-white shadow-sm dark:border-zinc-800 dark:bg-zinc-950/40">
              <div className="border-b border-zinc-100 px-6 py-5 dark:border-zinc-800">
                <div className="flex flex-col gap-5 sm:flex-row sm:items-center sm:justify-between">
                  <div className="flex items-center gap-3">
                    <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-emerald-50 text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-400">
                      <FontAwesomeIcon icon={faGlobe} className="h-4 w-4" />
                    </div>
                    <div>
                      <h2 className="text-base font-semibold text-zinc-800 dark:text-zinc-200">
                        PTR / Reverse DNS
                      </h2>
                      <p className="mt-0.5 text-sm text-zinc-500 dark:text-zinc-400">
                        Associez un nom d&apos;hôte (PTR) à chaque IP pour le
                        reverse DNS.
                      </p>
                    </div>
                  </div>
                  <div className="relative w-full shrink-0 sm:max-w-xs">
                    <FontAwesomeIcon
                      icon={faSearch}
                      className="pointer-events-none absolute top-1/2 left-3 h-4 w-4 -translate-y-1/2 text-zinc-400"
                    />
                    <input
                      className="w-full rounded-lg border border-zinc-300 bg-white py-2.5 pr-4 pl-10 text-sm text-zinc-900 outline-none placeholder:text-zinc-400 focus:border-emerald-600 focus:ring-2 focus:ring-emerald-600/15 dark:border-zinc-600 dark:bg-zinc-900 dark:text-zinc-100"
                      placeholder="Filtrer par IP ou hostname…"
                      value={ptrFilter}
                      onChange={(e) => setPtrFilter(e.target.value)}
                    />
                  </div>
                </div>
              </div>

              <div className="flex flex-wrap items-center justify-between gap-3 border-b border-zinc-100 bg-zinc-50/60 px-6 py-3.5 dark:border-zinc-800 dark:bg-zinc-900/40">
                <div className="flex items-center gap-2">
                  <DigiButton
                    type="button"
                    variant="secondary"
                    size="sm"
                    onClick={() => setSelected(true)}
                  >
                    Sélectionner tout
                  </DigiButton>
                  <DigiButton
                    type="button"
                    variant="secondary"
                    size="sm"
                    disabled={!selected}
                    onClick={() => setSelected(false)}
                  >
                    Tout retirer
                  </DigiButton>
                </div>
                <DigiButton
                  type="button"
                  variant="secondary"
                  size="sm"
                  disabled={!selected}
                  onClick={downloadCsv}
                >
                  <FontAwesomeIcon icon={faDownload} className="h-3.5 w-3.5" />
                  Télécharger (CSV)
                </DigiButton>
              </div>

              <div className="overflow-x-auto">
                <table className="w-full min-w-[900px]">
                  <thead>
                    <tr className="border-b border-zinc-100 bg-zinc-50 text-left dark:border-zinc-800 dark:bg-zinc-900/50">
                      <th className="w-12 px-6 py-4" />
                      <th className="px-6 py-4 text-sm font-semibold text-zinc-500 dark:text-zinc-400">
                        IP
                      </th>
                      <th className="px-6 py-4 text-sm font-semibold text-zinc-500 dark:text-zinc-400">
                        Zone
                      </th>
                      <th className="px-6 py-4 text-sm font-semibold text-zinc-500 dark:text-zinc-400">
                        État PTR
                      </th>
                      <th className="px-6 py-4 text-right text-sm font-semibold text-zinc-500 dark:text-zinc-400">
                        Gérer
                      </th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
                    {ptrVisible ? (
                      <tr className="hover:bg-zinc-50/80 dark:hover:bg-zinc-900/40">
                        <td className="px-6 py-4">
                          <input
                            type="checkbox"
                            className="h-4 w-4 rounded border-zinc-300 text-emerald-600 focus:ring-emerald-600"
                            checked={selected}
                            onChange={(e) => setSelected(e.target.checked)}
                          />
                        </td>
                        <td className="px-6 py-4">
                          <div className="flex items-center gap-3">
                            <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg border border-zinc-200 bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900">
                              <FontAwesomeIcon
                                icon={faNetworkWired}
                                className="h-3.5 w-3.5 text-zinc-400"
                              />
                            </div>
                            <span className="font-mono text-base text-zinc-800 dark:text-zinc-200">
                              {ipBare}
                            </span>
                          </div>
                        </td>
                        <td className="px-6 py-4 font-mono text-sm text-zinc-400 dark:text-zinc-500">
                          {zone}
                        </td>
                        <td className="px-6 py-4">
                          {ptr ? (
                            <span className="font-mono text-sm text-zinc-700 dark:text-zinc-300">
                              {ptr}
                            </span>
                          ) : (
                            <DigiBadge tone="zinc" dot uppercase>
                              Non défini
                            </DigiBadge>
                          )}
                        </td>
                        <td className="px-6 py-4 text-right">
                          <DigiButton
                            type="button"
                            variant="secondary"
                            size="sm"
                            onClick={() => setEditOpen(true)}
                          >
                            <FontAwesomeIcon
                              icon={faPencil}
                              className="h-3.5 w-3.5"
                            />
                            Modifier
                          </DigiButton>
                        </td>
                      </tr>
                    ) : (
                      <tr>
                        <td
                          colSpan={5}
                          className="px-6 py-10 text-center text-sm text-zinc-500"
                        >
                          Aucun PTR à afficher
                        </td>
                      </tr>
                    )}
                  </tbody>
                </table>
              </div>
              <div className="border-t border-zinc-100 px-6 py-3.5 text-xs text-zinc-400 dark:border-zinc-800 dark:text-zinc-500">
                {selected
                  ? "1 ligne(s) sélectionnée(s)."
                  : "Aucune ligne sélectionnée."}
              </div>
            </div>

            <EditPtrModal
              open={editOpen}
              onClose={() => setEditOpen(false)}
              ip={row.ip}
              initial={ptr}
              onSaved={(hostname) =>
                onRowPatched({ ...row, reverse_dns: hostname })
              }
            />
          </Fragment>
        ) : null}

        {tab === "stats" ? (
          <DigiCard>
            <h2 className="text-base font-semibold text-zinc-900 dark:text-zinc-100">
              Statistiques réseau
            </h2>
            <p className="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
              Trafic agrégé pour le préfixe {label}
            </p>
            <div className="mt-8">
              <DigiEmpty
                title="Aucune donnée statistique"
                description="Aucune donnée statistique disponible pour cette période. L’API statistiques Digi n’expose pas encore ces séries pour ce préfixe."
              />
            </div>
          </DigiCard>
        ) : null}

        {tab === "analysis" ? (
          <DigiCard>
            <h2 className="text-base font-semibold text-zinc-900 dark:text-zinc-100">
              Analyse du trafic
            </h2>
            <p className="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
              Trafic applicatif pour {ipBare}
            </p>
            <div className="mt-8">
              <DigiEmpty
                title="Aucune donnée sur la période"
                description="L’analyse détaillée (ports, pairs IP, pays) n’est pas encore disponible via l’API Digi pour ce préfixe."
              />
            </div>
          </DigiCard>
        ) : null}

        {tab === "attacks" ? (
          <DigiCard>
            <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
              <div>
                <h2 className="text-base font-semibold text-zinc-900 dark:text-zinc-100">
                  Historique des attaques
                </h2>
                <p className="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
                  Événements DDoS enregistrés pour {label}
                </p>
              </div>
              <Link
                to="/network/ddos"
                className="text-sm font-semibold text-emerald-700 hover:underline dark:text-emerald-400"
              >
                Voir toutes les attaques
              </Link>
            </div>
            {incidentsLoading ? (
              <div className="flex justify-center py-12">
                <DigiSpinner />
              </div>
            ) : relatedIncidents.length === 0 ? (
              <DigiEmpty
                title="Aucune attaque"
                description="Aucune attaque enregistrée pour cette période."
              />
            ) : (
              <DigiTableWrap>
                <table className="w-full min-w-[720px] text-sm">
                  <thead>
                    <tr className="border-b border-gray-200 bg-gray-50/80 text-left text-xs font-semibold tracking-wide text-gray-500 uppercase dark:border-gray-800 dark:bg-gray-900/30 dark:text-gray-400">
                      <DigiTh>Début</DigiTh>
                      <DigiTh>Fin</DigiTh>
                      <DigiTh>Débit</DigiTh>
                      <DigiTh>PPS</DigiTh>
                      <DigiTh>Statut</DigiTh>
                      <DigiTh className="text-right">Actions</DigiTh>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
                    {relatedIncidents.map((inc) => (
                      <DigiTr key={inc.id}>
                        <DigiTd>
                          {inc.started_at
                            ? new Date(inc.started_at).toLocaleString("fr-FR")
                            : "—"}
                        </DigiTd>
                        <DigiTd>
                          {inc.ended_at
                            ? new Date(inc.ended_at).toLocaleString("fr-FR")
                            : "—"}
                        </DigiTd>
                        <DigiTd>
                          {inc.peak_mbps != null
                            ? `${inc.peak_mbps} Mbps`
                            : "—"}
                        </DigiTd>
                        <DigiTd>
                          {inc.peak_pps != null
                            ? inc.peak_pps.toLocaleString("fr-FR")
                            : "—"}
                        </DigiTd>
                        <DigiTd>
                          <DigiBadge
                            tone={
                              String(inc.status).toLowerCase().includes("actif") ||
                              String(inc.status).toLowerCase() === "active"
                                ? "red"
                                : "zinc"
                            }
                            dot
                            uppercase
                          >
                            {inc.status || "—"}
                          </DigiBadge>
                        </DigiTd>
                        <DigiTd className="text-right">
                          <Link
                            to="/network/ddos"
                            className="text-sm font-semibold text-emerald-700 hover:underline dark:text-emerald-400"
                          >
                            Voir l&apos;attaque
                          </Link>
                        </DigiTd>
                      </DigiTr>
                    ))}
                  </tbody>
                </table>
              </DigiTableWrap>
            )}
          </DigiCard>
        ) : null}
      </div>
    </DigiPage>
  );
}

export function NetworkIpsContainer({
  ipId,
}: {
  /** URL segment after /network/ips/ — when set, show prefix detail */
  ipId?: string;
}) {
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [rows, setRows] = useState<NetworkIpRow[]>([]);
  const [orderOpen, setOrderOpen] = useState(false);
  const [tab, setTab] = useState<PrefixTab>("general");
  const [incidents, setIncidents] = useState<DdosIncidentSummary[]>([]);
  const [incidentsLoading, setIncidentsLoading] = useState(false);

  const selectedIp = decodeIpId(ipId);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await getNetworkIps();
      setRows(Array.isArray(res?.ips) ? res.ips : []);
    } catch (e) {
      setError(
        e instanceof Error
          ? e.message
          : "Impossible de charger les adresses IP.",
      );
      setRows([]);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => {
    if (!selectedIp) return;
    setTab("general");
  }, [selectedIp]);

  useEffect(() => {
    if (!selectedIp || tab !== "attacks") return;
    let cancelled = false;
    (async () => {
      setIncidentsLoading(true);
      try {
        const res = await getDdosIncidents({ limit: 50 });
        if (!cancelled) {
          setIncidents(Array.isArray(res?.incidents) ? res.incidents : []);
        }
      } catch {
        if (!cancelled) setIncidents([]);
      } finally {
        if (!cancelled) setIncidentsLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [selectedIp, tab]);

  const selectedRow = useMemo(() => {
    if (!selectedIp) return null;
    return (
      rows.find(
        (r) =>
          r.ip === selectedIp ||
          bareIp(r.ip) === bareIp(selectedIp) ||
          cidrLabel(r.ip) === selectedIp,
      ) ?? null
    );
  }, [rows, selectedIp]);

  const serviceOptions = useMemo(() => {
    const map = new Map<string, string>();
    for (const r of rows) {
      if (r.service?.id) map.set(r.service.id, r.service.name);
    }
    return [...map.entries()].map(([id, label]) => ({ id, label }));
  }, [rows]);

  if (loading) {
    return (
      <DigiPage>
        <NetworkNavTabs />
        <div className="flex justify-center py-24">
          <DigiSpinner />
        </div>
      </DigiPage>
    );
  }

  if (error) {
    return (
      <DigiPage>
        <NetworkNavTabs />
        <DigiAlert variant="error">{error}</DigiAlert>
        <div className="mt-4">
          <DigiButton type="button" variant="secondary" onClick={() => void load()}>
            Réessayer
          </DigiButton>
        </div>
      </DigiPage>
    );
  }

  if (selectedIp) {
    if (!selectedRow) {
      return (
        <DigiPage>
          <NetworkNavTabs />
          <DigiEmpty
            title="Préfixe introuvable"
            description="Cette adresse IP n’appartient pas à votre compte ou n’est plus disponible."
            action={
              <Link to="/network/ips">
                <DigiButton type="button" variant="secondary">
                  <FontAwesomeIcon icon={faChevronLeft} className="h-3.5 w-3.5" />
                  Retour aux IPs
                </DigiButton>
              </Link>
            }
          />
        </DigiPage>
      );
    }

    return (
      <PrefixDetailView
        row={selectedRow}
        tab={tab}
        onTabChange={setTab}
        incidents={incidents}
        incidentsLoading={incidentsLoading}
        onRowPatched={(next) =>
          setRows((prev) => prev.map((r) => (r.ip === next.ip ? next : r)))
        }
      />
    );
  }

  return (
    <Fragment>
      <IpListView rows={rows} onOrderClick={() => setOrderOpen(true)} />
      <OrderAdditionalIpModal
        open={orderOpen}
        onClose={() => setOrderOpen(false)}
        services={serviceOptions}
      />
    </Fragment>
  );
}
