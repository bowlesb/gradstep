import { defineConfig, devices } from '@playwright/test';
import { appPort as APP } from './e2e/environment';
// Opt-in fidelity check of the browser's local snippet rasterizer (docs/architecture/NOTES_AND_SNIPPETS.md): the real
// reader frame on real bundles in Chromium, Firefox and WebKit, each capture compared with the browser's own screenshot
// of the same region, in light and dark, at 1× and 2×. Vite dev serves the test-only harness; no backend, no network.
export default defineConfig({
  testDir: 'e2e', testMatch: '**/notes-capture.spec.ts', timeout: 180_000, expect: { timeout: 20_000 },
  fullyParallel: false, workers: 1, reporter: [['list']], outputDir: '../../.artifacts/notes-capture/results',
  use: { baseURL: `http://127.0.0.1:${APP}` },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'], viewport: { width: 900, height: 900 } } },
    { name: 'chromium-2x', use: { ...devices['Desktop Chrome'], viewport: { width: 900, height: 900 }, deviceScaleFactor: 2 } },
    { name: 'firefox', use: { ...devices['Desktop Firefox'], viewport: { width: 900, height: 900 } } },
    { name: 'webkit', use: { ...devices['Desktop Safari'], viewport: { width: 900, height: 900 } } },
    { name: 'webkit-2x', use: { ...devices['Desktop Safari'], viewport: { width: 900, height: 900 }, deviceScaleFactor: 2 } },
  ],
  webServer: [{ command: `npx vite --host 127.0.0.1 --port ${APP} --strictPort`, url: `http://127.0.0.1:${APP}/e2e/capture-harness.html`, reuseExistingServer: false, timeout: 120_000 }],
});
