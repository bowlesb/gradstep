// Frozen Node-crypto vectors shared with CryptoKit. All keys/nonces are synthetic.
import { createCipheriv, createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { fromBase64, fromHex, fromUtf8, sha256Hex, toBase64, toHex, utf8 } from '../src/lib/bytes';
import { type KeyBundle, keyRing, openEvent, sealEvent } from '../src/lib/wire';
import { type LibraryDescriptorEnvelope, type LibraryDescriptorPayload, libraryDescriptorAAD,
  normalizeLibraryDescriptor, openLibraryDescriptor, sealLibraryDescriptor } from '../src/lib/library-descriptor';

const fixture = JSON.parse(readFileSync(new URL('../../../tests/fixtures/library-descriptor/v1.json', import.meta.url), 'utf8'));
const context = { accountID: fixture.account_id as string, sourceID: fixture.source_id as string };
const envelope = fixture.envelope as LibraryDescriptorEnvelope;
const binding = { ...context, descriptorID: envelope.descriptor_id, revision: envelope.revision,
  mutationID: envelope.mutation_id, deviceID: envelope.device_id };
const otherID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const rawKey = fromHex(fixture.content_key_hex)!;
const bundle = (epoch = 7, contentKeys: KeyBundle['contentKeys'] = { '7': rawKey }, accountID = context.accountID): KeyBundle =>
  ({ accountID, epoch, contentKeys, managementToken: new Uint8Array(32) });
const vectors = [{ name: 'base', plaintext: fixture.plaintext, plaintext_utf8: fixture.plaintext_utf8,
  nonce_hex: fixture.nonce_hex, ...envelope, ciphertext_hex: fixture.ciphertext_hex }, ...fixture.additional_vectors];

/** Independent encryption permits authentic but invalid plaintext/AAD, without using the codec under test. */
function encryptNode(plaintext: Uint8Array | string, aad = fixture.aad_utf8): LibraryDescriptorEnvelope {
  const nonce = Buffer.from(fixture.nonce_hex, 'hex');
  const cipher = createCipheriv('aes-256-gcm', Buffer.from(fixture.derived_key_hex, 'hex'), nonce);
  cipher.setAAD(Buffer.from(aad, 'utf8'));
  const combined = Buffer.concat([nonce, cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
  return { ...envelope, ciphertext: combined.toString('base64'), sha256: createHash('sha256').update(combined).digest('hex') };
}

describe('library descriptor v1 independent wire vectors', () => {
  it.each(vectors)('reproduces and opens $name byte for byte', async vector => {
    const ring = await keyRing(bundle());
    expect(fromUtf8(libraryDescriptorAAD(context, envelope))).toBe(fixture.aad_utf8);
    const actual = await sealLibraryDescriptor(vector.plaintext, binding, ring, { nonce: fromHex(vector.nonce_hex)! });
    expect(actual).toEqual({ ...envelope, ciphertext: vector.ciphertext, sha256: vector.sha256 });
    expect(toHex(fromBase64(actual.ciphertext))).toBe(vector.ciphertext_hex);
    expect(await openLibraryDescriptor(actual, context, ring)).toEqual(vector.plaintext);
    // The independent writer authenticates the precise UTF-8 spelling, not only JSON equivalence.
    expect(await openLibraryDescriptor(encryptNode(vector.plaintext_utf8), context, ring)).toEqual(vector.plaintext);
  });

  it('uses random production nonces and omits an absent filename', async () => {
    const ring = await keyRing(bundle());
    const first = await sealLibraryDescriptor({ display_name: '  Attention\nheads ' }, binding, ring);
    const second = await sealLibraryDescriptor({ display_name: 'Attention heads' }, binding, ring);
    expect(first.ciphertext).not.toBe(second.ciphertext);
    expect(toHex(fromBase64(first.ciphertext).slice(0, 12))).not.toBe(fixture.nonce_hex);
    expect(await openLibraryDescriptor(first, context, ring)).toEqual({ display_name: 'Attention heads' });
    expect(await openLibraryDescriptor(second, context, ring)).toEqual({ display_name: 'Attention heads' });
  });

  it('keeps event and derived descriptor keys nonextractable and domain-separated', async () => {
    const ring = await keyRing(bundle());
    for (const key of [ring.keys.get(7)!, ring.descriptorKeys.get(7)!]) {
      expect(key.extractable).toBe(false);
      expect(key.algorithm).toEqual({ name: 'AES-GCM', length: 256 });
      await expect(crypto.subtle.exportKey('raw', key)).rejects.toThrow();
    }
    await expect(openLibraryDescriptor(envelope, context, { ...ring, descriptorKeys: ring.keys })).rejects.toThrow('corrupt_data');
    const event = await sealEvent({ kind: 'note', title: 'Synthetic' }, envelope.descriptor_id, envelope.device_id, ring);
    expect(await openEvent(event, ring)).toEqual({ kind: 'note', title: 'Synthetic' });
  });
});

describe('account and epoch binding', () => {
  it('opens historical epochs after rotation and seals only under the current epoch', async () => {
    const fresh = new Uint8Array(32).fill(0x89);
    const ring = await keyRing(bundle(8, { '7': rawKey, '8': fresh }));
    expect([...ring.descriptorKeys.keys()]).toEqual([7, 8]);
    expect(await openLibraryDescriptor(envelope, context, ring)).toEqual(fixture.plaintext);
    const revised = await sealLibraryDescriptor(fixture.plaintext, { ...binding, revision: 2, mutationID: otherID }, ring);
    expect(revised.epoch).toBe(8);
    expect(await openLibraryDescriptor(revised, context, ring)).toEqual(fixture.plaintext);
    await expect(openLibraryDescriptor(revised, context, await keyRing(bundle()))).rejects.toThrow('missing_key');
    await expect(openLibraryDescriptor(envelope, context, await keyRing(bundle(8, { '8': fresh })))).rejects.toThrow('missing_key');
    ring.descriptorKeys.delete(8);
    await expect(sealLibraryDescriptor(fixture.plaintext, binding, ring)).rejects.toThrow('missing_key');
  });

  it('refuses another account without losing the retained ciphertext', async () => {
    const ring = await keyRing(bundle()), before = JSON.stringify(envelope);
    const otherContext = { ...context, accountID: otherID };
    await expect(openLibraryDescriptor(envelope, otherContext, ring)).rejects.toThrow('wrong_account');
    await expect(sealLibraryDescriptor(fixture.plaintext, { ...binding, ...otherContext }, ring)).rejects.toThrow('wrong_account');
    const foreign = await keyRing(bundle(7, { '7': rawKey }, otherID));
    await expect(openLibraryDescriptor(envelope, otherContext, foreign)).rejects.toThrow('corrupt_data');
    // Even an otherwise correct key is bound to the account text in AAD.
    await expect(openLibraryDescriptor(envelope, otherContext, { ...ring, accountID: otherID })).rejects.toThrow('corrupt_data');
    expect(JSON.stringify(envelope)).toBe(before);
    expect(await openLibraryDescriptor(envelope, context, ring)).toEqual(fixture.plaintext);
  });

  it.each([
    ['account', 1, otherID], ['source', 2, 'upload:' + otherID], ['descriptor', 3, otherID], ['revision', 4, '2'],
    ['mutation', 5, otherID], ['device', 6, otherID], ['epoch', 7, '8'], ['format', 8, '2'],
  ])('authenticates the %s AAD field independently of the ciphertext digest', async (_field, index, replacement) => {
    const lines = fixture.aad_utf8.split('\n'); lines[index as number] = replacement;
    const altered = encryptNode(fixture.plaintext_utf8, lines.join('\n'));
    expect(await sha256Hex(fromBase64(altered.ciphertext))).toBe(altered.sha256);
    await expect(openLibraryDescriptor(altered, context, await keyRing(bundle()))).rejects.toThrow('corrupt_data');
  });

  it.each([0, 12, fromBase64(envelope.ciphertext).length - 1])('authenticates combined byte %s even with a recomputed digest', async index => {
    const bytes = fromBase64(envelope.ciphertext); bytes[index] ^= 1;
    const altered = { ...envelope, ciphertext: toBase64(bytes), sha256: await sha256Hex(bytes) };
    await expect(openLibraryDescriptor(altered, context, await keyRing(bundle()))).rejects.toThrow('corrupt_data');
  });

  it('rejects valid but mismatched sources and headers on the read path', async () => {
    const ring = await keyRing(bundle(8, { '7': rawKey, '8': rawKey }));
    await expect(openLibraryDescriptor(envelope, { ...context, sourceID: 'openalex:W123' }, ring)).rejects.toThrow('corrupt_data');
    for (const change of [{ descriptor_id: otherID }, { revision: 2 }, { mutation_id: otherID }, { device_id: otherID }, { epoch: 8 }]) {
      await expect(openLibraryDescriptor({ ...envelope, ...change }, context, ring)).rejects.toThrow('corrupt_data');
    }
    await expect(openLibraryDescriptor({ ...envelope, format: 2 }, context, ring)).rejects.toThrow('unsupported_format');
  });
});

describe('strict canonical envelope', () => {
  it.each(['descriptor_id', 'mutation_id', 'device_id'])('rejects noncanonical %s UUID spelling', async key => {
    const ring = await keyRing(bundle());
    for (const value of [otherID.toUpperCase(), ' ' + otherID, otherID + '\n', otherID.replaceAll('-', ''), '', 1, null]) {
      await expect(openLibraryDescriptor({ ...envelope, [key]: value }, context, ring)).rejects.toThrow('corrupt_data');
    }
  });

  it.each(['revision', 'epoch'])('requires a positive Int32 %s', async key => {
    const ring = await keyRing(bundle());
    for (const value of [0, -1, 1.5, 2_147_483_648, NaN, Infinity, '1', null]) {
      await expect(openLibraryDescriptor({ ...envelope, [key]: value }, context, ring)).rejects.toThrow('corrupt_data');
    }
    expect(() => libraryDescriptorAAD(context, { ...envelope, [key]: 2_147_483_647 })).not.toThrow();
  });

  it('rejects missing and extra envelope keys and malformed digest/base64', async () => {
    const ring = await keyRing(bundle());
    for (const key of Object.keys(envelope)) {
      const missing = { ...envelope } as Record<string, unknown>; delete missing[key];
      await expect(openLibraryDescriptor(missing, context, ring)).rejects.toThrow('corrupt_data');
    }
    for (const value of [null, [], { ...envelope, extra: 1 }, { ...envelope, sha256: envelope.sha256.toUpperCase() },
      { ...envelope, sha256: '0'.repeat(64) }, { ...envelope, sha256: envelope.sha256 + '\n' },
      { ...envelope, ciphertext: envelope.ciphertext.replaceAll('/', '_') },
      { ...envelope, ciphertext: envelope.ciphertext.replace(/=+$/, '') },
      { ...envelope, ciphertext: envelope.ciphertext + '\n' },
      // Nonzero unused pad bits decode to the same bytes in permissive base64 parsers.
      { ...envelope, ciphertext: envelope.ciphertext.replace(/Rg==$/, 'Rh==') },
      { ...envelope, ciphertext: toBase64(new Uint8Array(27)) },
      { ...envelope, ciphertext: toBase64(new Uint8Array(4_125)) }]) {
      await expect(openLibraryDescriptor(value, context, ring)).rejects.toThrow('corrupt_data');
    }
  });

  it('bounds source identities to 1–128 visible ASCII bytes without changing their spelling', async () => {
    const ring = await keyRing(bundle());
    for (const sourceID of ['', 'a'.repeat(129), 'upload:' + otherID + '\n', 'openalex:W1\r', ' space', 'tab\tid', 'é', '\x7f', '\u0085']) {
      await expect(sealLibraryDescriptor(fixture.plaintext, { ...binding, sourceID }, ring)).rejects.toThrow('corrupt_data');
      await expect(openLibraryDescriptor(envelope, { ...context, sourceID }, ring)).rejects.toThrow('corrupt_data');
    }
    for (const sourceID of ['a'.repeat(128), 'openalex:W123', '2305.18290', 'hep-th/9901001']) {
      const sealed = await sealLibraryDescriptor(fixture.plaintext, { ...binding, sourceID }, ring);
      expect(await openLibraryDescriptor(sealed, { ...context, sourceID }, ring)).toEqual(fixture.plaintext);
    }
    await expect(sealLibraryDescriptor(fixture.plaintext, { ...binding, accountID: otherID.toUpperCase() }, ring)).rejects.toThrow('corrupt_data');
  });
});

describe('scalar normalization and canonical plaintext', () => {
  it.each(fixture.normalization_cases)('matches the independent normalization case $input', vector => {
    if (vector.error) expect(() => normalizeLibraryDescriptor({ display_name: vector.input })).toThrow('corrupt_data');
    else expect(normalizeLibraryDescriptor({ display_name: vector.input })).toEqual({ display_name: vector.expected });
  });

  it('uses only the fixed whitespace set, preserves combining/non-BMP scalars and filename spacing', async () => {
    const whitespace = [9, 10, 11, 12, 13, 32, 0x85, 0xa0, 0x1680, ...Array.from({ length: 11 }, (_, i) => 0x2000 + i),
      0x2028, 0x2029, 0x202f, 0x205f, 0x3000].map(v => String.fromCodePoint(v)).join('');
    expect(normalizeLibraryDescriptor({ display_name: whitespace + 'A' + whitespace + 'B' + whitespace })).toEqual({ display_name: 'A B' });
    const exact = { display_name: '\ufeff\u180e\u200b🧠Cafe\u0301', filename: '  🧠 notes\u2028draft.pdf\u3000 ' };
    expect(normalizeLibraryDescriptor(exact)).toEqual(exact);
    const ring = await keyRing(bundle());
    expect(await openLibraryDescriptor(await sealLibraryDescriptor(exact, binding, ring), context, ring)).toEqual(exact);
  });

  it('counts Unicode scalars and enforces the exact field limits', async () => {
    const maximum = { display_name: '🧠'.repeat(500), filename: '🧠'.repeat(255) };
    expect(normalizeLibraryDescriptor(maximum)).toEqual(maximum);
    const ring = await keyRing(bundle());
    expect(await openLibraryDescriptor(await sealLibraryDescriptor(maximum, binding, ring), context, ring)).toEqual(maximum);
    for (const value of [{ display_name: '🧠'.repeat(501) }, { display_name: 'e\u0301'.repeat(251) },
      { display_name: 'valid', filename: '🧠'.repeat(256) }, { display_name: '' }, { display_name: '\t\u3000' }]) {
      expect(() => normalizeLibraryDescriptor(value)).toThrow('corrupt_data');
    }
  });

  it('rejects every filename control and unpaired surrogate instead of repairing it', () => {
    for (const code of [...Array.from({ length: 32 }, (_, i) => i), ...Array.from({ length: 33 }, (_, i) => 127 + i)]) {
      expect(() => normalizeLibraryDescriptor({ display_name: 'valid', filename: 'a' + String.fromCharCode(code) })).toThrow('corrupt_data');
    }
    for (const filename of ['', ' \u00a0\u2028\u3000', '\ud800', 'a\udfff', '\ud800x', '\udfff\ud800']) {
      expect(() => normalizeLibraryDescriptor({ display_name: 'valid', filename })).toThrow('corrupt_data');
    }
  });

  it.each([
    '{"filename":"attention-draft.pdf","display_name":"Attention and α — draft"}',
    '{ "display_name":"Attention and α — draft","filename":"attention-draft.pdf"}',
    '{"display_name":"Attention and α — draft","filename":"attention-draft.pdf","extra":1}',
    '{"display_name":"first","display_name":"second"}',
    '{"display_name":"\\u0041ttention"}',
    '{"display_name":"a\\/b"}',
    '{"display_name":"a\\ud83e\\udde0"}',
    '{"display_name":"\\ud800"}', '{"display_name":"\\udfff"}',
    '{"display_name":" title "}', '{"display_name":"two  spaces"}',
    '{"display_name":"a\\nb"}', '{"display_name":"title","filename":null}',
    '{"display_name":"title","filename":"file\\nname"}', '{"filename":"file.pdf"}',
    '{"display_name":1}', '[]', 'null', '', '\ufeff{"display_name":"title"}',
  ])('refuses authentic noncanonical or invalid plaintext %j', async plaintext => {
    await expect(openLibraryDescriptor(encryptNode(plaintext), context, await keyRing(bundle()))).rejects.toThrow('corrupt_data');
  });

  it('rejects invalid UTF-8 and overlength authenticated plaintext', async () => {
    const ring = await keyRing(bundle());
    for (const plaintext of [Uint8Array.from([0x7b, 0xff, 0x7d]), Uint8Array.from([0xed, 0xa0, 0x80]), new Uint8Array(4_097).fill(0x20)]) {
      await expect(openLibraryDescriptor(encryptNode(plaintext), context, ring)).rejects.toThrow('corrupt_data');
    }
    for (const value of [{ display_name: 'valid', filename: undefined }, { display_name: 'valid', filename: null },
      { display_name: 'valid', extra: 1 }, { display_name: 1 }]) {
      expect(() => normalizeLibraryDescriptor(value as LibraryDescriptorPayload)).toThrow('corrupt_data');
    }
  });
});
