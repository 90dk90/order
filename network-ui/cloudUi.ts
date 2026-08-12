/** Tokens instance — palette 1vps.cc (emerald / zinc) */
export const CloudUI = {
    /** Page sous le bandeau */
    bg: '#09090b',
    /** Bandeau header instance */
    band: '#050506',
    /** Carte principale */
    surface: '#18181b',
    /** Hover / icônes */
    surfaceHover: '#27272a',
    /** Bordure */
    border: '#27272a',
    borderSubtle: 'rgba(39, 39, 42, 0.85)',
    /** Titres */
    text: '#fafafa',
    /** Corps */
    textSecondary: '#d4d4d8',
    /** Labels */
    textMuted: '#a1a1aa',
    /** Accent emerald 1vps */
    accent: '#10b981',
    accentHover: '#34d399',
    accentMuted: 'rgba(16, 185, 129, 0.14)',
    blue: '#10b981',
    blueMuted: 'rgba(16, 185, 129, 0.12)',
    success: '#34d399',
    danger: '#ef4444',
    warning: '#f59e0b',
    radius: '8px',
    radiusLg: '8px',
    font: "Urbanist, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
    fontMono: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
} as const;

export const cloudPanelStyle = {
    background: CloudUI.surface,
    border: `1px solid ${CloudUI.border}`,
    borderRadius: CloudUI.radiusLg,
    boxShadow: '0 1px 3px 0 rgba(0,0,0,0.35), 0 1px 2px -1px rgba(0,0,0,0.35)',
    fontFamily: CloudUI.font,
} as const;

const COUNTRIES: Record<string, string> = {
    fr: 'France',
    be: 'Belgique',
    de: 'Allemagne',
    nl: 'Pays-Bas',
    uk: 'Royaume-Uni',
    gb: 'Royaume-Uni',
    us: 'États-Unis',
    ca: 'Canada',
    ch: 'Suisse',
    es: 'Espagne',
    it: 'Italie',
    lu: 'Luxembourg',
};

/** Drapeau pays (flagcdn) — fr, be, … */
export const flagUrl = (cc: string) => `https://flagcdn.com/w40/${cc.toLowerCase()}.png`;

/** Extrait le code pays depuis le nom de nœud (fr.magma.srv1 → fr) */
export const countryCodeFromNode = (node: string): string | null => {
    const parts = node.split('.').filter(Boolean);
    if (!parts.length) return null;
    const cc = parts[0].toLowerCase();
    return COUNTRIES[cc] ? cc : null;
};

export const countryLabelFromCode = (cc: string) => COUNTRIES[cc.toLowerCase()] || cc.toUpperCase();
