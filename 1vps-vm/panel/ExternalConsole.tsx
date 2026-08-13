import tw from 'twin.macro';
import * as Icon from 'react-feather';
import React, { memo, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import isEqual from 'react-fast-compare';
import Features from '@feature/Features';
import { useLocation } from 'react-router-dom';
import { ServerContext } from '@/state/server';
import Spinner from '@/components/elements/Spinner';
import Console from '@/components/server/console/Console';
import ErrorBoundary from '@/components/elements/ErrorBoundary';
import FlashMessageRender from '@/components/FlashMessageRender';
import PowerButtons from '@/components/server/console/PowerButtons';
import { CloudUI, cloudPanelStyle } from '@/components/hms/cloudUi';
import styled from 'styled-components/macro';
import http from '@/api/http';

type ConsoleTab = 'serial' | 'graphic';

type NoVncInfo = {
    mode: string;
    available: boolean;
    ip: string | null;
    direct_url: string | null;
    embed_url: string | null;
};

const statusMeta = (status: string | null) => {
    switch (status) {
        case 'running':
            return { label: 'En ligne', color: CloudUI.success };
        case 'starting':
            return { label: 'Démarrage', color: CloudUI.warning };
        case 'stopping':
            return { label: 'Arrêt', color: CloudUI.warning };
        case 'offline':
            return { label: 'Hors ligne', color: CloudUI.danger };
        default:
            return { label: status || '…', color: CloudUI.textMuted };
    }
};

const Toolbar = styled.div`
    display: flex;
    flex-direction: column;
    gap: 0.65rem;
    padding: 0.75rem 0.85rem;
    border-bottom: 1px solid ${CloudUI.border};
    background: ${CloudUI.surface};
    flex-shrink: 0;

    @media (min-width: 640px) {
        flex-direction: row;
        flex-wrap: wrap;
        align-items: center;
        gap: 0.75rem;
        padding: 0.75rem 1rem;
    }
`;

const TitleRow = styled.div`
    display: flex;
    align-items: center;
    gap: 0.5rem;
    min-width: 0;
    width: 100%;

    @media (min-width: 640px) {
        width: auto;
        flex: 1 1 auto;
    }
`;

const ActionsRow = styled.div`
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 0.45rem;
    width: 100%;

    @media (min-width: 640px) {
        width: auto;
        flex: 0 0 auto;
        justify-content: flex-end;
    }
`;

const TabBar = styled.div`
    display: flex;
    gap: 0.35rem;
    padding: 0.45rem 0.85rem;
    border-bottom: 1px solid ${CloudUI.border};
    background: ${CloudUI.surface};
    flex-shrink: 0;
`;

const TabBtn = styled.button<{ $active?: boolean }>`
    appearance: none;
    border: 1px solid ${(p) => (p.$active ? '#4b5563' : CloudUI.border)};
    background: ${(p) => (p.$active ? CloudUI.surfaceHover : 'transparent')};
    color: ${(p) => (p.$active ? CloudUI.text : CloudUI.textSecondary)};
    border-radius: 0.5rem;
    padding: 0.35rem 0.75rem;
    font-size: 0.75rem;
    font-weight: 600;
    cursor: pointer;
    min-height: 2rem;
`;

const ToolBtn = ({
    onClick,
    children,
    title,
    className,
    disabled,
}: {
    onClick: () => void;
    children: React.ReactNode;
    title?: string;
    className?: string;
    disabled?: boolean;
}) => (
    <button
        type="button"
        onClick={onClick}
        title={title}
        disabled={disabled}
        className={className}
        css={tw`inline-flex items-center justify-center gap-1.5 rounded-lg px-2.5 py-1.5 text-xs font-medium border-0 cursor-pointer transition-colors flex-1 sm:flex-none disabled:opacity-50 disabled:cursor-not-allowed`}
        style={{
            background: CloudUI.surfaceHover,
            color: CloudUI.textSecondary,
            border: `1px solid ${CloudUI.border}`,
            minHeight: '2.25rem',
        }}
        onMouseEnter={(e) => {
            if (disabled) return;
            e.currentTarget.style.color = CloudUI.text;
            e.currentTarget.style.borderColor = '#4b5563';
        }}
        onMouseLeave={(e) => {
            e.currentTarget.style.color = CloudUI.textSecondary;
            e.currentTarget.style.borderColor = CloudUI.border;
        }}
    >
        {children}
    </button>
);

const Label = styled.span`
    @media (max-width: 379px) {
        display: none;
    }
`;

const ExternalConsole = () => {
    const location = useLocation();
    const standalone = useMemo(
        () => new URLSearchParams(location.search).get('standalone') === '1',
        [location.search]
    );
    const eggFeatures = ServerContext.useStoreState((s) => s.server.data?.eggFeatures || [], isEqual);
    const serverName = ServerContext.useStoreState((s) => s.server.data?.name) || 'Instance';
    const uuid = ServerContext.useStoreState((s) => s.server.data?.uuid);
    const variables = ServerContext.useStoreState((s) => s.server.data?.variables || [], isEqual);
    const status = ServerContext.useStoreState((s) => s.status.value);
    const connected = ServerContext.useStoreState((s) => s.socket.connected);
    const instance = ServerContext.useStoreState((s) => s.socket.instance);
    const setServerStatus = ServerContext.useStoreActions((a) => a.status.setServerStatus);
    const consoleWrapperRef = useRef<HTMLDivElement>(null);
    const [isFullscreen, setIsFullscreen] = useState(false);
    const [tab, setTab] = useState<ConsoleTab>('serial');
    const [novnc, setNovnc] = useState<NoVncInfo | null>(null);
    const [novncError, setNovncError] = useState<string | null>(null);

    const displayMode = useMemo(() => {
        const v = variables.find((x) => x.envVariable === 'DISPLAY_MODE' || (x as any).env_variable === 'DISPLAY_MODE');
        const raw = (v as any)?.serverValue ?? (v as any)?.server_value ?? (v as any)?.value ?? '';
        return String(raw).toLowerCase();
    }, [variables]);

    const graphicEnabled = displayMode === 'novnc' || displayMode === 'vnc';

    useEffect(() => {
        document.title = standalone ? `Console — ${serverName}` : 'Console';
        if (!standalone) {
            return;
        }
        document.body.style.overflow = 'hidden';
        return () => {
            document.body.style.overflow = '';
        };
    }, [standalone, serverName]);

    useEffect(() => {
        const onFullscreenChange = () => {
            setIsFullscreen(document.fullscreenElement === consoleWrapperRef.current);
            window.dispatchEvent(new Event('resize'));
        };
        document.addEventListener('fullscreenchange', onFullscreenChange);
        return () => document.removeEventListener('fullscreenchange', onFullscreenChange);
    }, []);

    useEffect(() => {
        if (!graphicEnabled || !uuid) {
            setNovnc(null);
            return;
        }
        let cancelled = false;
        setNovncError(null);
        http.get(`/api/client/servers/${uuid}/novnc`)
            .then(({ data }) => {
                if (!cancelled) setNovnc(data as NoVncInfo);
            })
            .catch(() => {
                if (!cancelled) setNovncError('Impossible de résoudre l’URL noVNC.');
            });
        return () => {
            cancelled = true;
        };
    }, [graphicEnabled, uuid, status]);

    useEffect(() => {
        if (graphicEnabled && displayMode === 'novnc' && status === 'running') {
            setTab('graphic');
        }
    }, [graphicEnabled, displayMode, status]);

    const onClearConsole = useCallback(() => window.dispatchEvent(new Event('console:clear')), []);
    const onSearch = useCallback(() => window.dispatchEvent(new Event('console:search')), []);
    const onShare = useCallback(() => window.dispatchEvent(new Event('console:share')), []);
    const onHistory = useCallback(() => window.dispatchEvent(new Event('console:history')), []);
    const onFullscreen = useCallback(() => {
        const wrapper = consoleWrapperRef.current;
        if (!wrapper) return;
        if (!document.fullscreenElement) wrapper.requestFullscreen().catch(() => undefined);
        else document.exitFullscreen().catch(() => undefined);
    }, []);
    const onCtrlDel = useCallback(() => {
        if (!instance) return;
        setServerStatus('starting');
        instance.send('set state', 'restart');
    }, [instance, setServerStatus]);
    const openGraphic = useCallback(() => {
        const url = novnc?.embed_url || novnc?.direct_url;
        if (url) window.open(url, '_blank', 'noopener,noreferrer');
    }, [novnc]);

    useEffect(() => {
        const onKeyDown = (e: KeyboardEvent) => {
            if (e.ctrlKey && (e.key === 'Delete' || e.key === 'Del' || e.code === 'Delete')) {
                e.preventDefault();
                onCtrlDel();
            }
        };
        window.addEventListener('keydown', onKeyDown);
        return () => window.removeEventListener('keydown', onKeyDown);
    }, [onCtrlDel]);

    const meta = statusMeta(status);
    const embedSrc = novnc?.embed_url || null;

    return (
        <div
            css={standalone ? tw`w-full h-screen flex flex-col overflow-hidden` : tw`w-full`}
            style={{ fontFamily: CloudUI.font }}
        >
            <FlashMessageRender byKey={'server:console'} />
            <FlashMessageRender byKey={'console:share'} />

            <div
                ref={consoleWrapperRef}
                css={tw`overflow-hidden flex flex-col`}
                style={{
                    ...cloudPanelStyle,
                    background: '#0b1220',
                    height: standalone || isFullscreen ? '100vh' : 'clamp(28rem, 72vh, 58rem)',
                    borderRadius: standalone ? 0 : cloudPanelStyle.borderRadius,
                    border: standalone ? 'none' : cloudPanelStyle.border,
                    flex: standalone ? 1 : undefined,
                }}
            >
                <Toolbar>
                    <TitleRow>
                        <div css={tw`flex items-center gap-1.5 flex-shrink-0`}>
                            <span css={tw`w-2.5 h-2.5 rounded-full`} style={{ background: '#ef4444' }} />
                            <span css={tw`w-2.5 h-2.5 rounded-full`} style={{ background: '#eab308' }} />
                            <span css={tw`w-2.5 h-2.5 rounded-full`} style={{ background: '#22c55e' }} />
                        </div>
                        <span css={tw`text-sm font-medium truncate ml-1 min-w-0`} style={{ color: CloudUI.text }}>
                            Console — {serverName}
                        </span>
                        <span
                            css={tw`inline-flex items-center gap-1.5 ml-1 px-2 py-0.5 rounded-md text-[11px] font-medium flex-shrink-0`}
                            style={{ background: `${meta.color}22`, color: meta.color }}
                        >
                            <span css={tw`w-1.5 h-1.5 rounded-full`} style={{ background: meta.color }} />
                            {meta.label}
                        </span>
                        <span
                            css={tw`hidden sm:inline-flex items-center gap-1 text-[11px] ml-1 flex-shrink-0`}
                            style={{ color: connected ? CloudUI.success : CloudUI.textMuted }}
                        >
                            <span
                                css={tw`w-1.5 h-1.5 rounded-full`}
                                style={{ background: connected ? CloudUI.success : CloudUI.textMuted }}
                            />
                            {connected ? 'Connecté' : 'Connexion…'}
                        </span>
                    </TitleRow>

                    <ActionsRow>
                        {tab === 'serial' && (
                            <>
                                <ToolBtn onClick={onSearch} title="Rechercher dans les logs (Ctrl+F)">
                                    <Icon.Search size={13} />
                                    <Label>Chercher</Label>
                                </ToolBtn>
                                <ToolBtn onClick={onShare} title="Uploader les logs (mclo.gs)" disabled={!connected}>
                                    <Icon.Upload size={13} />
                                    <Label>Partager</Label>
                                </ToolBtn>
                                <ToolBtn onClick={onHistory} title="Historique des commandes">
                                    <Icon.Clock size={13} />
                                    <Label>Historique</Label>
                                </ToolBtn>
                                <ToolBtn onClick={onClearConsole} title="Effacer la console">
                                    <Icon.Trash2 size={13} />
                                    <Label>Effacer</Label>
                                </ToolBtn>
                            </>
                        )}
                        {tab === 'graphic' && (
                            <ToolBtn onClick={openGraphic} title="Ouvrir noVNC dans un nouvel onglet" disabled={!novnc}>
                                <Icon.ExternalLink size={13} />
                                <Label>Ouvrir</Label>
                            </ToolBtn>
                        )}
                        {!standalone && (
                            <ToolBtn onClick={onFullscreen} title="Plein écran">
                                {isFullscreen ? <Icon.Minimize2 size={13} /> : <Icon.Maximize2 size={13} />}
                                <Label>{isFullscreen ? 'Quitter' : 'Plein écran'}</Label>
                            </ToolBtn>
                        )}
                        <div css={tw`flex items-center ml-auto sm:ml-1`}>
                            <PowerButtons compact />
                        </div>
                    </ActionsRow>
                </Toolbar>

                {graphicEnabled && (
                    <TabBar>
                        <TabBtn type="button" $active={tab === 'serial'} onClick={() => setTab('serial')}>
                            Série
                        </TabBtn>
                        <TabBtn type="button" $active={tab === 'graphic'} onClick={() => setTab('graphic')}>
                            Graphique (noVNC)
                        </TabBtn>
                    </TabBar>
                )}

                <div css={tw`relative flex-1 min-h-0`}>
                    {tab === 'serial' || !graphicEnabled ? (
                        <Spinner.Suspense>
                            <ErrorBoundary>
                                <Console />
                            </ErrorBoundary>
                        </Spinner.Suspense>
                    ) : (
                        <div css={tw`absolute inset-0 flex flex-col bg-black`}>
                            {novncError && (
                                <div css={tw`p-3 text-sm`} style={{ color: CloudUI.danger }}>
                                    {novncError}
                                </div>
                            )}
                            {!embedSrc && !novncError && (
                                <div css={tw`flex-1 flex items-center justify-center`} style={{ color: CloudUI.textMuted }}>
                                    <Spinner size="large" centered />
                                </div>
                            )}
                            {embedSrc && (
                                <iframe
                                    title="noVNC"
                                    src={embedSrc}
                                    css={tw`w-full h-full border-0 flex-1`}
                                    allow="clipboard-read; clipboard-write; fullscreen"
                                />
                            )}
                            {novnc && !novnc.available && (
                                <div css={tw`p-3 text-xs`} style={{ color: CloudUI.textMuted }}>
                                    DISPLAY_MODE={novnc.mode}. Passez sur « novnc » et redémarrez pour la console graphique.
                                </div>
                            )}
                        </div>
                    )}
                </div>
            </div>

            {!standalone && eggFeatures && eggFeatures.length > 0 && (
                <div css={tw`mt-4`}>
                    <Features enabled={eggFeatures} />
                </div>
            )}
        </div>
    );
};

export default memo(ExternalConsole, isEqual);
