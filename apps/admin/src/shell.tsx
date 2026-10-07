import React from 'react';
import { environment } from './backend';

export function Brand() { return <div className="brand"><span className="brand-symbol" aria-hidden="true">▤</span><span>Gradstep</span></div>; }

// The signed-in frame: sidebar navigation and the page header. Shared with the
// development-only fixtures so screenshots show the real arrangement.
export function Shell({ tabs, tab, onTab, counts, email, onSignOut, loading, onRefresh, children }: {
  tabs: string[]; tab: string; onTab: (tab: string) => void; counts?: Record<string, number | undefined>;
  email: string; onSignOut: () => void; loading: boolean; onRefresh: () => void; children: React.ReactNode;
}) {
  return <div className="app-shell">
    <aside>
      <Brand />
      <span className="environment">{environment}</span>
      <nav aria-label="Administration">
        {tabs.map(item => <button key={item} aria-current={tab === item ? 'page' : undefined} className={tab === item ? 'selected' : ''} onClick={() => onTab(item)}>{item}{counts?.[item] ? <span className="count">{counts[item]}</span> : null}</button>)}
      </nav>
      <div className="sidebar-bottom"><span>{email}</span><button className="quiet" onClick={onSignOut}>Sign out</button></div>
    </aside>
    <main>
      <header><div><p className="eyebrow">GRADSTEP / ADMINISTRATION</p><h1>{tab}</h1></div><button className="secondary" disabled={loading} onClick={onRefresh}>{loading ? 'Refreshing…' : 'Refresh'}</button></header>
      {children}
    </main>
  </div>;
}
