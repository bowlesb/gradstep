import { Dialog } from './common';

/** The short, user-facing explanation of data paths, models and spending controls. Keep this separate from legal copy. */
export function HowGradstepWorks({ open, onClose }: { open: boolean; onClose: () => void }) {
  return <Dialog open={open} onClose={onClose} title="How Gradstep works" className="info-dialog-shell">
    <div className="info-dialog" data-testid="how-gradstep-works-dialog">
      <div className="dialog-heading"><h2>How Gradstep works</h2><button className="link" onClick={onClose}>Close</button></div>
      <section className="info-section"><h3>The short version</h3>
        <p>Gradstep keeps your research useful across devices while sending only the material needed for the action you ask for. Local paper storage, encrypted sync and AI processing are separate paths.</p>
      </section>
      <section className="info-section"><h3>What leaves your device</h3>
        <p>Library metadata, tags and encrypted chat events can sync through Gradstep. Reading progress stays on this device. Chat and note content is encrypted before sync; the keys stay with your approved devices and recovery code.</p>
        <p>New PDFs are downloaded, opened and processed only on your device. The structured reader prepares the exact official arXiv HTML version locally. Earlier server copies and conversions were deleted on 16 October 2026. In this browser, choose a PDF again after reopening the tab; its contents do not sync.</p>
        <p>An AI answer sends the relevant question, selected passage, conversation context and paper text to the selected model provider. Encryption protects stored copies; it does not hide content from a provider during a computation you requested.</p>
        <p>Optional web search sends search queries to the configured search provider. Provider retention and handling follow that provider's terms; Gradstep does not promise zero provider retention.</p>
      </section>
      <section className="info-section"><h3>How we keep costs bounded</h3>
        <p>A credit is a Gradstep usage unit, not cash. Before an AI action, the server estimates the work and reserves a bounded maximum. When it finishes, the actual measured usage is settled. Retries use the same operation identity so a lost response does not charge twice.</p>
        <p>Local HTML preparation uses no OCR credits. Chat, search and podcasts have separate limits and accounting. Ready-made podcast episodes avoid repeating provider work. Account and platform budgets stop one user or provider outage from creating an unlimited bill.</p>
        <p>Tokens are the text units providers use for billing; they are not the same as words. The cost of an answer depends on paper and conversation size, cached context, model, effort, answer length, tools and searches, and the tokens actually used. AI chat options (account menu) lists the usual credits per question for each model and length, and the most one answer can cost.</p>
      </section>
      <section className="info-section"><h3>What a normal month can cover</h3>
        <p>These are current planning guides, not a promise of a fixed number of answers. All paid actions use the same balance, and a longer paper or a more detailed profile can cost more.</p>
        <p><strong>Paper preparation:</strong> official arXiv HTML is prepared on your device without an OCR charge. <strong>Chat:</strong> a typical Sonnet answer is usually about 4–24 credits; AI chat options lists the range for each model and length. <strong>Search:</strong> about 1–2 credits per search.</p>
        <p><strong>Podcasts:</strong> browsing and playing a shared episode uses no generation credits. Recent five-minute private episodes used about 55–60 credits; the safety maximum is 150 and the actual charge is settled afterward.</p>
        <p>The current Standard and Pro plans include 800 and 1,800 credits. Think of them as a flexible monthly allowance: a light mix of new papers and chats leaves room for occasional audio, while repeated long papers, deep answers and private episodes use it faster.</p>
      </section>
      <section className="info-section"><h3>Models and providers</h3>
        <p>Answer options shows the available models and their estimated cost. On iPhone, iPad and Mac, an experimental on-device model can read a PDF on the device; nothing leaves the device for it. Search and speech use separate providers when enabled. The server enforces the available profiles and records the model that actually answered.</p>
        <p>Chat answers use Gemini Flash by Google through OpenRouter, Anthropic’s Claude models, or DeepSeek, as selected in Answer options (Anthropic still writes the chat’s title and suggested questions); podcast scripts can also be written by DeepSeek when you choose it for an episode. A lower-priced model is not automatically a safe replacement for scientific reading: before using one anywhere, we compare equation handling, citations, long-paper quality, privacy terms, latency, structured tools and real measured cost. We will not trade away reliability for a price number alone.</p>
      </section>
      <section className="info-section"><h3>arXiv</h3>
        <p>Your browser downloads each paper's official HTML version from arXiv and prepares it here; paper links go to the exact version on arXiv, and each paper keeps its authors' license.</p>
        <p data-testid="arxiv-acknowledgement">{ARXIV_ACKNOWLEDGEMENT}</p>
      </section>
      <section className="info-section"><h3>Your controls</h3>
        <p>You choose the model and answer length, and you can leave web search off. Each request is bounded before it runs, and the app shows what was charged afterward. Report a problem from the account menu so we can inspect the workflow and its accounting record.</p>
      </section>
      <div className="dialog-actions"><button className="primary" onClick={onClose}>Done</button></div>
    </div>
  </Dialog>;
}

/** arXiv's required acknowledgement for products that use its API or data (docs/architecture/ARXIV_DEVICE_ONLY.md §7). */
export const ARXIV_ACKNOWLEDGEMENT = 'Thank you to arXiv for use of its open access interoperability. This product was not reviewed or approved by, nor does it necessarily express or reflect the policies or opinions of, arXiv.';
