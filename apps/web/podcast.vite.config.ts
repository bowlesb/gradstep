import { defineConfig, mergeConfig } from 'vite';
import base from './vite.config.ts';
export default defineConfig(context => mergeConfig(typeof base === 'function' ? base(context) : base, {
  build: { outDir: '../../.artifacts/podcast-client/build', emptyOutDir: true, rolldownOptions: { input: 'e2e/podcast-harness.html' } },
}));
