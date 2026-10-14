import { defineConfig, devices } from '@playwright/test';
import base from './playwright.config';
// Pre-build UX review screenshots (scripts/ux-review.mjs). Desktop and phone over the fixture backend.
export default defineConfig({ ...base,
  testIgnore: [], testMatch: '**/ux-review.spec.ts', timeout: 120_000,
  outputDir: '../../.artifacts/ux/web-results',
  reporter: [['list'], ['json', { outputFile: '../../.artifacts/ux/web-results/report.json' }]],
  projects: [
    { name: 'desktop', use: { ...devices['Desktop Chrome'], viewport: { width: 1280, height: 860 } } },
    { name: 'phone', use: { ...devices['Desktop Chrome'], viewport: { width: 390, height: 844 }, isMobile: false, hasTouch: true } },
  ],
});
