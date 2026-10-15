// One part of the page failing never blanks the rest (docs/architecture/RESILIENCE.md fix 2): each region renders its
// own short notice with a way back, and the fault is recorded (a code, never content) for a support report.
import { Component, type ErrorInfo, type ReactNode } from 'react';
import { recordFault } from '../lib/faults';

type Props = { region: string; label: string; children: ReactNode; onReport?: () => void; resetKey?: unknown; compact?: boolean };

export class RegionBoundary extends Component<Props, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  componentDidCatch(error: unknown, _info: ErrorInfo) { recordFault(this.props.region, error); }
  componentDidUpdate(previous: Props) {
    // A different paper, route or account is a fresh start for the region.
    if (this.state.failed && previous.resetKey !== this.props.resetKey) this.setState({ failed: false });
  }
  render() {
    if (!this.state.failed) return this.props.children;
    const { region, label, onReport, compact } = this.props;
    return <div className={`region-fault${compact ? ' compact' : ''}`} role="alert" data-testid={`fault-${region}`}>
      <p><strong>{label} hit a problem.</strong>{compact ? '' : ' The rest of Gradstep keeps working.'}</p>
      <div className="row-actions">
        <button className="secondary small" onClick={() => this.setState({ failed: false })} data-testid={`fault-${region}-retry`}>Try again</button>
        {onReport && <button className="link" onClick={onReport}>Report it</button>}
      </div>
    </div>;
  }
}

/** The last line of defence: the app itself failed to render. A page with a way back, never a blank one. */
export class AppBoundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  componentDidCatch(error: unknown) { recordFault('app', error); }
  render() {
    if (!this.state.failed) return this.props.children;
    return <main className="auth-shell"><section className="card auth-card" role="alert" data-testid="fault-app">
      <h1>Gradstep hit a problem</h1>
      <p className="muted">Your library and chats are safe. Reload the page to continue.</p>
      <button className="primary" onClick={() => location.reload()}>Reload</button>
    </section></main>;
  }
}
