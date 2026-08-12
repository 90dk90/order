import React from 'react';
import tw from 'twin.macro';
import { useLocation } from 'react-router';
import HmsPanelShell from '@/components/hms/HmsPanelShell';
import { NotFound } from '@/components/elements/ScreenBlock';
import { Route, Switch, Redirect } from 'react-router-dom';
import NetworkIpsContainer from '@/components/network/NetworkIpsContainer';
import NetworkIpDetailContainer from '@/components/network/NetworkIpDetailContainer';
import NetworkDdosContainer from '@/components/network/NetworkDdosContainer';

export default () => {
    const location = useLocation();

    return (
        <HmsPanelShell>
            <div css={tw`min-h-[60vh] w-full`}>
                <Switch location={location}>
                    <Route path={'/network/ips'} exact component={NetworkIpsContainer} />
                    <Route path={'/network/ips/:ipId'} exact component={NetworkIpDetailContainer} />
                    <Route path={'/network/ddos'} exact component={NetworkDdosContainer} />
                    <Route path={'/network'} exact>
                        <Redirect to="/network/ips" />
                    </Route>
                    <Route path={'*'} component={NotFound} />
                </Switch>
            </div>
        </HmsPanelShell>
    );
};
