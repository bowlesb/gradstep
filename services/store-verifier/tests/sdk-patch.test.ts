import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { SignedDataVerifier, Environment } from '@apple/app-store-server-library';
import { patchSDKSource, resolvedSDKPath, sdkPatchProof, sdkPatchProofForHash, SDK_SOURCE_SHA256, SDK_PATCHED_SHA256 } from '../sdk-patch.ts';
import { health } from '../server.ts';
import { POLICY_ID } from '../protocol.ts';

const hash = (value: string) => createHash('sha256').update(value).digest('hex');
test('patch is exactly two checked hunks of the stock SDK, retaining the source attribution and rejecting drift', () => {
  const stock = readFileSync(new URL('../../../.artifacts/sdk-stock.js', import.meta.url), 'utf8');
  assert.equal(hash(stock), SDK_SOURCE_SHA256);
  const patched = patchSDKSource(stock);
  assert.equal(hash(patched), SDK_PATCHED_SHA256); assert.equal(readFileSync(resolvedSDKPath(), 'utf8'), patched);
  assert.ok(patched.includes('// Copyright (c) 2023 Apple Inc. Licensed under MIT License.'));
  assert.throws(() => patchSDKSource(stock.replace('return decodedJWT;', 'return {};' )), /sdk_source_mismatch/);
  assert.throws(() => patchSDKSource(stock + ' '), /sdk_source_mismatch/);
  assert.throws(() => patchSDKSource(patched), /sdk_source_mismatch/);
  const importing = createRequire(new URL('../../../supabase/functions/_shared/app-store.ts', import.meta.url));
  assert.equal(resolvedSDKPath(), importing.resolve('@apple/app-store-server-library/dist/jws_verification.js'));
});

test('readiness proves the exact installed mitigation, never arbitrary hashes or only X509 capabilities', () => {
  assert.equal(sdkPatchProof().applied, true);
  for (const unknown of [SDK_SOURCE_SHA256, 'PRIVATE', '', null]) {
    const proof = sdkPatchProofForHash(unknown); assert.equal(proof.applied, false); assert.ok(!JSON.stringify(proof).includes('PRIVATE'));
  }
  assert.equal(health({ STORE_VERIFIER_POLICY_ID: POLICY_ID, STORE_VERIFIER_MAINTENANCE: 'false' }).ready, true);
});

test('patched SDK date parser is strict UTC with complete calendar validation in every host timezone', () => {
  const verifier = new SignedDataVerifier([], true, Environment.SANDBOX, 'com.sciencereader.ios') as any;
  for (const [input, expected] of [['20261007010203Z', '2026-10-07T01:02:03.000Z'], ['20240229000000Z', '2024-02-29T00:00:00.000Z'],
    ['20000229000000Z', '2000-02-29T00:00:00.000Z'], ['00990101000000Z', '0099-01-01T00:00:00.000Z']]) {
    assert.equal(verifier.parseX509Date(input).toISOString(), expected);
  }
  for (const input of [undefined, null, '', 20261007, '20261007010203', '20261007010203+0000', '20261007010203.1Z', '20261007010203Z\n',
    '20261007010203Z\u2028', '20260229000000Z', '19000229000000Z', '20261301000000Z', '20260001000000Z', '20261000000000Z',
    '20261032235959Z', '20261007240000Z', '20261007006000Z', '20261007000060Z', '00000101000000Z']) {
    assert.throws(() => verifier.parseX509Date(input), error => (error as any).status === 7, String(input));
  }
});
