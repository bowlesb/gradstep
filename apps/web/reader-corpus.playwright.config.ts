import {defineConfig, devices} from '@playwright/test';
import base from './playwright.config';
export default defineConfig({...base,
 testIgnore:[],testMatch:'**/reader-corpus.spec.ts',timeout:120_000,
 outputDir:'../../.artifacts/reader-corpus-results',
 reporter:[['list'],['json',{outputFile:'../../.artifacts/reader-corpus-results/report.json'}]],
 projects:[
  {name:'chromium',use:{...devices['Desktop Chrome']}},
  {name:'firefox',use:{...devices['Desktop Firefox']}},
  {name:'webkit',use:{...devices['Desktop Safari']}},
 ],
});
