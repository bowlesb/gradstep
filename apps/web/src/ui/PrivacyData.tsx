// Account menu › Privacy & data, the browser's copy of the apps' page (owner, builds 57–58: "We need more in here about
// terms of service and how we use arXiv articles and how we abide by arXiv's terms"; docs/architecture/ARXIV_DEVICE_ONLY.md).
// Worded as on iPhone, iPad and Mac, except that a PDF here opens from arXiv in a new tab instead of being kept.
import { Dialog, SheetTop } from './common';
import { ARXIV_ACKNOWLEDGEMENT } from './HowGradstepWorks';

export const ARXIV_TERMS = 'https://info.arxiv.org/help/api/tou.html';

export function PrivacyData({ open, onClose }: { open: boolean; onClose: () => void }) {
  return <Dialog open={open} onClose={onClose} title="Privacy & data" className="info-dialog-shell">
    <SheetTop onClose={onClose} testID="privacy-close"><h2>Privacy &amp; data</h2></SheetTop>
    <div className="info-dialog" data-testid="privacy-dialog">
      <section className="info-section"><h3>Your notes and conversations</h3>
        <p>Private conversations and notes are encrypted with keys held on your devices. An approved device or your recovery code is needed to restore them.</p>
      </section>
      <section className="info-section"><h3>AI answers</h3>
        {/* As the apps' Settings › Privacy & data say it (RootView): there is no backup search provider since all inference
            moved to OpenRouter (the old line still named Anthropic's), and requests carry a random account ID. */}
        <p data-testid="privacy-ai">AI answers send your question, any selected passage, earlier messages in that conversation and, for paper chats, the paper’s text and the image of any figure or table you ask about through OpenRouter to Google Vertex (Gemini and Claude) or DeepInfra (DeepSeek), according to Answer options. A random account ID accompanies requests for cost accounting. Claude through OpenRouter writes the chat’s title and suggested questions. The model may search the web for some questions; those searches go to Tavily, a search service.</p>
      </section>
      <section className="info-section" data-testid="privacy-arxiv"><h3>Papers and arXiv</h3>
        <p>Papers open from the official web version or PDF that arXiv publishes. Your device downloads them directly from arXiv when you open a paper, and prepares them for reading on the device, for you alone. A PDF you open comes straight from arXiv in a new tab.</p>
        <p>Your device also asks arXiv when you search for papers. Gradstep’s servers never contact arXiv and keep no copies of papers; the Feed’s list of new papers comes from DataCite, which publishes arXiv’s records.</p>
        <p>Requests to arXiv are spaced out, name Gradstep, and stop for a day if arXiv asks this device to slow down, as arXiv’s API Terms of Use require. Each paper stays under its authors’ license, with a link back to arXiv.</p>
        <p><a href={ARXIV_TERMS} target="_blank" rel="noopener noreferrer">arXiv API Terms of Use</a></p>
        <p className="muted">{ARXIV_ACKNOWLEDGEMENT}</p>
      </section>
      {/* The interest index's notice, as the owner approved it on 2026-10-25 (docs/architecture/INTEREST_INDEX.md §5); the
          same section as the apps' Privacy & data. */}
      <section className="info-section" data-testid="privacy-topics"><h3>Topics and For you</h3>
        <p>To find your topics, your devices download a public map of recent arXiv research from our servers, the same file for everyone. Your topics are worked out on your devices; our servers don’t receive them. For you also ranks new papers by how close they are to the arXiv papers in your library, using their public titles and abstracts; nothing from that comparison is kept.</p>
      </section>
      <section className="info-section"><h3>Reports</h3>
        <p>A report you send, with its screenshot and notes, goes to Gradstep’s support so we can fix the problem, and is kept until you delete your account.</p>
      </section>
    </div>
  </Dialog>;
}
