// Stroke icons in the legacy app's style (24-unit grid, 2-unit rounded strokes), drawn inline.
import type { ReactNode } from 'react';

const paths = {
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
  bug: <><rect x="7" y="7" width="10" height="12" rx="5" /><path d="M9 4 7 2M15 4l2-2M5 10H2M22 10h-3M5 15H2M22 15h-3M9 19l-1 3M15 19l1 3" /></>,
  bubble: <><path d="M21 11a8 8 0 0 1-8 8H7l-4 3v-5a8 8 0 1 1 18-6z" /><path d="M8 11h.01M12 11h.01M16 11h.01" /></>,
  external: <><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" /><polyline points="15 3 21 3 21 9" /><line x1="10" y1="14" x2="21" y2="3" /></>,
  user: <><circle cx="12" cy="8" r="4" /><path d="M4 21v-1a6 6 0 0 1 6-6h4a6 6 0 0 1 6 6v1" /></>,
  info: <><circle cx="12" cy="12" r="9" /><line x1="12" y1="11" x2="12" y2="17" /><line x1="12" y1="7" x2="12" y2="7" /></>,
  lock: <><rect x="4.5" y="10.5" width="15" height="10" rx="2" /><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3" /></>,
  more: <><circle cx="5" cy="12" r="1" /><circle cx="12" cy="12" r="1" /><circle cx="19" cy="12" r="1" /></>,
  menu: <><line x1="4" y1="7" x2="20" y2="7" /><line x1="4" y1="12" x2="20" y2="12" /><line x1="4" y1="17" x2="20" y2="17" /></>,
  arrowUp: <><line x1="12" y1="19" x2="12" y2="5" /><polyline points="5 12 12 5 19 12" /></>,
  stop: <rect x="6.5" y="6.5" width="11" height="11" rx="2" />,
  sliders: <><line x1="4" y1="7" x2="20" y2="7" /><line x1="4" y1="17" x2="20" y2="17" /><circle cx="9" cy="7" r="2.5" /><circle cx="15" cy="17" r="2.5" /></>,
  // Starter questions (chat-starters.json icon keys).
  target: <><circle cx="12" cy="12" r="9" /><circle cx="12" cy="12" r="5" /><circle cx="12" cy="12" r="1" /></>,
  gear: <><circle cx="12" cy="12" r="3" /><path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1M16.6 16.6l2.1 2.1M5.3 18.7l2.1-2.1M16.6 7.4l2.1-2.1" /></>,
  figure: <><rect x="3" y="4" width="18" height="16" rx="2" /><circle cx="8.5" cy="9.5" r="1.5" /><polyline points="21 16 15.5 11 6 20" /></>,
  function: <><path d="M16 3.5h-1.5A3 3 0 0 0 11.5 6.5v11a3 3 0 0 1-3 3H7" /><line x1="7.5" y1="10" x2="15.5" y2="10" /></>,
  table: <><rect x="3" y="4" width="18" height="16" rx="2" /><line x1="3" y1="9.5" x2="21" y2="9.5" /><line x1="3" y1="14.5" x2="21" y2="14.5" /><line x1="9.5" y1="9.5" x2="9.5" y2="20" /></>,
  chart: <><line x1="3.5" y1="20" x2="20.5" y2="20" /><line x1="7" y1="16.5" x2="7" y2="11" /><line x1="12" y1="16.5" x2="12" y2="5" /><line x1="17" y1="16.5" x2="17" y2="8.5" /></>,
  question: <><circle cx="12" cy="12" r="9" /><path d="M9.2 9.2a2.9 2.9 0 0 1 5.6 1c0 1.9-2.8 2.6-2.8 2.6" /><line x1="12" y1="17" x2="12" y2="17" /></>,
  lightbulb: <><path d="M9.5 18h5M10.5 21h3" /><path d="M12 3a6 6 0 0 0-3.6 10.8c.6.5 1.1 1.2 1.1 2V16h5v-.2c0-.8.5-1.5 1.1-2A6 6 0 0 0 12 3z" /></>,
  compare: <><polyline points="17 3.5 20.5 7 17 10.5" /><line x1="3.5" y1="7" x2="20.5" y2="7" /><polyline points="7 13.5 3.5 17 7 20.5" /><line x1="20.5" y1="17" x2="3.5" y2="17" /></>,
  map: <><polygon points="3 6 3 21 9 18 15 21 21 18 21 3 15 6 9 3 3 6" /><line x1="9" y1="3" x2="9" y2="18" /><line x1="15" y1="6" x2="15" y2="21" /></>,
  // The equation view's Explain (the app's "sparkles").
  sparkles: <><path d="M10 3.5l1.7 4.8 4.8 1.7-4.8 1.7L10 16.5l-1.7-4.8L3.5 10l4.8-1.7z" /><path d="M18 14l.8 2.2 2.2.8-2.2.8L18 20l-.8-2.2-2.2-.8 2.2-.8z" /></>,
  // Reader version details: this paper uses the latest reader.
  check: <polyline points="20 6 9 17 4 12" />,
  // Contents › Figures › View as tiles.
  grid: <><rect x="4" y="4" width="7" height="7" rx="1.5" /><rect x="13" y="4" width="7" height="7" rx="1.5" /><rect x="4" y="13" width="7" height="7" rx="1.5" /><rect x="13" y="13" width="7" height="7" rx="1.5" /></>,
} satisfies Record<string, ReactNode>;

export type IconName = keyof typeof paths;
/** A name from data (a starter question's icon key) as an icon, or null when this build has no such icon. */
export const iconName = (name: string): IconName | null => Object.hasOwn(paths, name) ? name as IconName : null;

export function Icon({ name, size = 16 }: { name: IconName; size?: number }) {
  return (
    <svg className="icon" width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">
      {paths[name]}
    </svg>
  );
}
