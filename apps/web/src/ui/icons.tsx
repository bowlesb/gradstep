// Stroke icons in the legacy app's style (24-unit grid, 2-unit rounded strokes), drawn inline.
import type { ReactNode } from 'react';

const paths: Record<string, ReactNode> = {
  sidebar: <><rect x="3" y="4" width="18" height="16" rx="2" /><line x1="9" y1="4" x2="9" y2="20" /></>,
  panelRight: <><rect x="3" y="4" width="18" height="16" rx="2" /><line x1="15" y1="4" x2="15" y2="20" /></>,
  chat: <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />,
  chats: <><path d="M17 9h2a2 2 0 0 1 2 2v9l-3-3h-6a2 2 0 0 1-2-2v-1" /><path d="M15 4H5a2 2 0 0 0-2 2v9l3-3h9a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2z" /></>,
  search: <><circle cx="11" cy="11" r="7" /><line x1="21" y1="21" x2="16.65" y2="16.65" /></>,
  plus: <><line x1="12" y1="5" x2="12" y2="19" /><line x1="5" y1="12" x2="19" y2="12" /></>,
  sun: <><circle cx="12" cy="12" r="4.5" /><line x1="12" y1="1.5" x2="12" y2="3.5" /><line x1="12" y1="20.5" x2="12" y2="22.5" /><line x1="4.2" y1="4.2" x2="5.6" y2="5.6" />
    <line x1="18.4" y1="18.4" x2="19.8" y2="19.8" /><line x1="1.5" y1="12" x2="3.5" y2="12" /><line x1="20.5" y1="12" x2="22.5" y2="12" /><line x1="4.2" y1="19.8" x2="5.6" y2="18.4" />
    <line x1="18.4" y1="5.6" x2="19.8" y2="4.2" /></>,
  moon: <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />,
  image: <><rect x="3" y="3" width="18" height="18" rx="2" /><circle cx="8.5" cy="8.5" r="1.5" /><polyline points="21 15 16 10 5 21" /></>,
  list: <><line x1="4" y1="6" x2="20" y2="6" /><line x1="4" y1="12" x2="16" y2="12" /><line x1="4" y1="18" x2="18" y2="18" /></>,
  book: <><path d="M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z" /><path d="M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z" /></>,
  feed: <><path d="M4 11a9 9 0 0 1 9 9" /><path d="M4 4a16 16 0 0 1 16 16" /><circle cx="5" cy="19" r="1" /></>,
  chevronLeft: <polyline points="15 18 9 12 15 6" />,
  chevronUp: <polyline points="18 15 12 9 6 15" />,
  chevronDown: <polyline points="6 9 12 15 18 9" />,
  chevronRight: <polyline points="9 18 15 12 9 6" />,
  close: <><line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" /></>,
  refresh: <><polyline points="23 4 23 10 17 10" /><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10" /></>,
  keyboard: <><rect x="2" y="6" width="20" height="12" rx="2" /><line x1="6" y1="10" x2="6" y2="10" /><line x1="10" y1="10" x2="10" y2="10" /><line x1="14" y1="10" x2="14" y2="10" />
    <line x1="18" y1="10" x2="18" y2="10" /><line x1="7" y1="14" x2="17" y2="14" /></>,
  external: <><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" /><polyline points="15 3 21 3 21 9" /><line x1="10" y1="14" x2="21" y2="3" /></>,
  user: <><circle cx="12" cy="8" r="4" /><path d="M4 21v-1a6 6 0 0 1 6-6h4a6 6 0 0 1 6 6v1" /></>,
  // Paper podcasts (ui/Podcast.tsx).
  headphones: <><path d="M3 18v-6a9 9 0 0 1 18 0v6" /><path d="M21 19a2 2 0 0 1-2 2h-1a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h3z" /><path d="M3 19a2 2 0 0 0 2 2h1a2 2 0 0 0 2-2v-3a2 2 0 0 0-2-2H3z" /></>,
  play: <polygon points="7 4 20 12 7 20 7 4" />,
  pause: <><line x1="8" y1="5" x2="8" y2="19" /><line x1="16" y1="5" x2="16" y2="19" /></>,
  back15: <><path d="M3 12a9 9 0 1 0 3-6.7" /><polyline points="3 3 3 9 9 9" /><text x="12.5" y="15.5" fontSize="7.5" textAnchor="middle" stroke="none" fill="currentColor" fontWeight="700">15</text></>,
  forward15: <><path d="M21 12a9 9 0 1 1-3-6.7" /><polyline points="21 3 21 9 15 9" /><text x="11.5" y="15.5" fontSize="7.5" textAnchor="middle" stroke="none" fill="currentColor" fontWeight="700">15</text></>,
  transcript: <><line x1="4" y1="6" x2="20" y2="6" /><line x1="4" y1="10" x2="16" y2="10" /><line x1="4" y1="14" x2="20" y2="14" /><line x1="4" y1="18" x2="12" y2="18" /></>,
};

export type IconName = keyof typeof paths;

export function Icon({ name, size = 16 }: { name: IconName; size?: number }) {
  return (
    <svg className="icon" width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">
      {paths[name]}
    </svg>
  );
}
