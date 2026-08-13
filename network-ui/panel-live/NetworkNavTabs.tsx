import React from 'react';
import tw from 'twin.macro';
import { Link, useLocation } from 'react-router-dom';
import * as Icon from 'react-feather';
import { HMS } from '@/components/hms/hmsTheme';
import { CloudUI } from '@/components/hms/cloudUi';

type TabId = 'ips' | 'ddos';

const tabs: {
    id: TabId;
    shortLabel: string;
    label: string;
    to: string;
    icon: React.ReactNode;
}[] = [
    { id: 'ips', shortLabel: 'IPs', label: 'Adresse IP', to: '/network/ips', icon: <Icon.Globe size={16} /> },
    { id: 'ddos', shortLabel: 'DDoS', label: 'Attaque DDoS', to: '/network/ddos', icon: <Icon.Shield size={16} /> },
];

export default ({ active }: { active: TabId }) => {
    const location = useLocation();

    return (
        <div
            css={tw`flex p-1 rounded-xl gap-1 w-full sm:w-auto sm:inline-flex`}
            style={{ background: HMS.inputBg, border: `1px solid ${HMS.cardBorder}` }}
            role="tablist"
            aria-label="Sections réseau"
        >
            {tabs.map((tab) => {
                const isActive =
                    active === tab.id ||
                    location.pathname === tab.to ||
                    (tab.id === 'ips' && location.pathname.startsWith('/network/ips/'));
                return (
                    <Link
                        key={tab.id}
                        to={tab.to}
                        role="tab"
                        aria-selected={isActive}
                        css={tw`flex-1 sm:flex-none inline-flex items-center justify-center gap-2 px-3 sm:px-5 py-2.5 rounded-lg text-sm font-semibold no-underline`}
                        style={{
                            background: isActive ? CloudUI.accentMuted : 'transparent',
                            color: isActive ? CloudUI.accentHover : CloudUI.textMuted,
                            boxShadow: isActive ? 'inset 0 0 0 1px rgba(16,185,129,0.28)' : 'none',
                            minHeight: 42,
                            WebkitTapHighlightColor: 'transparent',
                        }}
                    >
                        {tab.icon}
                        <span css={tw`sm:hidden`}>{tab.shortLabel}</span>
                        <span css={tw`hidden sm:inline`}>{tab.label}</span>
                    </Link>
                );
            })}
        </div>
    );
};
