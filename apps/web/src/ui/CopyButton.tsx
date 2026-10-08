import { useState } from 'react';

/** A user-invoked clipboard action with a narrow fallback for browsers without Clipboard API support. */
export function CopyButton({ text, label = 'Copy', copiedLabel = 'Copied', className = 'link small' }: {
  text: string; label?: string; copiedLabel?: string; className?: string;
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
  return <button type="button" className={className} onClick={() => void copy()} disabled={!text || state === 'copied'}
    aria-label={state === 'failed' ? `${label} failed` : state === 'copied' ? copiedLabel : label} data-testid={`copy-${label.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`}>
    {state === 'failed' ? 'Copy failed' : state === 'copied' ? copiedLabel : label}
  </button>;
}
