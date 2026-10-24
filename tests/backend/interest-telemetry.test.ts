// ONNX Runtime's telemetry stays off (docs/architecture/INTEREST_INDEX.md §1): the embedder refuses to load the runtime
// unless ORT_DISABLE_TELEMETRY is set, and the image sets it.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createEmbedder, telemetryDisabled } from '../../services/pipeline-worker/interest-embed.ts';

test('the opt-out values ONNX Runtime accepts', () => {
  for (const v of ['1', 'true', 'YES', ' on ', 'y']) assert.equal(telemetryDisabled({ ORT_DISABLE_TELEMETRY: v }), true, v);
  for (const v of [undefined, '', '0', 'false', 'off']) assert.equal(telemetryDisabled({ ORT_DISABLE_TELEMETRY: v }), false, String(v));
});

test('without the opt-out the embedder refuses before touching the model or the runtime', async () => {
  const saved = process.env.ORT_DISABLE_TELEMETRY;
  delete process.env.ORT_DISABLE_TELEMETRY;
  try {
    await assert.rejects(createEmbedder({ modelPath: new URL('file:///nonexistent/model.onnx') }), /interest_telemetry_enabled/);
  } finally { if (saved !== undefined) process.env.ORT_DISABLE_TELEMETRY = saved; }
});

test('the worker image sets the opt-out', () => {
  const docker = readFileSync(new URL('../../services/pipeline-worker/Dockerfile', import.meta.url), 'utf8');
  assert.match(docker, /^ENV ORT_DISABLE_TELEMETRY=1$/m);
});
