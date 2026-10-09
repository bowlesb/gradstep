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
        <p>Library metadata, tags, reading state and encrypted chat events can sync through Gradstep. Chat and note content is encrypted before sync; the keys stay with your approved devices and recovery code.</p>
        <p>Paper files follow their source and rights. Default-license arXiv papers can be kept on your device for reading. Rights-cleared or explicitly permitted conversions can be shared to avoid repeating OCR. User-uploaded and private papers stay account-scoped.</p>
        <p>When you ask for equation-aware preparation, Mathpix receives the PDF or permitted processing asset. An AI answer sends the relevant question, selected passage, conversation context and paper text to the selected model provider. Encryption protects stored copies; it does not hide content from a provider during a computation you requested.</p>
        <p>Optional web search sends search queries to the configured search provider. Provider retention and handling follow that provider's terms; Gradstep does not promise zero provider retention.</p>
      </section>
      <section className="info-section"><h3>How we keep costs bounded</h3>
        <p>A credit is a Gradstep usage unit, not cash. Before an AI action, the server estimates the work and reserves a bounded maximum. When it finishes, the actual measured usage is settled. Retries use the same operation identity so a lost response does not charge twice.</p>
        <p>Paper preparation, chat, search and podcasts have separate limits and accounting. Shared eligible conversions and ready-made podcast episodes avoid repeating provider work. Account and platform budgets stop one user or provider outage from creating an unlimited bill.</p>
        <p>Tokens are the text units providers use for billing; they are not the same as words. The cost of an answer depends on paper and conversation size, cached context, model, effort, answer length, tools and searches, and the tokens actually used. Chat controls show an estimate and maximum before work starts.</p>
      </section>
      <section className="info-section"><h3>What a normal month can cover</h3>
        <p>These are current planning guides, not a promise of a fixed number of answers. All paid actions use the same balance, and a longer paper or a more detailed profile can cost more.</p>
        <p><strong>Paper preparation:</strong> about 1 credit per new Mathpix page; an eligible shared conversion can avoid that charge. <strong>Chat:</strong> a typical Sonnet answer is usually about 4–24 credits, with the exact estimate shown before sending. <strong>Search:</strong> about 1–2 credits per search.</p>
        <p><strong>Podcasts:</strong> browsing and playing a shared episode uses no generation credits. Recent five-minute private episodes used about 55–60 credits; the safety maximum is 150 and the actual charge is settled afterward.</p>
        <p>The current Standard and Pro plans include 800 and 1,800 credits. Think of them as a flexible monthly allowance: a light mix of new papers and chats leaves room for occasional audio, while repeated long papers, deep answers and private episodes use it faster.</p>
      </section>
      <section className="info-section"><h3>Models and providers</h3>
        <p>Current chat answers use Anthropic's Claude models: Haiku is the fast, lower-cost choice for simpler work, Sonnet is the default balance of quality and cost, and Opus is reserved for harder reasoning. Mathpix prepares equations when you request it; search and speech use separate providers when enabled. The server enforces the available profiles and records the model that actually answered, including an approved fallback.</p>
        <p>A lower-priced model is not automatically a safe replacement for scientific reading. Before adding a provider such as DeepSeek, we compare equation handling, citations, long-paper quality, privacy terms, latency, structured tools and real measured cost. We will not trade away reliability for a price number alone.</p>
      </section>
      <section className="info-section"><h3>Your controls</h3>
        <p>You choose the chat profile and answer length, and you can leave web search off. Each request is bounded before it runs, and the app shows what was charged afterward. Report a problem from the account menu so we can inspect the workflow and its accounting record.</p>
      </section>
      <div className="dialog-actions"><button className="primary" onClick={onClose}>Done</button></div>
    </div>
  </Dialog>;
}
