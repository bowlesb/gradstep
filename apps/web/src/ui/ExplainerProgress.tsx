// The explainers' progress bar (owner, 2026-10-22: "it needs a progress bar"; and for equations "the same progress with the
// progress bar"): the figure walkthrough (figure-progress.ts) and the equation's symbols (equation-progress.ts) share it.
import type { FigureProgressState } from '../lib/figure-progress';

/** A thin bar, its value when the count is known, else indeterminate, with the stage under it. It sits where the
 * explanation's next words will appear; `fading` is its short exit once done (hidden from assistive technology). */
export function ProgressBar({ state, fading = false, testID = 'figure-progress' }: { state: FigureProgressState; fading?: boolean; testID?: string }) {
  const percent = state.value === null ? null : Math.round(state.value * 100);
  return <div className={`figure-progress${fading ? ' fading' : ''}`} data-testid={testID} aria-hidden={fading || undefined}>
    <div className={`figure-progress-track${percent === null ? ' indeterminate' : ''}`} role="progressbar" aria-label={state.label} aria-valuetext={state.label}
      aria-valuemin={0} aria-valuemax={100} aria-valuenow={percent ?? undefined}>
      <div className="figure-progress-fill" style={percent === null ? undefined : { width: `${percent}%` }} />
    </div>
    <p className="figure-progress-label" aria-hidden="true">{state.label}</p>
  </div>;
}

export const reducedMotion = () => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;
