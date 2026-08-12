import React, { useEffect, useRef, useState } from 'react';
import tw from 'twin.macro';
import { Link } from 'react-router-dom';
import * as Icon from 'react-feather';
import { HMS, hmsCardStyle } from '@/components/hms/hmsTheme';
import { CloudUI } from '@/components/hms/cloudUi';

export const NetworkPage = ({ children }: { children: React.ReactNode }) => (
    <div
        css={tw`w-full mx-auto space-y-4 sm:space-y-6 pb-8`}
        style={{ fontFamily: CloudUI.font, maxWidth: 1400 }}
    >
        {children}
    </div>
);

/** Même échelle que HmsToolPage / reste du panel. */
export const NetworkHeader = ({
    icon: PageIcon,
    title,
    subtitle,
}: {
    icon: typeof Icon.Globe;
    title: string;
    subtitle: string;
}) => (
    <div css={tw`flex items-center sm:items-start gap-3 sm:gap-4`}>
        <div
            css={tw`w-10 h-10 sm:w-12 sm:h-12 rounded-xl sm:rounded-2xl flex items-center justify-center flex-shrink-0`}
            style={{
                background: 'rgba(16, 185, 129, 0.14)',
                color: '#34d399',
                border: '1px solid rgba(16, 185, 129, 0.28)',
            }}
        >
            <PageIcon size={20} strokeWidth={1.75} />
        </div>
        <div css={tw`min-w-0 sm:pt-0.5`}>
            <p
                css={tw`text-xs font-bold m-0 mb-1 uppercase hidden sm:block`}
                style={{ color: CloudUI.textMuted, letterSpacing: '0.14em', fontSize: '0.65rem' }}
            >
                Réseau
            </p>
            <h1 css={tw`text-lg sm:text-2xl font-semibold m-0 tracking-tight`} style={{ color: CloudUI.text }}>
                {title}
            </h1>
            <p
                css={tw`text-sm m-0 mt-2 leading-relaxed max-w-2xl hidden sm:block`}
                style={{ color: CloudUI.textMuted }}
            >
                {subtitle}
            </p>
        </div>
    </div>
);

export const Panel = ({
    children,
    padded = true,
}: {
    children: React.ReactNode;
    padded?: boolean;
}) => (
    <section
        css={[tw`rounded-xl overflow-hidden`, padded ? tw`p-4 sm:p-6 lg:p-8` : tw``]}
        style={hmsCardStyle}
    >
        {children}
    </section>
);

export const PanelHeader = ({
    title,
    description,
    actions,
}: {
    title: string;
    description?: React.ReactNode;
    actions?: React.ReactNode;
}) => (
    <div
        css={tw`flex flex-col gap-3 sm:gap-4 lg:flex-row lg:items-center lg:justify-between pb-4 sm:pb-5 mb-1`}
        style={{ borderBottom: `1px solid ${HMS.cardBorder}` }}
    >
        <div css={tw`min-w-0`}>
            <h2 css={tw`text-base sm:text-lg font-semibold m-0 tracking-tight`} style={{ color: CloudUI.text }}>
                {title}
            </h2>
            {description ? (
                <p css={tw`text-sm m-0 mt-1 leading-relaxed hidden sm:block`} style={{ color: CloudUI.textMuted }}>
                    {description}
                </p>
            ) : null}
        </div>
        {actions ? (
            <div css={tw`flex flex-col sm:flex-row sm:flex-wrap items-stretch sm:items-center gap-2 w-full lg:w-auto flex-shrink-0`}>
                {actions}
            </div>
        ) : null}
    </div>
);

export const StatCard = ({
    label,
    value,
    hint,
    icon,
    tone = 'default',
}: {
    label: string;
    value: string | number;
    hint?: string;
    icon: React.ReactNode;
    tone?: 'default' | 'ok' | 'warn' | 'danger';
}) => {
    const accent =
        tone === 'ok'
            ? CloudUI.success
            : tone === 'warn'
              ? CloudUI.warning
              : tone === 'danger'
                ? CloudUI.danger
                : CloudUI.accent;
    const soft =
        tone === 'ok'
            ? 'rgba(52,211,153,0.12)'
            : tone === 'warn'
              ? 'rgba(245,158,11,0.12)'
              : tone === 'danger'
                ? 'rgba(239,68,68,0.12)'
                : CloudUI.accentMuted;

    return (
        <div css={tw`rounded-xl p-3 sm:p-5 min-w-0`} style={hmsCardStyle}>
            <div css={tw`flex items-center justify-between gap-2 mb-2 sm:mb-3`}>
                <span css={tw`text-xs sm:text-sm font-medium truncate`} style={{ color: CloudUI.textMuted }}>
                    {label}
                </span>
                <span
                    css={tw`inline-flex h-7 w-7 sm:h-9 sm:w-9 items-center justify-center rounded-lg flex-shrink-0`}
                    style={{ background: soft, color: accent }}
                >
                    {icon}
                </span>
            </div>
            <p
                css={tw`text-xl sm:text-2xl lg:text-3xl font-semibold tabular-nums m-0 tracking-tight`}
                style={{ color: CloudUI.text }}
            >
                {value}
            </p>
            {hint ? (
                <p css={tw`text-xs sm:text-sm m-0 mt-1 sm:mt-2 truncate hidden sm:block`} style={{ color: CloudUI.textMuted }}>
                    {hint}
                </p>
            ) : null}
        </div>
    );
};

export const Badge = ({
    children,
    tone = 'neutral',
}: {
    children: React.ReactNode;
    tone?: 'neutral' | 'ok' | 'warn' | 'danger' | 'accent';
}) => {
    const map = {
        neutral: { bg: 'rgba(255,255,255,0.04)', color: CloudUI.textMuted, border: HMS.cardBorder },
        ok: { bg: 'rgba(52,211,153,0.12)', color: CloudUI.success, border: 'rgba(52,211,153,0.25)' },
        warn: { bg: 'rgba(245,158,11,0.12)', color: CloudUI.warning, border: 'rgba(245,158,11,0.25)' },
        danger: { bg: 'rgba(239,68,68,0.12)', color: CloudUI.danger, border: 'rgba(239,68,68,0.25)' },
        accent: { bg: CloudUI.accentMuted, color: CloudUI.accentHover, border: 'rgba(16,185,129,0.25)' },
    }[tone];

    return (
        <span
            css={tw`inline-flex items-center gap-1 px-2.5 py-1 rounded-md text-xs font-medium whitespace-nowrap`}
            style={{ background: map.bg, color: map.color, border: `1px solid ${map.border}` }}
        >
            {children}
        </span>
    );
};

const digiOutlineIdle: React.CSSProperties = {
    background: 'rgba(255,255,255,0.035)',
    color: CloudUI.textSecondary,
    border: `1px solid ${HMS.cardBorder}`,
    boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.03)',
};

const digiOutlineHover: React.CSSProperties = {
    background: CloudUI.accentMuted,
    color: CloudUI.accentHover,
    border: '1px solid rgba(16,185,129,0.38)',
    boxShadow: '0 0 0 1px rgba(16,185,129,0.08), inset 0 1px 0 rgba(255,255,255,0.04)',
};

/** Bouton outline Digi (Modifier PTR, Gérer, etc.) — hover emerald signature. */
export const GhostButton = ({
    children,
    onClick,
    disabled,
    title,
    compact,
}: {
    children: React.ReactNode;
    onClick?: () => void;
    disabled?: boolean;
    title?: string;
    compact?: boolean;
}) => {
    const [hover, setHover] = useState(false);
    const active = hover && !disabled;
    return (
        <button
            type="button"
            title={title}
            disabled={disabled}
            onClick={onClick}
            onMouseEnter={() => setHover(true)}
            onMouseLeave={() => setHover(false)}
            css={[
                tw`inline-flex items-center justify-center gap-2 rounded-lg font-medium border-0 cursor-pointer transition-all disabled:opacity-50 disabled:cursor-not-allowed whitespace-nowrap`,
                compact ? tw`px-2.5 py-1.5 text-xs` : tw`w-full sm:w-auto px-3 py-2.5 text-sm`,
            ]}
            style={{
                ...(active ? digiOutlineHover : digiOutlineIdle),
                minHeight: compact ? 34 : 44,
            }}
        >
            {children}
        </button>
    );
};

/** Lien outline Digi — même langage que GhostButton (ex. Gérer ce préfixe). */
export const GhostLink = ({
    to,
    children,
    compact,
    title,
    fullWidth,
}: {
    to: string;
    children: React.ReactNode;
    compact?: boolean;
    title?: string;
    fullWidth?: boolean;
}) => {
    const [hover, setHover] = useState(false);
    return (
        <Link
            to={to}
            title={title}
            onMouseEnter={() => setHover(true)}
            onMouseLeave={() => setHover(false)}
            css={[
                tw`inline-flex items-center justify-center gap-2 rounded-lg font-medium no-underline transition-all whitespace-nowrap`,
                compact ? tw`px-2.5 py-1.5 text-xs` : tw`px-3 py-2.5 text-sm`,
                fullWidth ? tw`w-full` : tw``,
            ]}
            style={{
                ...(hover ? digiOutlineHover : digiOutlineIdle),
                minHeight: compact ? 34 : 44,
            }}
        >
            {children}
        </Link>
    );
};

export const PrimaryButton = ({
    children,
    onClick,
    disabled,
}: {
    children: React.ReactNode;
    onClick?: () => void;
    disabled?: boolean;
}) => (
    <button
        type="button"
        disabled={disabled}
        onClick={onClick}
        css={tw`w-full sm:w-auto inline-flex items-center justify-center gap-2 px-3 py-2.5 rounded-lg text-sm font-medium border-0 cursor-pointer transition-colors disabled:opacity-50 whitespace-nowrap`}
        style={{ background: CloudUI.accent, color: '#fff', minHeight: 44 }}
    >
        {children}
    </button>
);

export const SegmentedControl = <T extends string>({
    value,
    onChange,
    options,
}: {
    value: T;
    onChange: (v: T) => void;
    options: { id: T; label: string }[];
}) => (
    <div
        css={tw`flex p-1 rounded-xl gap-1 w-full overflow-x-auto`}
        style={{ background: HMS.inputBg, border: `1px solid ${HMS.cardBorder}` }}
        role="tablist"
    >
        {options.map((opt) => {
            const active = value === opt.id;
            return (
                <button
                    key={opt.id}
                    type="button"
                    role="tab"
                    aria-selected={active}
                    onClick={() => onChange(opt.id)}
                    css={tw`flex-1 px-2 sm:px-3 py-2.5 rounded-lg text-xs sm:text-sm font-medium whitespace-nowrap border-0 cursor-pointer transition-colors text-center`}
                    style={{
                        background: active ? CloudUI.accentMuted : 'transparent',
                        color: active ? CloudUI.accentHover : CloudUI.textMuted,
                        boxShadow: active ? 'inset 0 0 0 1px rgba(16,185,129,0.28)' : 'none',
                        minHeight: 44,
                        WebkitTapHighlightColor: 'transparent',
                    }}
                >
                    {opt.label}
                </button>
            );
        })}
    </div>
);

/** Loupe centrée (flex). Pleine largeur sur mobile. */
export const SearchField = ({
    value,
    onChange,
    placeholder,
}: {
    value: string;
    onChange: (v: string) => void;
    placeholder: string;
}) => (
    <div
        css={tw`flex items-center w-full rounded-xl overflow-hidden`}
        style={{
            background: HMS.inputBg,
            border: `1px solid ${HMS.cardBorder}`,
            minHeight: 44,
        }}
    >
        <span css={tw`pl-4 flex items-center flex-shrink-0`} style={{ color: CloudUI.textMuted }}>
            <Icon.Search size={16} />
        </span>
        <input
            value={value}
            onChange={(e) => onChange(e.target.value)}
            placeholder={placeholder}
            css={tw`flex-1 min-w-0 border-0 outline-none bg-transparent px-3 py-3 text-sm`}
            style={{ color: CloudUI.text }}
        />
    </div>
);

/** Select sans flèche native tordue. */
export const SelectField = ({
    value,
    onChange,
    children,
}: {
    value: string;
    onChange: (v: string) => void;
    children: React.ReactNode;
}) => (
    <div css={tw`relative flex items-center w-full sm:w-auto`}>
        <select
            value={value}
            onChange={(e) => onChange(e.target.value)}
            css={tw`w-full rounded-xl py-3 text-sm outline-none cursor-pointer`}
            style={{
                background: HMS.inputBg,
                color: CloudUI.text,
                border: `1px solid ${HMS.cardBorder}`,
                WebkitAppearance: 'none',
                MozAppearance: 'none',
                appearance: 'none',
                paddingLeft: 14,
                paddingRight: 40,
                minHeight: 44,
            }}
        >
            {children}
        </select>
        <Icon.ChevronDown
            size={15}
            css={tw`absolute pointer-events-none`}
            style={{ color: CloudUI.textMuted, right: 12, top: '50%', transform: 'translateY(-50%)' }}
        />
    </div>
);

export const Toolbar = ({ children }: { children: React.ReactNode }) => (
    <div css={tw`flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between lg:gap-4`}>{children}</div>
);

/** Carte liste mobile. */
export const MobileCard = ({
    children,
    onClick,
    accent,
}: {
    children: React.ReactNode;
    onClick?: () => void;
    accent?: string;
}) => (
    <div
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
        css={[tw`rounded-xl p-4 space-y-3`, onClick ? tw`cursor-pointer` : tw``]}
        style={{
            background: HMS.inputBg,
            border: `1px solid ${HMS.cardBorder}`,
            borderLeft: accent ? `3px solid ${accent}` : undefined,
            WebkitTapHighlightColor: 'transparent',
            transition: 'opacity 0.12s ease',
        }}
        onTouchStart={onClick ? (e) => {
            (e.currentTarget as HTMLDivElement).style.opacity = '0.88';
        } : undefined}
        onTouchEnd={onClick ? (e) => {
            (e.currentTarget as HTMLDivElement).style.opacity = '1';
        } : undefined}
        onTouchCancel={onClick ? (e) => {
            (e.currentTarget as HTMLDivElement).style.opacity = '1';
        } : undefined}
    >
        {children}
    </div>
);

export const MobileMetaGrid = ({ items }: { items: { label: string; value: React.ReactNode }[] }) => (
    <div
        css={tw`grid grid-cols-2 gap-3 rounded-lg px-3 py-3`}
        style={{ background: 'rgba(0,0,0,0.22)', border: `1px solid ${HMS.cardBorder}` }}
    >
        {items.map((item) => (
            <div key={item.label} css={tw`min-w-0`}>
                <p
                    css={tw`text-xs uppercase m-0 mb-1 font-semibold`}
                    style={{ color: CloudUI.textMuted, letterSpacing: '0.04em', fontSize: '0.65rem' }}
                >
                    {item.label}
                </p>
                <div css={tw`text-sm leading-snug break-words`} style={{ color: CloudUI.textSecondary }}>
                    {item.value}
                </div>
            </div>
        ))}
    </div>
);

export type ActionsMenuItem = {
    key: string;
    label: string;
    icon?: React.ReactNode;
    disabled?: boolean;
    danger?: boolean;
    href?: string;
    onClick?: () => void;
};

/** Menu d’actions compact (évite le débordement de boutons dans les tableaux). */
export const ActionsMenu = ({ items, label = 'Gérer', fullWidth }: { items: ActionsMenuItem[]; label?: string; fullWidth?: boolean }) => {
    const [open, setOpen] = useState(false);
    const [pos, setPos] = useState<{ top: number; left: number } | null>(null);
    const rootRef = useRef<HTMLDivElement>(null);
    const btnRef = useRef<HTMLButtonElement>(null);
    const menuWidth = 228;

    const place = () => {
        const btn = btnRef.current;
        if (!btn) return;
        const r = btn.getBoundingClientRect();
        let left = fullWidth ? r.left : r.right - menuWidth;
        if (left + menuWidth > window.innerWidth - 8) left = window.innerWidth - menuWidth - 8;
        if (left < 8) left = 8;
        let top = r.bottom + 6;
        const approxH = 48 + items.length * 40;
        if (top + approxH > window.innerHeight - 8) {
            top = Math.max(8, r.top - approxH - 6);
        }
        setPos({ top, left });
    };

    useEffect(() => {
        if (!open) return;
        place();
        const onDoc = (e: Event) => {
            if (!rootRef.current?.contains(e.target as Node)) setOpen(false);
        };
        const onKey = (e: KeyboardEvent) => {
            if (e.key === 'Escape') setOpen(false);
        };
        const onReposition = () => place();
        document.addEventListener('mousedown', onDoc);
        document.addEventListener('touchstart', onDoc, { passive: true });
        document.addEventListener('keydown', onKey);
        window.addEventListener('resize', onReposition);
        window.addEventListener('scroll', onReposition, true);
        return () => {
            document.removeEventListener('mousedown', onDoc);
            document.removeEventListener('touchstart', onDoc);
            document.removeEventListener('keydown', onKey);
            window.removeEventListener('resize', onReposition);
            window.removeEventListener('scroll', onReposition, true);
        };
    }, [open, items.length]);

    return (
        <div ref={rootRef} css={[tw`relative inline-flex justify-end`, fullWidth ? tw`w-full` : tw``]}>
            <button
                ref={btnRef}
                type="button"
                aria-haspopup="menu"
                aria-expanded={open}
                onClick={() => setOpen((v) => !v)}
                css={[
                    tw`inline-flex items-center justify-center gap-2 px-3 py-2.5 rounded-lg text-sm font-medium border-0 cursor-pointer whitespace-nowrap`,
                    fullWidth ? tw`w-full` : tw``,
                ]}
                style={{
                    background: open ? CloudUI.accentMuted : 'rgba(255,255,255,0.04)',
                    color: open ? CloudUI.accentHover : CloudUI.textSecondary,
                    border: `1px solid ${open ? 'rgba(16,185,129,0.28)' : HMS.cardBorder}`,
                    minHeight: 44,
                }}
            >
                {label}
                <Icon.ChevronDown
                    size={14}
                    style={{ transform: open ? 'rotate(180deg)' : undefined, transition: 'transform 0.15s' }}
                />
            </button>
            {open && pos ? (
                <div
                    role="menu"
                    css={tw`fixed z-50 py-1 rounded-xl overflow-hidden`}
                    style={{
                        top: pos.top,
                        left: pos.left,
                        width: fullWidth && btnRef.current ? Math.max(menuWidth, btnRef.current.getBoundingClientRect().width) : menuWidth,
                        background: CloudUI.surface,
                        border: `1px solid ${HMS.cardBorder}`,
                        boxShadow: '0 16px 40px rgba(0,0,0,0.45)',
                    }}
                >
                    {items.map((item) => {
                        const content = (
                            <>
                                <span css={tw`inline-flex w-4 h-4 items-center justify-center flex-shrink-0 opacity-80`}>
                                    {item.icon}
                                </span>
                                <span css={tw`truncate`}>{item.label}</span>
                            </>
                        );
                        const baseCss = tw`w-full flex items-center gap-2 px-4 py-3 text-sm text-left no-underline border-0 cursor-pointer`;
                        const style: React.CSSProperties = {
                            background: 'transparent',
                            color: item.danger ? CloudUI.danger : CloudUI.textSecondary,
                            opacity: item.disabled ? 0.45 : 1,
                            minHeight: 48,
                            WebkitTapHighlightColor: 'transparent',
                        };
                        const hoverIn = (e: React.MouseEvent<HTMLElement>) => {
                            e.currentTarget.style.background = 'rgba(255,255,255,0.04)';
                        };
                        const hoverOut = (e: React.MouseEvent<HTMLElement>) => {
                            e.currentTarget.style.background = 'transparent';
                        };
                        if (item.href && !item.disabled) {
                            return (
                                <Link
                                    key={item.key}
                                    to={item.href}
                                    role="menuitem"
                                    css={baseCss}
                                    style={style}
                                    onClick={() => setOpen(false)}
                                    onMouseEnter={hoverIn}
                                    onMouseLeave={hoverOut}
                                >
                                    {content}
                                </Link>
                            );
                        }
                        return (
                            <button
                                key={item.key}
                                type="button"
                                role="menuitem"
                                disabled={item.disabled}
                                css={baseCss}
                                style={style}
                                onClick={() => {
                                    if (item.disabled) return;
                                    item.onClick?.();
                                    setOpen(false);
                                }}
                                onMouseEnter={hoverIn}
                                onMouseLeave={hoverOut}
                            >
                                {content}
                            </button>
                        );
                    })}
                </div>
            ) : null}
        </div>
    );
};

const thStyle: React.CSSProperties = {
    textAlign: 'left',
    padding: '12px 10px',
    fontSize: '0.68rem',
    fontWeight: 650,
    letterSpacing: '0.06em',
    textTransform: 'uppercase',
    color: CloudUI.textMuted,
    borderBottom: `1px solid ${HMS.cardBorder}`,
    background: 'rgba(0,0,0,0.18)',
    whiteSpace: 'nowrap',
};

const tdStyle: React.CSSProperties = {
    padding: '14px 10px',
    borderBottom: `1px solid ${HMS.cardBorder}`,
    verticalAlign: 'middle',
    overflow: 'hidden',
};

export const DataTable = ({
    headers,
    children,
}: {
    headers: { key: string; label: string; align?: 'left' | 'right'; width?: string }[];
    children: React.ReactNode;
}) => (
    <div css={tw`hidden lg:block w-full overflow-hidden`}>
        <table css={tw`w-full`} style={{ borderCollapse: 'collapse', tableLayout: 'fixed', width: '100%' }}>
            <thead>
                <tr>
                    {headers.map((h) => (
                        <th
                            key={h.key}
                            style={{
                                ...thStyle,
                                textAlign: h.align || 'left',
                                width: h.width,
                            }}
                        >
                            {h.label}
                        </th>
                    ))}
                </tr>
            </thead>
            <tbody>{children}</tbody>
        </table>
    </div>
);

export const Td = ({
    children,
    align,
    accent,
}: {
    children: React.ReactNode;
    align?: 'left' | 'right';
    /** Bordure gauche colorée (historique DDoS). */
    accent?: string;
}) => (
    <td
        style={{
            ...tdStyle,
            textAlign: align || 'left',
            borderLeft: accent ? `3px solid ${accent}` : undefined,
        }}
    >
        {children}
    </td>
);

export const MonoIp = ({ children }: { children: React.ReactNode }) => (
    <code
        css={tw`text-sm sm:text-base font-semibold tracking-tight`}
        style={{ color: CloudUI.text, fontFamily: CloudUI.fontMono }}
    >
        {children}
    </code>
);

export const MetaLine = ({ children }: { children: React.ReactNode }) => (
    <p css={tw`text-sm m-0 mt-1 leading-snug`} style={{ color: CloudUI.textMuted }}>
        {children}
    </p>
);

export const EmptyState = ({
    icon,
    title,
    description,
}: {
    icon: React.ReactNode;
    title: string;
    description: string;
}) => (
    <div css={tw`px-5 sm:px-8 py-12 sm:py-16 text-center`}>
        <div css={tw`mx-auto mb-3 sm:mb-4 opacity-40 flex justify-center`} style={{ color: CloudUI.textMuted }}>
            {icon}
        </div>
        <p css={tw`m-0 text-base sm:text-lg font-semibold`} style={{ color: CloudUI.text }}>
            {title}
        </p>
        <p css={tw`m-0 mt-2 text-sm max-w-md mx-auto leading-relaxed`} style={{ color: CloudUI.textMuted }}>
            {description}
        </p>
    </div>
);

export const copyText = async (value: string) => {
    try {
        await navigator.clipboard.writeText(value);
        return true;
    } catch {
        return false;
    }
};

export const formatWhen = (iso?: string | null) => {
    if (!iso) return '—';
    try {
        return new Date(iso).toLocaleString('fr-FR', {
            day: '2-digit',
            month: 'short',
            hour: '2-digit',
            minute: '2-digit',
        });
    } catch {
        return iso;
    }
};

export const durationMin = (start?: string, stop?: string | null) => {
    if (!start || !stop) return null;
    const a = Date.parse(start);
    const b = Date.parse(stop);
    if (!Number.isFinite(a) || !Number.isFinite(b) || b < a) return null;
    return Math.max(1, Math.round((b - a) / 60000));
};

export const severityOfBps = (bps?: number): 'ok' | 'warn' | 'danger' => {
    if (!bps || bps < 5e8) return 'ok';
    if (bps < 3e9) return 'warn';
    return 'danger';
};
