import type { ReactNode } from 'react';
import { Icon as SharedIcon } from './icons';
const paths: Record<string, ReactNode> = {
  // Paper podcasts (ui/Podcast.tsx).
  headphones: <><path d="M3 18v-6a9 9 0 0 1 18 0v6" /><path d="M21 19a2 2 0 0 1-2 2h-1a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h3z" /><path d="M3 19a2 2 0 0 0 2 2h1a2 2 0 0 0 2-2v-3a2 2 0 0 0-2-2H3z" /></>,
  play: <polygon points="7 4 20 12 7 20 7 4" />,
  pause: <><line x1="8" y1="5" x2="8" y2="19" /><line x1="16" y1="5" x2="16" y2="19" /></>,
  back15: <><path d="M3 12a9 9 0 1 0 3-6.7" /><polyline points="3 3 3 9 9 9" /><text x="12.5" y="15.5" fontSize="7.5" textAnchor="middle" stroke="none" fill="currentColor" fontWeight="700">15</text></>,
  forward15: <><path d="M21 12a9 9 0 1 1-3-6.7" /><polyline points="21 3 21 9 15 9" /><text x="11.5" y="15.5" fontSize="7.5" textAnchor="middle" stroke="none" fill="currentColor" fontWeight="700">15</text></>,
  transcript: <><line x1="4" y1="6" x2="20" y2="6" /><line x1="4" y1="10" x2="16" y2="10" /><line x1="4" y1="14" x2="20" y2="14" /><line x1="4" y1="18" x2="12" y2="18" /></>,
};
export function Icon({ name, size = 16 }: { name: string; size?: number }) {
  return paths[name] ? <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{paths[name]}</svg> : <SharedIcon name={name} size={size} />;
}
