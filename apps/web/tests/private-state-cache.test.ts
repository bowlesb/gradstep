// C2/C3: derived views of the private state are computed once per change and shared until the next change.
import { describe, expect, it } from 'vitest';
import { PrivateState, type AppliedEvent, type PrivateEvent } from '../src/lib/events';

const device = 'aaaaaaaa-0000-4000-8000-000000000001';
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const C = id(900), D = id(901), M1 = id(902), M2 = id(903);
const event = (n: number, payload: PrivateEvent): AppliedEvent => ({ id: id(n), deviceID: device, payload });

function conversation() {
  const state = new PrivateState();
  state.applyBatch([
    event(1, { kind: 'conversation', entityID: C, parents: [], text: 'What is DPO?', documentID: D, createdAt: 1 }),
    event(2, { kind: 'message', entityID: M1, parents: [id(1)], conversationID: C, documentID: D, text: 'What is DPO?', role: 'user', status: 'complete', createdAt: 2 }),
    event(3, { kind: 'message', entityID: M2, parents: [id(2)], conversationID: C, documentID: D, text: 'An objective.', role: 'assistant', status: 'complete', createdAt: 3 }),
  ]);
  return state;
}

describe('derived private state', () => {
  it('returns the same summaries, branches and diagrams until an event changes them', () => {
    const state = conversation();
    const summaries = state.conversationSummaries(), branches = state.conversationBranches(C), diagrams = state.diagramsByMessage();
    expect(summaries).toHaveLength(1); expect(branches).toHaveLength(1); expect(branches[0].messages.map(m => m.payload.text)).toEqual(['What is DPO?', 'An objective.']);
    expect(state.conversationSummaries()).toBe(summaries); expect(state.conversationBranches(C)).toBe(branches); expect(state.diagramsByMessage()).toBe(diagrams);
    expect(state.conversationBranch(C, id(3))).toBe(branches[0]);
    state.applyBatch([event(4, { kind: 'message', entityID: id(904), parents: [id(3)], conversationID: C, documentID: D, text: 'Why?', role: 'user', status: 'complete', createdAt: 4 })]);
    expect(state.conversationSummaries()).not.toBe(summaries); expect(state.conversationSummaries()[0].messageCount).toBe(3);
    expect(state.conversationBranches(C)[0].messages).toHaveLength(3);
  });
  it('never keeps a view from a batch that was only checked or rolled back', () => {
    const state = conversation(), before = state.conversationSummaries();
    state.check([event(5, { kind: 'tombstone', entityID: C, parents: [], createdAt: 5 })]);
    expect(state.isDeleted(C)).toBe(false); expect(state.conversationSummaries()).toHaveLength(1);
    expect(() => state.applyBatch([event(6, { kind: 'tombstone', entityID: C, parents: [], createdAt: 6 }), event(6, { kind: 'tombstone', entityID: D, parents: [], createdAt: 6 })])).toThrow();
    expect(state.isDeleted(C)).toBe(false); expect(state.conversationSummaries()).toEqual(before);
    state.applyBatch([event(7, { kind: 'tombstone', entityID: C, parents: [], createdAt: 7 })]);
    expect(state.isDeleted(C)).toBe(true); expect(state.conversationSummaries()).toEqual([]); expect(state.conversationBranches(C)).toEqual([]);
    expect(state.revisions(C)).toEqual([]);
  });
  it('shares nothing a caller can change', () => {
    const state = conversation();
    expect(Object.isFrozen(state.conversationSummaries())).toBe(true);
    expect(() => (state.conversationBranches(C)[0].messages as AppliedEvent[]).reverse()).toThrow(TypeError);
    expect([...state.conversationSummaries()].sort()).toHaveLength(1);
  });
  it('indexes revisions, kinds and paper references', () => {
    const state = new PrivateState(), member = id(950);
    state.applyBatch([
      event(10, { kind: 'local_paper', entityID: id(960), parents: [], text: JSON.stringify({ format: 'device-pdf-membership-v1', title: 'A PDF', pageCount: 3, createdAt: 1, archived: false, tags: [] }) }),
      event(11, { kind: 'local_paper', entityID: id(960), parents: [id(10)], text: JSON.stringify({ format: 'device-pdf-membership-v1', title: 'A PDF', pageCount: 3, createdAt: 1, archived: true, tags: [] }) }),
      event(12, { kind: 'conversation', entityID: id(970), parents: [], text: 'Q', documentID: member, paperReference: { format: 'source-membership-v1', membershipID: member, source: 'arxiv', sourceID: '2601.01234', revision: 2 } }),
    ]);
    expect(state.entitiesOfKind('local_paper')).toEqual([id(960)]);
    expect(state.revisions(id(960)).map(e => e.id)).toEqual([id(11)]);
    expect(state.paperReference(member)).toMatchObject({ sourceID: '2601.01234', revision: 2 });
    expect(state.paperReference(id(951))).toBeUndefined();
  });
});
