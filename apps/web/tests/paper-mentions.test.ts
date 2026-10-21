// The browser's "Papers in this answer" detection, against the cases of ScienceReaderCore's ChatPaperMentionsTests (B2).
import { describe, expect, it } from 'vitest';
import { MAXIMUM_MENTIONS, cleanTitle, leadingTitle, paperMentions } from '../src/lib/paper-mentions';

const ids = (text: string) => paperMentions(text).map(m => m.id);

describe('papers in an answer', () => {
  it('lists arXiv and DOI papers with titles, in order, without the paper only Sources names', () => {
    const answer = `Related work:

1. **Direct Preference Optimization: Your Language Model is Secretly a Reward Model** — Rafailov et al., 2023. arXiv:2305.18290
2. [A General Theoretical Paradigm to Understand Learning from Human Preferences](https://arxiv.org/abs/2310.12036v2) — Azar et al.
3. **Rank Analysis of Incomplete Block Designs** — Bradley and Terry, 1952. https://doi.org/10.2307/2334029.
4. KTO (https://arxiv.org/pdf/2402.01306.pdf) and ORPO (arXiv 2403.07691) compare against it.

Sources:
1. Attention Is All You Need — https://arxiv.org/abs/1706.03762`;
    const mentions = paperMentions(answer);
    expect(mentions.map(m => m.id)).toEqual(['arxiv:2305.18290', 'arxiv:2310.12036', 'doi:10.2307/2334029', 'arxiv:2402.01306', 'arxiv:2403.07691']);
    expect(mentions[0].title).toBe('Direct Preference Optimization: Your Language Model is Secretly a Reward Model');
    expect(mentions[1].title).toBe('A General Theoretical Paradigm to Understand Learning from Human Preferences');
    expect(mentions[1].label).toBe('arXiv 2310.12036v2');
    expect(mentions[2].title).toBe('Rank Analysis of Incomplete Block Designs');
    expect(mentions[2].label).toBe('DOI 10.2307/2334029'); // the sentence's full stop is not part of the DOI
    expect(mentions[2].url).toBe('https://doi.org/10.2307/2334029');
    expect(mentions[3].title).toBeNull(); expect(mentions[4].title).toBeNull(); // a line naming two papers gives neither its leading words
    expect(mentions[0].url).toBe('https://arxiv.org/abs/2305.18290');
  });
  it('collapses duplicates and arXiv DOIs and caps the list', () => {
    const mentions = paperMentions('See arXiv:2305.18290, [DPO](https://arxiv.org/abs/2305.18290v3) and doi:10.48550/arXiv.2305.18290 again.');
    expect(mentions.map(m => m.id)).toEqual(['arxiv:2305.18290']);
    expect(mentions[0].title).toBeNull(); // a one-word link label is not a title
    expect(ids('10.1000/ABC and 10.1000/abc')).toEqual(['doi:10.1000/abc']);
    const many = Array.from({ length: 12 }, (_, i) => `arXiv:2401.${String(i + 1).padStart(5, '0')}`).join('\n');
    expect(ids(many)).toHaveLength(MAXIMUM_MENTIONS);
  });
  it('counts only recognized identifiers', () => {
    expect(ids('Accuracy rose from 2305.18290 to 2310.12036 points; costs $10.50; version 10.2.1/3.')).toEqual([]);
    expect(ids('arXiv:2313.00001 and arXiv:1706.3762')).toEqual([]);
    expect(ids('arXiv:hep-th/9901001v2')).toEqual(['arxiv:hep-th/9901001']);
    expect(ids('arXiv preprint arXiv:1706.03762.')).toEqual(['arxiv:1706.03762']);
    expect(ids('[the paper](https://doi.org/10.1016/S0140-6736(20)30183-5)')).toEqual(['doi:10.1016/s0140-6736(20)30183-5']);
    expect(ids('(see 10.1145/3292500.3330701)')).toEqual(['doi:10.1145/3292500.3330701']);
    expect(ids('No identifiers here.')).toEqual([]);
  });
  it('takes titles from links or the item’s leading title', () => {
    expect(leadingTitle('- **Scaling Laws for Neural Language Models** (Kaplan, 2020)')).toBe('Scaling Laws for Neural Language Models');
    expect(leadingTitle('3) “Deep Residual Learning for Image Recognition”, He et al.')).toBe('Deep Residual Learning for Image Recognition');
    expect(leadingTitle('**Note:** this is related')).toBeNull();
    expect(leadingTitle('Plain text arXiv:2305.18290')).toBeNull();
    expect(cleanTitle('https://arxiv.org/abs/2305.18290')).toBeNull();
    expect(cleanTitle('arXiv:2305.18290')).toBeNull();
  });
});
