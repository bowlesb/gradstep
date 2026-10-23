import { useState } from 'react';
import { Icon } from './icons';

/** A user-invoked clipboard action with a narrow fallback for browsers without Clipboard API support. `icon` draws it as
 * a quiet icon button (an answer's Copy, UX audit R25); its name stays the label. */
export function CopyButton({ text, label = 'Copy', copiedLabel = 'Copied', className = 'link small', icon = false }: {
  text: string; label?: string; copiedLabel?: string; className?: string; icon?: boolean;
}) {
  const [state, setState] = useState<'ready' | 'copied' | 'failed'>('ready');
  const copy = async () => {
    if (!text || state === 'copied') return;
    try {
      if (navigator.clipboard?.writeText) await navigator.clipboard.writeText(text);
      else {
        const field = document.createElement('textarea');
        field.value = text; field.setAttribute('readonly', '');
        field.style.position = 'fixed'; field.style.opacity = '0';
        document.body.appendChild(field); field.select();
        try { if (!document.execCommand('copy')) throw new Error('copy_failed'); }
        finally { field.remove(); }
      }
      setState('copied');
      window.setTimeout(() => setState('ready'), 1_500);
    } catch {
      setState('failed');
    }
  };
  const name = state === 'failed' ? `${label} failed` : state === 'copied' ? copiedLabel : label;
  return <button type="button" className={icon ? 'icon-button copy-icon' : className} onClick={() => void copy()} disabled={!text || state === 'copied'}
    aria-label={name} title={icon ? name : undefined} data-testid={`copy-${label.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`}>
    {icon ? <Icon name={state === 'copied' ? 'check' : state === 'failed' ? 'close' : 'copy'} size={15} />
      : state === 'failed' ? 'Copy failed' : state === 'copied' ? copiedLabel : label}
  </button>;
}
