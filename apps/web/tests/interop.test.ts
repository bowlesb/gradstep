// WebCrypto ⇄ Swift (CryptoKit) interoperability for encrypted wire format 1.
// Uses the frozen, public, Swift-tested fixture and the Swift ScienceReaderWireCheck
// executable. Fixed keys/nonces here are public test vectors, never user data.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { fromBase64, toBase64, toHex, canonicalJSON, utf8 } from '../src/lib/bytes';
import { approvalPayload } from '../src/lib/approval';
import { type PrivateEvent, decodeEvent, encodeDiagram, encodeEvent } from '../src/lib/events';
import { type KeyBundle, decodeBundle, enrollmentFingerprint, generateDeviceKeyPair, importTestPrivateKey, keyRing, openEvent, recover, sealEvent,
  unwrapForDevice, wrapForDevice, wrapRecovery } from '../src/lib/wire';

const core = new URL('../../apple/ScienceReaderCore/', import.meta.url);
const fixture = JSON.parse(readFileSync(new URL('Tests/ScienceReaderCoreTests/Fixtures/envelopes-v1.json', core), 'utf8'));
const account = '11111111-2222-4333-8444-555555555555', device = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', event = '12345678-abcd-4abc-8def-123456789abc';
const bytes = (start: number, length = 32) => Uint8Array.from({ length }, (_, i) => (start + i) & 255);
const bundle = (): KeyBundle => decodeBundle(utf8(canonicalJSON(fixture.keys)), account);
const challenge = fromBase64(fixture.challenge), rawPrivate = fromBase64(fixture.privateKey);

describe('frozen Swift-tested fixture (envelopes-v1.json)', () => {
  it('reproduces every envelope byte for byte from the fixed test vectors', async () => {
    expect(fixture.challenge).toBe(toBase64(bytes(0x60)));
    const keys = bundle(), ring = await keyRing(keys), recipient = await importTestPrivateKey(rawPrivate);
    const sealed = await sealEvent(fixture.payload, event, device, ring, { nonce: bytes(0, 12) });
    expect(toBase64(sealed.ciphertext)).toBe(fixture.eventCiphertext);
    expect(toBase64(await wrapRecovery(keys, fixture.recoveryCode, { nonce: bytes(0x10, 12) }))).toBe(fixture.recoveryPackage);
    expect(toBase64(await wrapForDevice(keys, device, recipient.publicKey, challenge, { ephemeralPrivate: bytes(0xe0), nonce: bytes(0x30, 12) })))
      .toBe(fixture.deviceEnvelope);
  });

  it('opens the fixture event, recovery package and device envelope', async () => {
    const keys = bundle(), ring = await keyRing(keys), recipient = await importTestPrivateKey(rawPrivate);
    expect(await openEvent({ id: event, deviceID: device, epoch: 1, format: 1, ciphertext: fromBase64(fixture.eventCiphertext) }, ring)).toEqual(fixture.payload);
    expect(await recover(fromBase64(fixture.recoveryPackage), fixture.recoveryCode, account)).toEqual(keys);
    // Display spelling of the same code (groups, uppercase, whitespace) derives the same key.
    const display = fixture.recoveryCode.toUpperCase().match(/.{8}/g).join('-  ');
    expect(await recover(fromBase64(fixture.recoveryPackage), display, account)).toEqual(keys);
    expect(await unwrapForDevice(fromBase64(fixture.deviceEnvelope), account, device, 1, recipient.privateKey, recipient.publicKey, challenge)).toEqual(keys);
  });

  it('rejects the wrong account, device, epoch, code, format and any tampering', async () => {
    const keys = bundle(), ring = await keyRing(keys), recipient = await importTestPrivateKey(rawPrivate);
    const envelope = { id: event, deviceID: device, epoch: 1, format: 1, ciphertext: fromBase64(fixture.eventCiphertext) };
    const other = '00000000-0000-4000-8000-000000000001';
    await expect(openEvent({ ...envelope, deviceID: other }, ring)).rejects.toThrow('corrupt_data');
    await expect(openEvent({ ...envelope, id: other }, ring)).rejects.toThrow('corrupt_data');
    await expect(openEvent({ ...envelope, format: 3 }, ring)).rejects.toThrow('unsupported_format');
    await expect(openEvent(envelope, { ...ring, accountID: other })).rejects.toThrow('corrupt_data');
    const flipped = envelope.ciphertext.slice(); flipped[20] ^= 1;
    await expect(openEvent({ ...envelope, ciphertext: flipped }, ring)).rejects.toThrow('corrupt_data');
    await expect(recover(fromBase64(fixture.recoveryPackage), toHex(bytes(0xb1)), account)).rejects.toThrow('invalid_recovery_code');
    await expect(recover(fromBase64(fixture.recoveryPackage), fixture.recoveryCode, other)).rejects.toThrow();
    await expect(recover(fromBase64(fixture.recoveryPackage), 'not-a-code', account)).rejects.toThrow('invalid_recovery_code');
    const wrapped = fromBase64(fixture.deviceEnvelope);
    await expect(unwrapForDevice(wrapped, account, other, 1, recipient.privateKey, recipient.publicKey, challenge)).rejects.toThrow();
    await expect(unwrapForDevice(wrapped, account, device, 2, recipient.privateKey, recipient.publicKey, challenge)).rejects.toThrow();
    await expect(unwrapForDevice(wrapped, account, device, 1, recipient.privateKey, recipient.publicKey, bytes(0x61))).rejects.toThrow();
    const damaged = wrapped.slice(); damaged[damaged.length - 1] ^= 1;
    await expect(unwrapForDevice(damaged, account, device, 1, recipient.privateKey, recipient.publicKey, challenge)).rejects.toThrow('corrupt_data');
    // A structurally valid bundle for another account is refused after decryption.
    const foreign = { ...keys, accountID: other };
    await expect(recover(await wrapRecovery(foreign, fixture.recoveryCode), fixture.recoveryCode, account)).rejects.toThrow();
  });
});

// Builds and runs the Swift package's ScienceReaderWireCheck (as scripts/check-wire.mjs does).
const swift = (() => { try { execFileSync('swift', ['--version'], { stdio: 'ignore' }); return true; } catch { return false; } })();

describe.runIf(swift)('Swift CryptoKit ⇄ WebCrypto, fresh random envelopes both ways', () => {
  it('Swift opens WebCrypto envelopes, WebCrypto opens Swift envelopes, and Swift approves a browser key from its QR payload', async () => {
    const keys = bundle(), ring = await keyRing(keys), recipient = await importTestPrivateKey(rawPrivate);
    const input = {
      keys: fixture.keys, payload: fixture.payload, eventID: event, deviceID: device, challenge: fixture.challenge, privateKey: fixture.privateKey,
      recoveryCode: fixture.recoveryCode,
      eventCiphertext: toBase64((await sealEvent(fixture.payload, event, device, ring)).ciphertext),
      recoveryPackage: toBase64(await wrapRecovery(keys, fixture.recoveryCode)),
      deviceEnvelope: toBase64(await wrapForDevice(keys, device, recipient.publicKey, challenge)),
    };
    // QR approval: this browser's real, non-extractable key as its QR payload names it; Swift approves as the app does.
    const browser = await generateDeviceKeyPair(), browserChallenge = crypto.getRandomValues(new Uint8Array(32)), requestID = crypto.randomUUID();
    const qr = await approvalPayload({ requestID, account, deviceID: device, publicKey: browser.publicKey, challenge: browserChallenge, kind: 'w' });
    const approval = { payload: qr.payload, requestID, deviceID: device, publicKey: toBase64(browser.publicKey), challenge: toBase64(browserChallenge) };
    // Fresh randomness: none of these may equal the frozen fixture.
    expect(input.eventCiphertext).not.toBe(fixture.eventCiphertext);
    expect(input.deviceEnvelope).not.toBe(fixture.deviceEnvelope);
    // The executable throws (non-zero exit) unless it decrypts all three to exactly these keys/payload.
    const stdout = execFileSync('swift', ['run', '--package-path', fileURLToPath(core), 'ScienceReaderWireCheck'],
      { input: JSON.stringify({ ...input, approval }), encoding: 'utf8', timeout: 600_000, maxBuffer: 1024 * 1024, stdio: ['pipe', 'pipe', 'ignore'] });
    const output = JSON.parse(stdout);
    expect(output.eventCiphertext).not.toBe(input.eventCiphertext);
    expect(await openEvent({ id: event, deviceID: device, epoch: 1, format: 1, ciphertext: fromBase64(output.eventCiphertext) }, ring)).toEqual(fixture.payload);
    expect(await recover(fromBase64(output.recoveryPackage), fixture.recoveryCode, account)).toEqual(keys);
    expect(await unwrapForDevice(fromBase64(output.deviceEnvelope), account, device, 1, recipient.privateKey, recipient.publicKey, challenge)).toEqual(keys);
    expect(output.approval.code).toBe(qr.code);
    expect(output.approval.refusedSubstitute).toBe(true);
    expect(browser.privateKey.extractable).toBe(false);
    expect(await unwrapForDevice(fromBase64(output.approval.envelope), account, device, 1, browser.privateKey, browser.publicKey, browserChallenge)).toEqual(keys);
    expect(output.fingerprint).toBe(await enrollmentFingerprint(account, device, recipient.publicKey, challenge));
  }, 600_000);

  // Browser chat history: events the web writes (a conversation with its passage, a question, an interrupted answer
  // with a time, a diagram) decode in Swift's PrivateEvent, and Swift's re-sealed copies decode here to the same events.
  it('Swift decodes the browser’s chat events and the browser decodes Swift’s', async () => {
    const keys = bundle(), ring = await keyRing(keys), recipient = await importTestPrivateKey(rawPrivate);
    const conversation = 'cccccccc-0000-4000-8000-000000000001', documentID = 'dddddddd-0000-4000-8000-000000000002', answer = 'eeeeeeee-0000-4000-8000-000000000003';
    const events: PrivateEvent[] = [
      { kind: 'conversation', entityID: conversation, parents: [], documentID, text: 'Explain in plain terms, including any symbols: \\(\\beta\\) controls…', createdAt: 1_791_400_000_000,
        anchor: { artifactID: 'aaaaaaaa-0000-4000-8000-000000000004', quote: '\\(\\beta\\) controls the deviation', prefix: 'the parameter ', suffix: ' from the base', elementID: 'b-e8b10bc14510-24' } },
      { kind: 'message', entityID: 'bbbbbbbb-0000-4000-8000-000000000005', parents: [event], conversationID: conversation, documentID, text: 'What is β? “quoted” – ∑ 中文', role: 'user', status: 'complete', createdAt: 1_791_400_000_001 },
      { kind: 'message', entityID: answer, parents: [event], conversationID: conversation, text: 'Partial **answer** with \\[x^2\\]', role: 'assistant', status: 'interrupted', createdAt: 1_791_400_000_002 },
      { kind: 'diagram', entityID: 'ffffffff-0000-4000-8000-000000000006', parents: [], conversationID: conversation, text: encodeDiagram({ title: 'Flow', source: 'graph TD; A-->B', messageID: answer }) },
    ];
    for (const payload of events) {
      const input = {
        keys: fixture.keys, payload: encodeEvent(payload), eventID: event, deviceID: device, challenge: fixture.challenge, privateKey: fixture.privateKey,
        recoveryCode: fixture.recoveryCode, eventCiphertext: toBase64((await sealEvent(encodeEvent(payload), event, device, ring)).ciphertext),
        recoveryPackage: toBase64(await wrapRecovery(keys, fixture.recoveryCode)), deviceEnvelope: toBase64(await wrapForDevice(keys, device, recipient.publicKey, challenge)),
      };
      const stdout = execFileSync('swift', ['run', '--package-path', fileURLToPath(core), 'ScienceReaderWireCheck'],
        { input: JSON.stringify(input), encoding: 'utf8', timeout: 600_000, maxBuffer: 1024 * 1024, stdio: ['pipe', 'pipe', 'ignore'] });
      const output = JSON.parse(stdout);
      expect(decodeEvent(await openEvent({ id: event, deviceID: device, epoch: 1, format: 1, ciphertext: fromBase64(output.eventCiphertext) }, ring))).toEqual(decodeEvent(encodeEvent(payload)));
    }
  }, 600_000);
});
