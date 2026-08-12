import React, { useEffect } from "react";
import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import { faTimes, faSpinner } from "@fortawesome/free-solid-svg-icons";

/** Digi brand tones (emerald primary — not Infrawire blue). */
export type DigiTone = "emerald" | "amber" | "red" | "zinc" | "sky";

const toneBadge: Record<DigiTone, string> = {
  emerald:
    "border-emerald-200 bg-emerald-50 text-emerald-800 dark:border-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-300",
  amber:
    "border-amber-200 bg-amber-50 text-amber-800 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-300",
  red: "border-red-200 bg-red-50 text-red-800 dark:border-red-800 dark:bg-red-950/40 dark:text-red-300",
  zinc: "border-zinc-200 bg-zinc-50 text-zinc-700 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  sky: "border-sky-200 bg-sky-50 text-sky-800 dark:border-sky-800 dark:bg-sky-950/40 dark:text-sky-300",
};

const toneAlert: Record<DigiTone, string> = {
  emerald:
    "border-emerald-200 bg-emerald-50 text-emerald-900 dark:border-emerald-800 dark:bg-emerald-950/30 dark:text-emerald-100",
  amber:
    "border-amber-200 bg-amber-50 text-amber-900 dark:border-amber-800 dark:bg-amber-950/30 dark:text-amber-100",
  red: "border-red-200 bg-red-50 text-red-900 dark:border-red-800 dark:bg-red-950/30 dark:text-red-100",
  zinc: "border-zinc-200 bg-zinc-50 text-zinc-800 dark:border-zinc-700 dark:bg-zinc-900/40 dark:text-zinc-100",
  sky: "border-sky-200 bg-sky-50 text-sky-900 dark:border-sky-800 dark:bg-sky-950/30 dark:text-sky-100",
};

export function DigiBadge({
  tone = "zinc",
  children,
  className = "",
  dot = false,
  uppercase = false,
}: {
  tone?: DigiTone;
  children: React.ReactNode;
  className?: string;
  /** Status pill with leading color dot (Infrawire-style). */
  dot?: boolean;
  uppercase?: boolean;
}) {
  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-[11px] font-semibold ${
        uppercase ? "tracking-wide uppercase" : ""
      } ${toneBadge[tone]} ${className}`}
    >
      {dot ? (
        <span
          className="h-1.5 w-1.5 shrink-0 rounded-full bg-current opacity-90"
          aria-hidden
        />
      ) : null}
      {children}
    </span>
  );
}

const alertVariantTone: Record<string, DigiTone> = {
  success: "emerald",
  warning: "amber",
  error: "red",
  danger: "red",
  info: "sky",
  neutral: "zinc",
};

export function DigiAlert({
  tone,
  variant,
  title,
  children,
  className = "",
}: {
  tone?: DigiTone;
  /** Alias used by callers (`warning` / `error` / `info`). */
  variant?: "success" | "warning" | "error" | "danger" | "info" | "neutral";
  title?: string;
  children?: React.ReactNode;
  className?: string;
}) {
  const resolved: DigiTone =
    tone ?? (variant ? alertVariantTone[variant] ?? "zinc" : "zinc");
  return (
    <div className={`rounded-xl border px-4 py-3 text-sm ${toneAlert[resolved]} ${className}`}>
      {title ? <div className="font-semibold">{title}</div> : null}
      {children ? <div className={title ? "mt-1 opacity-90" : ""}>{children}</div> : null}
    </div>
  );
}

export function DigiSpinner({ label }: { label?: string }) {
  return (
    <div className="flex items-center justify-center gap-2 py-10 text-sm text-zinc-500 dark:text-zinc-400">
      <FontAwesomeIcon icon={faSpinner} className="animate-spin text-emerald-600" />
      {label ? <span>{label}</span> : null}
    </div>
  );
}

export function DigiEmpty({
  title,
  description,
  action,
}: {
  title: string;
  description?: string;
  action?: React.ReactNode;
}) {
  return (
    <div className="flex flex-col items-center justify-center gap-2 px-4 py-12 text-center">
      <p className="text-sm font-semibold text-zinc-800 dark:text-zinc-100">{title}</p>
      {description ? (
        <p className="max-w-md text-sm text-zinc-500 dark:text-zinc-400">{description}</p>
      ) : null}
      {action ? <div className="mt-2">{action}</div> : null}
    </div>
  );
}

export function DigiButton({
  children,
  variant = "primary",
  size = "md",
  disabled,
  loading,
  type = "button",
  onClick,
  className = "",
  title,
}: {
  children: React.ReactNode;
  variant?: "primary" | "secondary" | "ghost" | "danger";
  size?: "sm" | "md";
  disabled?: boolean;
  loading?: boolean;
  type?: "button" | "submit" | "reset";
  onClick?: () => void;
  className?: string;
  title?: string;
}) {
  const sizes = size === "sm" ? "px-3 py-1.5 text-xs" : "px-4 py-2 text-sm";
  const variants: Record<string, string> = {
    primary:
      "bg-emerald-600 text-white hover:bg-emerald-500 focus-visible:ring-emerald-500/40 disabled:bg-emerald-600/50",
    secondary:
      "border border-zinc-200 bg-white text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100 dark:hover:bg-zinc-800",
    ghost:
      "bg-transparent text-zinc-700 hover:bg-zinc-100 dark:text-zinc-200 dark:hover:bg-zinc-800",
    danger:
      "bg-red-600 text-white hover:bg-red-500 focus-visible:ring-red-500/40 disabled:bg-red-600/50",
  };
  return (
    <button
      type={type}
      title={title}
      disabled={disabled || loading}
      onClick={onClick}
      className={`inline-flex items-center justify-center gap-2 rounded-lg font-semibold transition focus:outline-none focus-visible:ring-2 disabled:cursor-not-allowed ${sizes} ${variants[variant]} ${className}`}
    >
      {loading ? <FontAwesomeIcon icon={faSpinner} className="animate-spin" /> : null}
      {children}
    </button>
  );
}

export function DigiInput({
  label,
  value,
  onChange,
  placeholder,
  type = "text",
  className = "",
  disabled,
  min,
  max,
}: {
  label?: string;
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  type?: string;
  className?: string;
  disabled?: boolean;
  min?: number;
  max?: number;
}) {
  return (
    <label className={`block ${className}`}>
      {label ? (
        <span className="mb-1.5 block text-xs font-semibold text-zinc-600 dark:text-zinc-300">
          {label}
        </span>
      ) : null}
      <input
        type={type}
        value={value}
        disabled={disabled}
        placeholder={placeholder}
        min={min}
        max={max}
        onChange={(e) => onChange(e.target.value)}
        className="w-full rounded-lg border border-zinc-200 bg-white px-3 py-2 text-sm text-zinc-900 outline-none transition focus:border-emerald-500 focus:ring-2 focus:ring-emerald-500/20 disabled:opacity-60 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100"
      />
    </label>
  );
}

export function DigiModal({
  open,
  onClose,
  title,
  description,
  children,
  footer,
  size = "md",
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  description?: string;
  children: React.ReactNode;
  footer?: React.ReactNode;
  size?: "sm" | "md" | "lg" | "xl";
}) {
  useEffect(() => {
    if (!open) return undefined;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, onClose]);

  if (!open) return null;

  const maxW =
    size === "sm"
      ? "max-w-md"
      : size === "lg"
        ? "max-w-3xl"
        : size === "xl"
          ? "max-w-5xl"
          : "max-w-xl";

  return (
    <div className="fixed inset-0 z-[80] flex items-center justify-center p-4">
      <button
        type="button"
        aria-label="Fermer"
        className="absolute inset-0 bg-zinc-950/50 backdrop-blur-[1px]"
        onClick={onClose}
      />
      <div
        role="dialog"
        aria-modal="true"
        className={`relative z-10 flex max-h-[90vh] w-full ${maxW} flex-col overflow-hidden rounded-2xl border border-zinc-200 bg-white shadow-xl dark:border-zinc-700 dark:bg-zinc-900`}
      >
        <div className="flex items-start justify-between gap-3 border-b border-zinc-100 px-5 py-4 dark:border-zinc-800">
          <div className="min-w-0">
            <h2 className="text-base font-semibold text-zinc-900 dark:text-zinc-50">{title}</h2>
            {description ? (
              <p className="mt-1 text-sm text-zinc-500 dark:text-zinc-400">{description}</p>
            ) : null}
          </div>
          <button
            type="button"
            onClick={onClose}
            className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-lg text-zinc-500 hover:bg-zinc-100 hover:text-zinc-800 dark:hover:bg-zinc-800 dark:hover:text-zinc-100"
            aria-label="Fermer"
          >
            <FontAwesomeIcon icon={faTimes} />
          </button>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto px-5 py-4">{children}</div>
        {footer ? (
          <div className="border-t border-zinc-100 px-5 py-4 dark:border-zinc-800">{footer}</div>
        ) : null}
      </div>
    </div>
  );
}

export function DigiPage({
  title,
  description,
  icon,
  actions,
  children,
  className = "",
}: {
  title?: string;
  description?: string;
  icon?: React.ReactNode;
  actions?: React.ReactNode;
  children: React.ReactNode;
  className?: string;
}) {
  const showHeader = Boolean(title || description || icon || actions);
  return (
    <div className={`space-y-6 ${className}`}>
      {showHeader ? (
        <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-3">
              {icon ? (
                <span className="inline-flex shrink-0 items-center justify-center text-emerald-700 dark:text-emerald-300">
                  {icon}
                </span>
              ) : null}
              {title ? (
                <h1 className="text-2xl font-semibold tracking-tight text-zinc-900 sm:text-3xl dark:text-zinc-100">
                  {title}
                </h1>
              ) : null}
            </div>
            {description ? (
              <p className="mt-1.5 text-base text-zinc-600 dark:text-zinc-300">{description}</p>
            ) : null}
          </div>
          {actions ? (
            <div className="flex shrink-0 flex-wrap items-center gap-2">{actions}</div>
          ) : null}
        </div>
      ) : null}
      {children}
    </div>
  );
}

export function DigiCard({
  title,
  description,
  children,
  className = "",
  padding = true,
  compact,
}: {
  title?: string;
  description?: string;
  children: React.ReactNode;
  className?: string;
  padding?: boolean;
  compact?: boolean;
}) {
  return (
    <div
      className={`overflow-hidden rounded-xl border border-zinc-200 bg-white shadow-sm dark:border-zinc-800 dark:bg-zinc-950/40 ${className}`}
    >
      {title || description ? (
        <div className={`border-b border-zinc-100 dark:border-zinc-800 ${compact ? "px-4 py-3" : "px-5 py-4"}`}>
          {title ? (
            <h2 className="text-sm font-semibold text-zinc-900 dark:text-zinc-100">{title}</h2>
          ) : null}
          {description ? (
            <p className="mt-0.5 text-xs text-zinc-500 dark:text-zinc-400">{description}</p>
          ) : null}
        </div>
      ) : null}
      <div className={padding ? (compact ? "p-4" : "p-5") : ""}>{children}</div>
    </div>
  );
}

export function DigiTableWrap({
  children,
  className = "",
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <div
      className={`overflow-hidden rounded-xl border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-950/40 ${className}`}
    >
      <div className="overflow-x-auto">{children}</div>
    </div>
  );
}

export function DigiTh({
  children,
  className = "",
  align = "left",
}: {
  children?: React.ReactNode;
  className?: string;
  align?: "left" | "right" | "center";
}) {
  const a = align === "right" ? "text-right" : align === "center" ? "text-center" : "text-left";
  return (
    <th
      className={`px-4 py-3 text-xs font-semibold tracking-[0.08em] text-zinc-500 uppercase dark:text-zinc-400 ${a} ${className}`}
    >
      {children}
    </th>
  );
}

export function DigiTd({
  children,
  className = "",
  align = "left",
}: {
  children?: React.ReactNode;
  className?: string;
  align?: "left" | "right" | "center";
}) {
  const a = align === "right" ? "text-right" : align === "center" ? "text-center" : "text-left";
  return <td className={`px-4 py-3.5 align-middle ${a} ${className}`}>{children}</td>;
}

export function DigiTr({
  children,
  className = "",
  onClick,
}: {
  children: React.ReactNode;
  className?: string;
  onClick?: () => void;
}) {
  return (
    <tr
      onClick={onClick}
      className={`border-b border-zinc-100 last:border-0 dark:border-zinc-800 ${
        onClick ? "cursor-pointer hover:bg-zinc-50/80 dark:hover:bg-zinc-900/40" : ""
      } ${className}`}
    >
      {children}
    </tr>
  );
}
