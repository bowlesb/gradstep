// Chat model/effort/length, answer labels and topic titles (2026-10-08): the browser mirrors ChatProfiles.swift,
// ChatStream.swift and PrivateState.swift, checked against the same public fixtures the Swift tests use.
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { canonicalJSON, fromBase64, toBase64, utf8 } from '../src/lib/bytes';
import { SSEParser, composerPlaceholder, conversationPreview, makeRequest, requestBody, streamLabel } from '../src/lib/chat';
import { answeredBy, available, decodeProfileTable, estimateText, hasAutoEffort, listedModels, modelName, modelProvider, offersModelLength, parseProfileID, profileID, profileSummary, ProfileTableLoader, requestProfile, sameChoice, STANDARD_PROFILE, typicalEstimate, withChoice,
  tableEstimate, type ProfileChoice } from '../src/lib/chat-profiles';
import { cleanTopicTitle, decodeEvent, encodeEvent, GENERATED_TITLE, PrivateState, RENAMED_TITLE, type PrivateEvent } from '../src/lib/events';
import { decodeBundle, keyRing, openEvent, sealEvent } from '../src/lib/wire';

const fixtures = new URL('../../apple/ScienceReaderCore/Tests/ScienceReaderCoreTests/Fixtures/', import.meta.url);
const read = (name: string) => JSON.parse(readFileSync(new URL(name, fixtures), 'utf8'));
const envelopes = read('envelopes-v1.json'), labelled = JSON.parse(readFileSync(new URL('./fixtures/labelled-events-v1.json', import.meta.url), 'utf8')) as { eventID: string; payload: Record<string, unknown>; ciphertext: string }[];
// The table builds 57/58 shipped with (no additions) and the table staging serves since 2026-10-16 (auto, DeepSeek).
const published = JSON.parse(readFileSync(new URL('../../../tests/fixtures/chat-profiles-v1-build57.json', import.meta.url), 'utf8'));
const publishedAuto = JSON.parse(readFileSync(new URL('./fixtures/chat-profiles-v1.json', import.meta.url), 'utf8'));
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
    expect(profileSummary({ model: 'opus', effort: 'medium', length: 'detailed' }, table)).toBe('Opus · Detailed');
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
  it('copies the selected request and excludes profile and title options from diagram repair', () => {
    const choice: ProfileChoice = { model: 'opus', effort: 'high', length: 'detailed' };
    const request = makeRequest(crypto.randomUUID(), null, [{ role: 'user', text: 'question' }], null, null, { profile: choice });
    choice.model = 'haiku'; expect(request.profile.model).toBe('opus');
    const repair = makeRequest(crypto.randomUUID(), null, [{ role: 'user', text: 'repair' }], 'diagram', 'diagram_fix', { profile: choice, topicTitle: true });
    expect(requestBody(repair)).not.toHaveProperty('profile'); expect(requestBody(repair)).not.toHaveProperty('topic_title');
  });
  it('round-trips profile identifiers and names the answering model', () => {
    for (const model of ['haiku', 'sonnet', 'opus'] as const) for (const effort of ['low', 'medium', 'high'] as const)
      for (const length of ['brief', 'standard', 'detailed'] as const) expect(parseProfileID(profileID({ model, effort, length }))).toEqual({ model, effort, length });
    for (const id of ['diagram_fix', 'sonnet-low', 'sonnet-low-standard-x', 'fable-low-brief', 'sonnet-auto-standard', '', undefined]) expect(parseProfileID(id)).toBeNull();
    expect(answeredBy('claude-sonnet-5-5', 'sonnet-low-standard')).toBe('Sonnet · Standard');
    expect(answeredBy('claude-sonnet-5', 'sonnet-medium-brief')).toBe('Sonnet · Brief · by Claude Sonnet 5');
    expect(answeredBy('claude-opus-4-8', 'opus-high-detailed')).toBe('Opus · Detailed · by Claude Opus 4.8');
    expect(answeredBy('claude-opus-5-5', undefined)).toBe('Claude Opus 5.5');
    expect(answeredBy(undefined, 'haiku-low-brief')).toBe('Haiku · Brief');
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

// Chat redesign from build 57 (CHAT.md, 2026-10-16): the reader picks the model and length; effort is automatic where
// the server's table offers `auto` (servers from 2026-10-16), and requests keep the stored effort where it doesn't.
describe('automatic effort and DeepSeek in the published table', () => {
  const plain = decodeProfileTable(published)!, auto = decodeProfileTable(publishedAuto)!;
  const sonnet: ProfileChoice = { model: 'sonnet', effort: 'low', length: 'standard' };
  const turns = [{ role: 'user' as const, text: 'Why?' }];
  it('decodes a table without auto exactly as before', () => {
    expect(hasAutoEffort(plain)).toBe(false); expect(plain.autoDefault).toBeNull(); expect(plain.estimates.size).toBe(27);
    expect(listedModels(plain)).toEqual(['haiku', 'sonnet', 'opus']);
    expect(requestProfile(plain, sonnet)).toEqual(sonnet);
    expect(requestProfile(plain, { model: 'opus', effort: 'high', length: 'detailed' })).toEqual({ model: 'opus', effort: 'high', length: 'detailed' });
    expect(requestProfile(plain, { model: 'deepseek', effort: 'low', length: 'standard' })).toBeNull();
    expect(typicalEstimate(plain, 'sonnet', 'standard')).toEqual({ low: 4, high: 24, max: 37 }); // the low-effort estimate
  });
  it('decodes the additive auto profiles, default_auto and DeepSeek within chat-profiles-v1', () => {
    expect(auto.version).toBe('chat-profiles-v1'); expect(auto.defaultChoice).toEqual(STANDARD_PROFILE);
    expect(hasAutoEffort(auto)).toBe(true); expect(auto.autoDefault).toEqual({ model: 'sonnet', effort: 'auto', length: 'standard' });
    expect(auto.estimates.size).toBe(48);
    expect(listedModels(auto)).toEqual(['haiku', 'sonnet', 'opus', 'deepseek']);
    expect(auto.models.deepseek).toMatchObject({ label: 'DeepSeek', apiModel: 'deepseek-flash' });
    expect(modelProvider(auto, 'deepseek')).toBe('DeepSeek'); expect(modelProvider(auto, 'opus')).toBe('Anthropic');
    expect(auto.efforts.auto?.label).toBe('Automatic');
    expect(typicalEstimate(auto, 'sonnet', 'standard')).toEqual({ low: 4, high: 24, max: 41 }); // the automatic estimate
    expect(tableEstimate(auto, { model: 'deepseek', effort: 'auto', length: 'standard' })).toBe('Usually 1–3 credits · up to 5');
    expect(auto.models.deepseek?.detail).toBe('Low cost; processed by DeepSeek'); // the server's words
    // A table that ties DeepSeek to a consent this browser doesn't show leaves DeepSeek out entirely.
    const otherConsent = decodeProfileTable({ ...publishedAuto, models: publishedAuto.models.map((m: { id: string }) => m.id === 'deepseek' ? { ...m, consent_version: 'cloud-ai-v9' } : m) })!;
    expect(listedModels(otherConsent)).toEqual(['haiku', 'sonnet', 'opus']); expect(available(otherConsent, { model: 'deepseek', effort: 'low', length: 'brief' })).toBe(false);
    // A default_auto it doesn't offer, or one with a concrete effort, is ignored; the table still decodes.
    expect(decodeProfileTable({ ...publishedAuto, default_auto: { model: 'opus', effort: 'auto', length: 'brief', x: 1 } })!.autoDefault).toEqual({ model: 'opus', effort: 'auto', length: 'brief' });
    expect(decodeProfileTable({ ...publishedAuto, default_auto: { model: 'sonnet', effort: 'low', length: 'standard' } })!.autoDefault).toBeNull();
    expect(decodeProfileTable({ ...publishedAuto, profiles: publishedAuto.profiles.filter((p: { id: string }) => p.id !== 'sonnet-auto-standard') })!.autoDefault).toBeNull();
    // Version and default rules are unchanged.
    expect(decodeProfileTable({ ...publishedAuto, version: 'chat-profiles-v2' })).toBeNull();
    expect(decodeProfileTable({ ...publishedAuto, default: { model: 'sonnet', effort: 'auto', length: 'standard' } })).toBeNull();
  });
  it('requests effort auto where offered for the model and length, else the stored effort', () => {
    expect(requestProfile(auto, sonnet)).toEqual({ model: 'sonnet', effort: 'auto', length: 'standard' });
    expect(requestProfile(auto, { model: 'opus', effort: 'high', length: 'detailed' })).toEqual({ model: 'opus', effort: 'auto', length: 'detailed' });
    const noHaikuAuto = decodeProfileTable({ ...publishedAuto, profiles: publishedAuto.profiles.filter((p: { id: string }) => p.id !== 'haiku-auto-brief') })!;
    expect(requestProfile(noHaikuAuto, { model: 'haiku', effort: 'medium', length: 'brief' })).toEqual({ model: 'haiku', effort: 'medium', length: 'brief' });
    const deepseekAutoOnly = decodeProfileTable({ ...publishedAuto, profiles: publishedAuto.profiles.filter((p: { model: string; effort: string }) => p.model !== 'deepseek' || p.effort === 'auto') })!;
    expect(available(deepseekAutoOnly, { model: 'deepseek', effort: 'low', length: 'brief' })).toBe(true);
    expect(offersModelLength(deepseekAutoOnly, 'deepseek', 'brief')).toBe(true);
    expect(available(null, sonnet)).toBe(false);
  });
  it('sends effort "auto" in the body (always, even for Sonnet · Standard) and the stored effort otherwise', () => {
    const autoBody = requestBody(makeRequest('op', 'd', turns, null, null, { profile: sonnet, autoEffort: true, topicTitle: true }));
    expect(autoBody.profile).toEqual({ model: 'sonnet', effort: 'auto', length: 'standard' });
    const deepseek = requestBody(makeRequest('op', 'd', turns, null, null, { profile: { model: 'deepseek', effort: 'low', length: 'brief' }, autoEffort: true }));
    expect(deepseek.profile).toEqual({ model: 'deepseek', effort: 'auto', length: 'brief' });
    // Without auto: today's request, the standard profile unsent and others with their effort.
    expect(requestBody(makeRequest('op', 'd', turns, null, null, { profile: sonnet })).profile).toBeUndefined();
    expect(requestBody(makeRequest('op', 'd', turns, null, null, { profile: { model: 'opus', effort: 'high', length: 'brief' } })).profile).toEqual({ model: 'opus', effort: 'high', length: 'brief' });
    // A diagram repair never carries a profile, automatic or not.
    expect(requestBody(makeRequest('op', null, turns, 'diagram', 'diagram_fix', { profile: sonnet, autoEffort: true }))).not.toHaveProperty('profile');
  });
  it('changes the model or length keeping an offered effort', () => {
    expect(withChoice(plain, { model: 'opus', effort: 'high', length: 'brief' }, { model: 'haiku' })).toEqual({ model: 'haiku', effort: 'high', length: 'brief' });
    const deepseekAutoOnly = decodeProfileTable({ ...publishedAuto, profiles: publishedAuto.profiles.filter((p: { model: string; effort: string }) => p.model !== 'deepseek' || p.effort === 'auto') })!;
    expect(withChoice(deepseekAutoOnly, { model: 'sonnet', effort: 'medium', length: 'standard' }, { model: 'deepseek' })).toEqual({ model: 'deepseek', effort: 'medium', length: 'standard' });
    const sonnetLowOnly = decodeProfileTable({ ...published, profiles: published.profiles.filter((p: { model: string; effort: string }) => p.model !== 'sonnet' || p.effort === 'low') })!;
    expect(withChoice(sonnetLowOnly, { model: 'opus', effort: 'high', length: 'brief' }, { model: 'sonnet' })).toEqual({ model: 'sonnet', effort: 'low', length: 'brief' });
  });
  it('summarizes a choice as model · length everywhere, and the placeholder by chat', () => {
    expect(profileSummary(sonnet, auto)).toBe('Sonnet · Standard'); expect(profileSummary({ model: 'deepseek', length: 'brief' }, auto)).toBe('DeepSeek · Brief');
    expect(profileSummary({ model: 'deepseek', length: 'brief' })).toBe('DeepSeek · Brief');
    expect(sameChoice(sonnet, { ...sonnet, effort: 'high' })).toBe(true); expect(sameChoice(sonnet, { ...sonnet, length: 'brief' })).toBe(false);
    expect(answeredBy('deepseek-flash', 'deepseek-medium-standard', auto)).toBe('DeepSeek · Standard');
    expect(answeredBy('claude-sonnet-5-5', 'sonnet-medium-detailed', auto)).toBe('Sonnet · Detailed');
    expect(composerPlaceholder('paper', false)).toBe('Ask anything about the paper');
    expect(composerPlaceholder('general', false)).toBe('Ask anything');
    expect(composerPlaceholder('paper', true)).toBe('Your answer');
  });
  it('previews a conversation by its passage or newest answer, never its paper', () => {
    expect(conversationPreview({ anchor: { quote: '  softmax(QKᵀ/√d)\n over keys ' }, latestAnswer: 'An answer' })).toBe('“softmax(QKᵀ/√d) over keys”');
    expect(conversationPreview({ latestAnswer: '**The objective** compares preferences [¶2].\n\nMore' })).toBe('The objective compares preferences.');
    expect(conversationPreview({ latestAnswer: '\\[L = x\\]\n\n| a | b |\n|---|---|\n\nThe loss \\(\\beta\\) term.' })).toBe('The loss \\beta term.');
    expect(conversationPreview({ latestAnswer: 'x'.repeat(260) })).toHaveLength(201);
    expect(conversationPreview({})).toBe('');
  });
});


describe('Flash rollout', () => {
  const raw = JSON.parse(readFileSync(new URL('./fixtures/chat-profiles-gemini.json', import.meta.url), 'utf8')); // the server's (tests/fixtures), with default_figures
  it('uses the recommended default, preserves explicit choices and names both processors', () => {
    const table = decodeProfileTable(raw)!;
    expect(table.defaultChoice).toEqual({ model: 'gemini', effort: 'medium', length: 'standard' });
    expect(table.autoDefault).toBeNull();
    expect(requestProfile(table, table.defaultChoice)).toEqual({ model: 'gemini', effort: 'auto', length: 'standard' });
    expect(requestProfile(table, STANDARD_PROFILE)?.model).toBe('sonnet');
    expect(modelProvider(table, 'gemini')).toBe('Google through OpenRouter');
    const body = requestBody(makeRequest(crypto.randomUUID(), null, [{ role: 'user', text: 'Hello' }], null, null, { profile: table.defaultChoice, autoEffort: true }));
    expect(body.consent_version).toBe('cloud-ai-v6'); expect(body.profile?.model).toBe('gemini');
  });
  it('does not offer Flash under an unknown consent contract or a different route', () => {
    for (const change of [{ consent_version: 'cloud-ai-v6' }, { provider: 'mystery' }]) {
      const table = decodeProfileTable({ ...raw, models: raw.models.map((m: any) => m.id === 'gemini' ? { ...m, ...change } : m) })!;
      expect(table.defaultChoice).toEqual(STANDARD_PROFILE); expect(listedModels(table)).not.toContain('gemini');
    }
  });
});
