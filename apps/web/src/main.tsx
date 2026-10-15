import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './ui/App';
import { AppBoundary } from './ui/ErrorBoundary';
import { installGlobalFaultHandlers } from './lib/faults';
import { applyTheme } from './ui/prefs';
import './style.css';

applyTheme(); // the saved appearance before the first paint
// An error nobody caught is recorded for a report; the page keeps running (RESILIENCE.md fix 2).
installGlobalFaultHandlers();
createRoot(document.getElementById('root')!).render(<StrictMode><AppBoundary><App /></AppBoundary></StrictMode>);
