// End-to-end tests against a local fixture backend (e2e/fixture-backend.mjs) and the production
// build served by `vite preview` with the production security headers (connect-src → fixture).
import { defineConfig, devices } from '@playwright/test';

const FIXTURE = 54329, APP = 4317;
const env = `VITE_SUPABASE_URL=http://127.0.0.1:${FIXTURE} VITE_SUPABASE_ANON_KEY=fixture-anon VITE_ENVIRONMENT=fixture`;
// Use WEB_E2E_DEV=1 for targeted StrictMode lifecycle journeys (the security-header test requires production).
const appCommand = process.env.WEB_E2E_DEV === '1'
  ? `${env} npx vite --host 127.0.0.1 --port ${APP} --strictPort`
  : `${env} npx vite build --outDir dist-e2e && ${env} npx vite preview --outDir dist-e2e --host 127.0.0.1 --port ${APP} --strictPort`;

export default defineConfig({
  testDir: 'e2e',
  timeout: 60_000,
  expect: { timeout: 10_000 },
  fullyParallel: false,
  workers: 1,
  reporter: [['list']],
  outputDir: '../../.artifacts/web-e2e/results',
  use: { baseURL: `http://127.0.0.1:${APP}`, trace: 'retain-on-failure' },
  projects: [
    { name: 'desktop', use: { ...devices['Desktop Chrome'], viewport: { width: 1280, height: 860 } } },
    { name: 'phone', use: { ...devices['Desktop Chrome'], viewport: { width: 390, height: 844 }, isMobile: false, hasTouch: true } },
    { name: 'webkit', use: { ...devices['Desktop Safari'], viewport: { width: 1280, height: 860 } } },
  ],
  webServer: [
    { command: `FIXTURE_PORT=${FIXTURE} node e2e/fixture-backend.mjs`, url: `http://127.0.0.1:${FIXTURE}/health`, reuseExistingServer: false },
    { command: appCommand,
      url: `http://127.0.0.1:${APP}/`, reuseExistingServer: false, timeout: 120_000 },
  ],
});
