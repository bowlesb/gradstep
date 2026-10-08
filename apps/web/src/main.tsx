import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './ui/App';
import { applyTheme } from './ui/prefs';
import './style.css';

applyTheme(); // the saved appearance before the first paint
createRoot(document.getElementById('root')!).render(<StrictMode><App /></StrictMode>);
