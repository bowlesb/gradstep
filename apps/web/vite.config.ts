// Gradstep browser reader build (docs/architecture/BROWSER_READER.md).
// - `virtual:reader-frame`: the reader frame's only script — src/reader/frame-shim.js followed by
//   apps/apple/ScienceReader/Resources/reader-bridge.js copied byte for byte — and its CSP hash.
// - `_headers` for Cloudflare Pages (CSP with that hash and the configured backend), also applied
//   by `vite preview` so local end-to-end tests run under the production policy.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { type Plugin, loadEnv } from 'vite';
import { defineConfig } from 'vitest/config';

const repository = fileURLToPath(new URL('../../', import.meta.url));
const BRIDGE = new URL('../apple/ScienceReader/Resources/reader-bridge.js', import.meta.url);
const SHIM = new URL('./src/reader/frame-shim.js', import.meta.url);

function frameScript(): { script: string; hash: string } {
  const script = readFileSync(SHIM, 'utf8') + '\n' + readFileSync(BRIDGE, 'utf8');
  // It is serialized inside the frame document's <script>; these would end or alter that element.
  if (/<\/script|<!--/i.test(script)) throw new Error('The reader frame script must not contain </script or <!--');
  return { script, hash: 'sha256-' + createHash('sha256').update(script, 'utf8').digest('base64') };
}

function headers(backend: string, hash: string): Record<string, string> {
  const origin = backend ? new URL(backend).origin : '';
  return {
    'Content-Security-Policy': [`default-src 'none'`, `script-src 'self' '${hash}'`, `style-src 'self' 'unsafe-inline'`, `img-src 'self' data:`,
      `font-src 'self'`, `connect-src ${origin || `'none'`}`, `frame-src 'self'`, `manifest-src 'self'`, `base-uri 'none'`, `form-action 'self'`,
      `frame-ancestors 'none'`, `object-src 'none'`, `worker-src 'none'`].join('; '),
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
    'X-Frame-Options': 'DENY',
    'Cross-Origin-Opener-Policy': 'same-origin',
    'Cross-Origin-Resource-Policy': 'same-origin',
    'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()',
  };
}

function readerFrame(backend: string): Plugin {
  const id = 'virtual:reader-frame', resolved = '\0' + id;
  return {
    name: 'gradstep-reader-frame',
    resolveId: source => (source === id ? resolved : null),
    load(source) {
      if (source !== resolved) return null;
      this.addWatchFile(fileURLToPath(BRIDGE)); this.addWatchFile(fileURLToPath(SHIM));
      return `export default ${JSON.stringify(frameScript())};`;
    },
    configurePreviewServer(server) {
      const values = headers(backend, frameScript().hash);
      server.middlewares.use((_request, response, next) => { for (const [k, v] of Object.entries(values)) response.setHeader(k, v); next(); });
    },
    generateBundle() {
      const values = headers(backend, frameScript().hash);
      // no-transform stops the CDN from injecting its analytics beacon (zone-level Web Analytics), which the CSP
      // would refuse anyway; Pages joins it with the per-path Cache-Control values below.
      const lines = ['/*', ...Object.entries(values).map(([k, v]) => `  ${k}: ${v}`), ...(backend.startsWith('https:') ? ['  Strict-Transport-Security: max-age=31536000'] : []),
        '  Cache-Control: no-transform',
        '', '/index.html', '  Cache-Control: no-cache', '', '/', '  Cache-Control: no-cache', '', '/assets/*', '  Cache-Control: public, max-age=31536000, immutable', ''];
      this.emitFile({ type: 'asset', fileName: '_headers', source: lines.join('\n') });
    },
  };
}

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, fileURLToPath(new URL('.', import.meta.url)), 'VITE_');
  // Only the public backend URL, anon key and environment name may reach the bundle.
  for (const key of Object.keys(env)) if (!['VITE_SUPABASE_URL', 'VITE_SUPABASE_ANON_KEY', 'VITE_ENVIRONMENT'].includes(key)) throw new Error(`Refusing unexpected build variable ${key}`);
  const backend = env.VITE_SUPABASE_URL ?? '';
  return {
    plugins: [readerFrame(backend)],
    server: { fs: { allow: [repository] } },
    build: { target: 'es2022', sourcemap: false, assetsInlineLimit: 0 },
    test: { include: ['tests/**/*.test.ts'], environment: 'node', testTimeout: 30_000 },
  };
});
