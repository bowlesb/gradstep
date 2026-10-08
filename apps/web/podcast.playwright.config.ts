import { defineConfig, devices } from '@playwright/test';
import { fixturePort as fixture, appPort as app } from './e2e/environment';
const env = `VITE_SUPABASE_URL=http://127.0.0.1:${fixture} VITE_SUPABASE_ANON_KEY=fixture-anon VITE_ENVIRONMENT=podcast-fixture`;
const appCommand = process.env.WEB_E2E_DEV === '1'
  ? `${env} npx vite --config podcast.vite.config.ts --host 127.0.0.1 --port ${app} --strictPort`
  : `${env} npx vite build --config podcast.vite.config.ts && ${env} npx vite preview --config podcast.vite.config.ts --host 127.0.0.1 --port ${app} --strictPort`;
export default defineConfig({
  testDir: 'e2e', testMatch: 'podcast-client.spec.ts', fullyParallel: false, workers: 1, timeout: 45_000,
  expect: { timeout: 10_000 }, reporter: [['list']], outputDir: '../../.artifacts/podcast-client/results',
  use: { baseURL: `http://127.0.0.1:${app}`, trace: 'retain-on-failure' },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'], viewport: { width: 1280, height: 860 } } }],
  webServer: [
    { command: `FIXTURE_PORT=${fixture} node e2e/podcast-fixture.mjs`, url: `http://127.0.0.1:${fixture}/health`, reuseExistingServer: false },
    { command: appCommand, url: `http://127.0.0.1:${app}/e2e/podcast-harness.html`, reuseExistingServer: false, timeout: 120_000 },
  ],
});
