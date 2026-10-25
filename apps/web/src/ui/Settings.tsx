// Settings (owner-approved 2026-10-22, UX audit S9): the account menu's 23 rows as the apps' Settings sheet, with their
// sections in their order (RootView.swift SettingsView): Account, AI credits, AI options, Library, Reading, Your
// assets, Help and about, and Admin for operators (grey, apart). An information dialog: title on the left, a round X on
// the right, no footer; explanations behind ⓘ beside a row's words. A row opens a page inside Settings with Back
// (Keyboard shortcuts), or the existing dialog over it.
import { type ReactNode, useEffect, useState } from 'react';
import { type AccountSummary, CREDITS_INFO, FREE_AI_INFO, PLAN_INFO, WHERE_TO_BUY, creditsLabel, freeAILabel, loadAccountSummary, planLabel } from '../lib/account-summary';
import { operationsDashboard, operatorRoles } from '../lib/backend';
import type { Explanation } from '../lib/chat-session';
import { Dialog, InfoTip, SheetTop } from './common';
import { Icon, type IconName } from './icons';
import type { Theme } from './prefs';
import './settings.css';

export const SHORTCUTS = [['/ or ⌘K', 'Search papers'], ['⌘F', 'Find in the paper'], ['[', 'Show or hide the side panel'], [']', 'Show or hide the chat panel'],
  ['F', 'Reading mode (Esc leaves it)'], ['J K', 'Next or previous section'], ['Space', 'Page down in the paper (Shift: up)'],
  ['↑ ↓', 'Move between papers'], ['← →', 'Previous or next figure'], ['Esc', 'Close, or clear the search'], ['?', 'These shortcuts']] as const;

export function ShortcutList() {
  return <>
    <dl className="shortcuts">{SHORTCUTS.map(([k, d]) => <div key={k}><dt><kbd>{k}</kbd></dt><dd>{d}</dd></div>)}</dl>
    <p className="fine">On Windows and Linux, use Ctrl for ⌘.</p>
  </>;
}

export type SettingsSync = { label: string; detail: string | null; canSync: boolean; run: () => void };

function Section({ title, info, admin = false, testID, children }: { title: string; info?: string; admin?: boolean; testID?: string; children: ReactNode }) {
  return <section className={`settings-section${admin ? ' admin' : ''}`} aria-label={title} data-testid={testID}>
    <h3 className="settings-heading">{title}{info && <InfoTip text={info} />}</h3>
    <div className="settings-group">{children}</div>
  </section>;
}

/** A fact: its words (and ⓘ) on the left, the value on the right. */
function Fact({ label, info, infoTestID, value, testID, children }: { label: string; info?: string; infoTestID?: string; value?: ReactNode; testID?: string; children?: ReactNode }) {
  return <div className="settings-row" data-testid={testID}>
    <span className="settings-label">{label}{info && <InfoTip text={info} testID={infoTestID} />}</span>
    <span className="settings-value">{value}{children}</span>
  </div>;
}

/** A row that opens something: a page here or a dialog over Settings (a chevron), or an action (accent words, no
 * chevron; red for Delete account). The whole row is the button; an ⓘ sits just right of the words, over it. */
function Open({ label, icon, value, onClick, disabled = false, kind = 'open', testID, info }: { label: string; icon?: IconName; value?: ReactNode; onClick: (() => void) | null;
  disabled?: boolean; kind?: 'open' | 'action' | 'danger'; testID?: string; info?: string }) {
  const off = disabled || !onClick;
  return <div className={`settings-row settings-open-row ${kind}${off ? ' disabled' : ''}`}>
    <button type="button" className="settings-open" aria-label={label} disabled={off} onClick={() => onClick?.()} data-testid={testID} />
    <span className="settings-label" aria-hidden={!info || undefined}>{icon && <Icon name={icon} size={15} />}<span aria-hidden="true">{label}</span>{info && <InfoTip text={info} />}</span>
    {value !== undefined && <span className="settings-value" aria-hidden="true">{value}</span>}
    {kind === 'open' && <Icon name="chevronRight" size={14} />}
  </div>;
}

function Toggle({ label, info, on, onChange, testID }: { label: string; info?: string; on: boolean; onChange: (on: boolean) => void; testID?: string }) {
  return <div className="settings-row">
    <span className="settings-label">{label}{info && <InfoTip text={info} />}</span>
    <button type="button" role="switch" aria-checked={on} aria-label={label} className="settings-switch" onClick={() => onChange(!on)} data-testid={testID}><span /></button>
  </div>;
}

export function SettingsDialog({ open, onClose, account, email, theme, setTheme, passageMarks, onPassageMarks, sync, onUsage, onChatDefaults, onCatalogs, onChats, onDiagrams, onNotes,
  onExplanations, onDownloadAssets, onInfo, onPrivacy, onReport, onReports, onDeleteAccount, onSignOut }: {
  open: boolean; onClose: () => void; account: string; email: string | null; theme: Theme; setTheme: (t: Theme) => void;
  passageMarks: boolean; onPassageMarks: (on: boolean) => void; sync: SettingsSync | null;
  onUsage: () => void; onChatDefaults: (() => void) | null; onCatalogs: (() => void) | null; onChats: () => void; onDiagrams: (() => void) | null; onNotes: () => void;
  onExplanations: ((kind: Explanation['kind']) => void) | null; onDownloadAssets: (() => void) | null;
  onInfo: () => void; onPrivacy: () => void; onReport: () => void; onReports: () => void; onDeleteAccount: () => void; onSignOut: () => void;
}) {
  const [page, setPage] = useState<'main' | 'shortcuts'>('main');
  useEffect(() => { if (!open) setPage('main'); }, [open]);
  // AI credits and the plan, read again each time Settings opens (native Settings › AI credits); the last values stay
  // while a read is under way, a dash while none has answered.
  const [summary, setSummary] = useState<AccountSummary>({ balance: undefined, plan: undefined });
  useEffect(() => { setSummary({ balance: undefined, plan: undefined }); }, [account]);
  useEffect(() => {
    if (!open) return;
    const abort = new AbortController();
    loadAccountSummary(account, abort.signal).then(next => {
      if (abort.signal.aborted) return;
      setSummary(last => ({ balance: next.balance ?? last.balance, plan: next.plan !== undefined ? next.plan : last.plan,
        periodMonths: next.plan !== undefined ? next.periodMonths ?? null : last.periodMonths }));
    }, () => undefined);
    return () => abort.abort();
  }, [account, open]);
  // Operators (owner, support) get a link to the admin site; readers never see it.
  const [roles, setRoles] = useState<string[]>([]);
  useEffect(() => {
    const abort = new AbortController(); setRoles([]);
    operatorRoles(account, abort.signal).then(setRoles, () => undefined);
    return () => abort.abort();
  }, [account]);

  return <Dialog open={open} onClose={onClose} title="Settings" className="settings-dialog">
    {page === 'shortcuts' ? <div className="settings-page" data-testid="settings-shortcuts">
      <SheetTop onClose={onClose} closeLabel="Close settings">
        <button type="button" className="icon-button sheet-back" onClick={() => setPage('main')} aria-label="Back to Settings" title="Back to Settings" data-testid="settings-back">
          <Icon name="chevronLeft" /></button>
        <h2>Keyboard shortcuts</h2>
      </SheetTop>
      <ShortcutList />
    </div> : <div className="settings-page" data-testid="settings">
      <SheetTop onClose={onClose} closeLabel="Close settings" testID="settings-close"><h2>Settings</h2></SheetTop>
      <Section title="Account" testID="settings-account">
        <div className="settings-row settings-email"><span className="settings-label menu-email">{email ?? 'Signed in'}</span></div>
        <Fact label="This browser" info="An approved device holds your encryption keys. Your library and chats open here without the recovery code." value="Approved device" testID="settings-device" />
        {sync && <Fact label="Sync" testID="account-sync" value={<span title={sync.detail ?? undefined}>{sync.label}</span>}>
          {sync.canSync && <button type="button" className="link small" onClick={sync.run} data-testid="sync-now">Sync now</button>}</Fact>}
        <Fact label="Plan" info={PLAN_INFO} infoTestID="plan-info" value={planLabel(summary.plan, summary.periodMonths)} testID="account-plan" />
        <Open label="Sign out…" onClick={onSignOut} kind="action" testID="settings-sign-out" />
        <Open label="Delete account…" onClick={onDeleteAccount} kind="danger" testID="delete-account" />
      </Section>
      {/* Owner, build 57: "Credits -> AI credits", "Plan -> Subscription Plan"; the explanations behind ⓘ. Bought in the apps. */}
      <Section title="AI credits">
        <Fact label="Available" info={CREDITS_INFO} infoTestID="credits-info" value={creditsLabel(summary.balance)} testID="account-credits" />
        {!!summary.balance?.reserved && <Fact label="Held for answers in progress" value={summary.balance.reserved.toLocaleString()} testID="account-held" />}
        {/* Owner, 2026-10-23: say plainly that the web can't sell yet, for readers without an iPhone, iPad or Mac. */}
        <Fact label="Add credits" info={WHERE_TO_BUY} infoTestID="add-credits-info" value="Not on the web yet" testID="add-credits" />
        {/* Free AI (migration 0150; docs/PRICING_HOW_IT_WORKS.md): only on the free tier. */}
        {summary.balance?.free && <Fact label="Free AI this month" info={FREE_AI_INFO} infoTestID="free-ai-info" value={freeAILabel(summary.balance.free)} testID="account-free-ai" />}
        {/* Owner, 2026-10-22: where credits go — each request with its tokens and cost. */}
        <Open label="Your AI usage" onClick={onUsage} testID="ai-usage" />
      </Section>
      <Section title="AI options">
        <Open label="AI chat options" onClick={onChatDefaults} testID="chat-defaults"
          info="The model and answer length new chats start with, for each activity, and visual answers." />
      </Section>
      <Section title="Library">
        <Open label="Catalogs" onClick={onCatalogs} testID="settings-catalogs" info="Your default catalog opens when you start the app. New papers go into the catalog you’re viewing." />
      </Section>
      {/* Text sizes live where you read (A− / A+ on the paper; owner, build 57). */}
      <Section title="Reading">
        <div className="settings-row">
          <span className="settings-label">Appearance<InfoTip text="System follows this device’s Light or Dark setting and changes when it does, for example at sunset if it switches automatically." testID="appearance-info" /></span>
          <span className="segmented settings-theme" role="radiogroup" aria-label="Appearance">
            {(['system', 'light', 'dark'] as const).map(t => <button key={t} type="button" role="radio" aria-checked={theme === t} className={`segment${theme === t ? ' on' : ''}`}
              onClick={() => setTheme(t)} data-testid={`appearance-${t}`}>{t === 'system' ? 'System' : t === 'light' ? 'Light' : 'Dark'}</button>)}
          </span>
        </div>
        <Toggle label="Underline passages with chats" info="Passages you’ve started a chat from are underlined in the paper. Click one to open its chat." on={passageMarks} onChange={onPassageMarks} testID="passage-marks" />
      </Section>
      {/* Owner, build 57: "Research -> Your Assets… chats, diagrams one word is enough". */}
      <Section title="Your assets">
        <Open label="Chats" icon="chats" onClick={onChats} testID="assets-chats" />
        <Open label="Diagrams" icon="chart" onClick={onDiagrams} testID="assets-diagrams" />
        {/* Owner, 2026-10-21: "Needs to be a Notes section in your assets". */}
        <Open label="Snippets" icon="notes" onClick={onNotes} testID="assets-notes" />
        {/* Owner, build 62: the AI Explainer's answers too (this tab's; the apps keep theirs on the device). */}
        <Open label="Equation explanations" icon="function" onClick={onExplanations && (() => onExplanations('equation'))} testID="assets-equations" />
        <Open label="Figure explanations" icon="image" onClick={onExplanations && (() => onExplanations('figure'))} testID="assets-figures" />
        <Open label="Paper explanations" icon="sparkles" onClick={onExplanations && (() => onExplanations('paper'))} testID="assets-papers" />
        {/* Owner, build 82: "Need a download assets button": this browser's own content as a .zip made here. */}
        <Open label="Download your assets" icon="download" onClick={onDownloadAssets} testID="assets-download" />
      </Section>
      {/* About, with Report and My reports beside it, for everyone (owner, build 58). */}
      <Section title="Help and about">
        <Open label="How Gradstep works" icon="info" onClick={onInfo} testID="how-gradstep-works" />
        <Open label="Privacy & data" icon="lock" onClick={onPrivacy} testID="privacy-data" />
        <Open label="Keyboard shortcuts" icon="keyboard" onClick={() => setPage('shortcuts')} testID="settings-shortcuts-row" />
        <Open label="Report a problem…" icon="bug" onClick={onReport} kind="action" testID="settings-report" />
        <Open label="My reports" icon="bubble" onClick={onReports} testID="my-reports" />
      </Section>
      {/* Operator tools in one grey group, apart, only for owner and support (owner, build 57). */}
      {roles.length > 0 && <Section title="Admin" admin testID="menu-admin">
        <div className="settings-row settings-open-row open">
          <a className="settings-open" href={operationsDashboard(roles)} target="_blank" rel="noreferrer" aria-label="Operations dashboard" data-testid="operations-dashboard" />
          <span className="settings-label"><Icon name="external" size={15} /><span aria-hidden="true">Operations dashboard</span>
            <InfoTip text="People, use, reliability and spending, on the private admin site. Sign in there once with your password and authenticator." /></span>
        </div>
      </Section>}
    </div>}
  </Dialog>;
}
