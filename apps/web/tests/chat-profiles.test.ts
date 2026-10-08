// Chat model/effort/length, answer labels and topic titles (2026-10-08): the browser mirrors ChatProfiles.swift,
// ChatStream.swift and PrivateState.swift, checked against the same public fixtures the Swift tests use.
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { canonicalJSON, fromBase64, toBase64, utf8 } from '../src/lib/bytes';
import { SSEParser, makeRequest, requestBody, streamLabel } from '../src/lib/chat';
import { answeredBy, decodeProfileTable, estimateText, modelName, parseProfileID, profileID, profileSummary, ProfileTableLoader, STANDARD_PROFILE,
  tableEstimate, type ProfileChoice } from '../src/lib/chat-profiles';
import { cleanTopicTitle, decodeEvent, encodeEvent, GENERATED_TITLE, PrivateState, RENAMED_TITLE, type PrivateEvent } from '../src/lib/events';
import { decodeBundle, keyRing, openEvent, sealEvent } from '../src/lib/wire';

const fixtures = new URL('../../apple/ScienceReaderCore/Tests/ScienceReaderCoreTests/Fixtures/', import.meta.url);
const read = (name: string) => JSON.parse(readFileSync(new URL(name, fixtures), 'utf8'));
const envelopes = read('envelopes-v1.json'), labelled = read('labelled-events-v1.json') as { eventID: string; payload: Record<string, unknown>; ciphertext: string }[];
const published = read('chat-profiles-v1.json');
const account = '11111111-2222-4333-8444-555555555555';
const bytes = (start: number, length = 32) => Uint8Array.from({ length }, (_, i) => (start + i) & 255);

describe('labelled events (labelled-events-v1.json, sealed by Node, read by Swift)', () => {
  it('open, decode and re-seal byte for byte with the new keys', async () => {
    const ring = await keyRing(decodeBundle(utf8(canonicalJSON(envelopes.keys)), account));
    expect(labelled).toHaveLength(4);
    for (const [index, item] of labelled.entries()) {
      const envelope = { id: item.eventID, deviceID: envelopes.deviceID, epoch: 1, format: 1, ciphertext: fromBase64(item.ciphertext) };
      const opened = await openEvent(envelope, ring);
      expect(opened).toEqual(item.payload);
      const event = decodeEvent(opened);
      expect(encodeEvent(event)).toEqual(item.payload);
      const sealed = await sealEvent(encodeEvent(event), item.eventID, envelopes.deviceID, ring, { nonce: bytes(0x40 + index, 12) });
      expect(toBase64(sealed.ciphertext)).toBe(item.ciphertext);
    }
    const events = labelled.map(e => decodeEvent(e.payload));
    expect(events[0].titleSource).toBe(GENERATED_TITLE); expect(events[1].titleSource).toBe(RENAMED_TITLE);
    expect(events[2].titleSource).toBe('imported-by-a-later-build');
    expect([events[3].model, events[3].profile]).toEqual(['claude-sonnet-5', 'opus-high-detailed']);
  });
  it('bounds labels at 64 UTF-8 bytes on every kind, as Swift does, and refuses non-strings', () => {
    const base = labelled[3].payload;
    expect(() => decodeEvent({ ...base, model: 'x'.repeat(65) })).toThrow();
    expect(() => decodeEvent({ ...base, profile: 'é'.repeat(33) })).toThrow();
    expect(() => decodeEvent({ ...base, titleSource: 7 })).toThrow();
    expect(decodeEvent({ ...base, titleSource: 'anything', model: 'm'.repeat(64) }).titleSource).toBe('anything');
    expect(decodeEvent({ ...envelopes.payload, profile: null }).profile).toBeUndefined();
  });
});

describe('the published profile table (chat-profiles-v1.json)', () => {
  const table = decodeProfileTable(published)!;
  it('decodes with its estimates and labels', () => {
    expect(table.version).toBe('chat-profiles-v1'); expect(table.defaultChoice).toEqual(STANDARD_PROFILE); expect(table.estimates.size).toBe(27);
    expect(tableEstimate(table, STANDARD_PROFILE)).toBe('Usually 4–24 credits · up to 37');
    expect(tableEstimate(table, { model: 'haiku', effort: 'low', length: 'brief' })).toBe('Usually 1–2 credits · up to 2');
    expect(tableEstimate(table, { model: 'opus', effort: 'high', length: 'detailed' })).toBe('Usually 24–63 credits · up to 114');
    expect(estimateText({ low: 1, high: 1, max: 1 })).toBe('About 1 credit · up to 1');
    expect(profileSummary({ model: 'opus', effort: 'medium', length: 'detailed' }, table)).toBe('Opus · Medium · Detailed');
    expect(table.note).toContain('Web searches');
  });
  it('refuses another version, a missing default or an oversized table; skips what it does not know', () => {
    expect(decodeProfileTable({ ...published, version: 'chat-profiles-v2' })).toBeNull();
    expect(decodeProfileTable({})).toBeNull(); expect(decodeProfileTable(null)).toBeNull();
    expect(decodeProfileTable({ ...published, profiles: published.profiles.filter((p: { id: string }) => p.id !== 'sonnet-low-standard') })).toBeNull();
    expect(decodeProfileTable({ ...published, padding: 'x'.repeat(70_000) })).toBeNull();
    const fewer = decodeProfileTable({ ...published, profiles: [...published.profiles.filter((p: { model: string }) => p.model !== 'opus'),
      { model: 'fable', effort: 'low', length: 'brief', credits: { low: 1, high: 2, max: 3 } },
      { model: 'haiku', effort: 'low', length: 'brief', credits: { low: 5, high: 2, max: 3 } }] })!;
    expect(fewer.estimates.size).toBe(18);
    expect(tableEstimate(fewer, { model: 'opus', effort: 'low', length: 'standard' })).toBeNull();
    expect(tableEstimate(fewer, { model: 'haiku', effort: 'low', length: 'brief' })).toBe('Usually 1–2 credits · up to 2');
  });
  it('is fetched once per login and a failure is retried later', async () => {
    let calls = 0, fail = true;
    const loader = new ProfileTableLoader(account, new AbortController().signal, async () => { calls++; if (fail) throw new Error('offline'); return published; });
    expect(await loader.load()).toBeNull(); fail = false;
    expect((await loader.load())?.version).toBe('chat-profiles-v1'); await loader.load();
    expect(calls).toBe(2);
  });
});

describe('choices, labels and requests', () => {
  it('round-trips profile identifiers and names the answering model', () => {
    for (const model of ['haiku', 'sonnet', 'opus'] as const) for (const effort of ['low', 'medium', 'high'] as const)
      for (const length of ['brief', 'standard', 'detailed'] as const) expect(parseProfileID(profileID({ model, effort, length }))).toEqual({ model, effort, length });
    for (const id of ['diagram_fix', 'sonnet-low', 'sonnet-low-standard-x', 'fable-low-brief', '', undefined]) expect(parseProfileID(id)).toBeNull();
    expect(answeredBy('claude-sonnet-5-5', 'sonnet-low-standard')).toBe('Sonnet · Low · Standard');
    expect(answeredBy('claude-sonnet-5', 'sonnet-medium-brief')).toBe('Sonnet · Medium · Brief · by Claude Sonnet 5');
    expect(answeredBy('claude-opus-4-8', 'opus-high-detailed')).toBe('Opus · High · Detailed · by Claude Opus 4.8');
    expect(answeredBy('claude-opus-5-5', undefined)).toBe('Claude Opus 5.5');
    expect(answeredBy(undefined, 'haiku-low-brief')).toBe('Haiku · Low · Brief');
    expect(answeredBy(undefined, undefined)).toBeNull();
    expect(answeredBy('claude-sonnet-5-5', 'diagram_fix')).toBe('Claude Sonnet 5.5');
    expect(modelName('claude-haiku-4-5-20251001')).toBe('Claude Haiku 4.5');
  });
  it('sends a choice only when it is not the default, and a title request only when asked', () => {
    const turns = [{ role: 'user' as const, text: 'Why?' }];
    const plain = requestBody(makeRequest('op', null, turns, null));
    expect(plain.profile).toBeUndefined(); expect(plain.topic_title).toBeUndefined();
    expect(requestBody(makeRequest('op', null, turns, null, null, { profile: STANDARD_PROFILE })).profile).toBeUndefined();
    const chosen: ProfileChoice = { model: 'opus', effort: 'high', length: 'detailed' };
    const body = requestBody(makeRequest('op', 'd', turns, null, null, { profile: chosen, topicTitle: true }));
    expect(body.profile).toEqual(chosen); expect(body.topic_title).toBe(true);
  });
  it('parses title and labelled done events; a bad title or label is dropped, never fatal', () => {
    const parser = new SSEParser();
    const text = ['event: title\ndata: {"text":"Explainer for\\u202e a persona\\npaper"}\n\n', 'event: title\ndata: {"text":"   "}\n\n',
      'event: title\ndata: {"nope":1}\n\n',
      'event: done\ndata: {"stop_reason":"end_turn","credits":3,"usage":{},"model":"claude-opus-5-5","profile":"opus-high-detailed"}\n\n',
      `event: done\ndata: {"stop_reason":"end_turn","credits":1,"model":"Bad Model!","profile":"${'x'.repeat(65)}"}\n\n`,
      'event: done\ndata: {"stop_reason":"end_turn","credits":2}\n\n'].join('');
    expect(parser.consume(new TextEncoder().encode(text))).toEqual([
      { type: 'title', text: 'Explainer for a persona paper' },
      { type: 'done', stopReason: 'end_turn', credits: 3, model: 'claude-opus-5-5', profile: 'opus-high-detailed' },
      { type: 'done', stopReason: 'end_turn', credits: 1 },
      { type: 'done', stopReason: 'end_turn', credits: 2 },
    ]);
    expect(streamLabel('sonnet-low-standard')).toBe('sonnet-low-standard'); expect(streamLabel('a b')).toBeUndefined();
  });
  it('cleans topic titles to one bounded line', () => {
    expect(cleanTopicTitle('  Why DPO\n needs\tno reward model  ')).toBe('Why DPO needs no reward model');
    expect(cleanTopicTitle('⁦Hidden⁩ bidi')).toBe('Hidden bidi');
    expect(cleanTopicTitle(' \n ')).toBeNull();
    expect(cleanTopicTitle('a'.repeat(120))).toHaveLength(80);
  });
});

describe('a topic title is a new conversation revision', () => {
  const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
  it('keeps the paper, passage and start; concurrent titles resolve to a later rename', () => {
    const state = new PrivateState(), device = id(800), conversation = id(1), paper = id(2), anchor = { artifactID: id(3), quote: 'softmax(QKᵀ/√d)', prefix: '', suffix: '' };
    const root: PrivateEvent = { kind: 'conversation', entityID: conversation, parents: [], documentID: paper, text: 'Explain in plain terms, including any symbols: softmax', anchor, createdAt: 1_790_000_000_000 };
    state.apply({ id: id(10), deviceID: device, payload: root });
    state.apply({ id: id(11), deviceID: device, payload: { kind: 'message', entityID: id(20), parents: [id(10)], conversationID: conversation, documentID: paper, text: 'Q', role: 'user', status: 'complete' } });
    expect(state.conversationSummaries()[0].titleSource).toBeUndefined();
    const generated = state.titledConversation(conversation, ' Scaled  attention\nexplained ', GENERATED_TITLE)!;
    expect(generated).toEqual({ kind: 'conversation', entityID: conversation, parents: [id(10)], documentID: paper, anchor, createdAt: 1_790_000_000_000,
      text: 'Scaled attention explained', titleSource: 'generated' });
    state.apply({ id: id(12), deviceID: device, payload: generated });
    const summary = state.conversationSummaries()[0];
    expect([summary.title, summary.titleSource, summary.documentID, summary.startedAt, summary.messageCount]).toEqual(['Scaled attention explained', 'generated', paper, 1_790_000_000_000, 1]);
    expect(state.conversationBranches(conversation)[0].complete).toBe(true);
    state.apply({ id: id(13), deviceID: id(801), payload: { ...state.titledConversation(conversation, 'Other device', GENERATED_TITLE)!, parents: [id(10)] } });
    expect(state.revisions(conversation)).toHaveLength(2);
    const renamed = state.titledConversation(conversation, 'My notes', RENAMED_TITLE)!;
    expect(new Set(renamed.parents)).toEqual(new Set([id(12), id(13)]));
    state.apply({ id: id(14), deviceID: device, payload: renamed });
    expect(state.conversationSummaries()[0]).toMatchObject({ title: 'My notes', titleSource: 'renamed' });
    expect(state.titledConversation(conversation, '  ', RENAMED_TITLE)).toBeNull();
    expect(state.titledConversation(id(99), 'x', RENAMED_TITLE)).toBeNull();
  });
});
