#if DEBUG && FIXTURE_HOST
import Foundation
import ScienceReaderCore

/// `--chat-history-fixture` (with `--chat-fixture` or `--draft-fixture`): about thirty varied, synthetic
/// conversations written through the real encrypted fixture store, for All chats' table and its visual scenarios.
/// Times are relative to launch so labels read "Just now", "2 h ago", "Yesterday", a weekday, a date and last year;
/// two conversations have no recorded time, like history saved before 2026-10-07. One paper chat is about a paper
/// no longer in the library. Five begin with a reader selection action's prompt (equations as Mathpix writes them, a
/// reference), as real history does. Compiled out of device and release builds.
extension ReaderModel {
    static var chatHistoryFixtureEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--chat-history-fixture") }

    /// Conversation `n` of the fixture (stable, so UI tests can find rows).
    static func chatHistoryFixtureConversation(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "c4a7c4a7-0000-4000-8000-%012ld", n))!
    }

    func installChatHistoryFixture(into store: EncryptedStore, deviceID: UUID) async throws {
        let first = Self.chatHistoryFixtureConversation(1)
        guard await store.state().revisions(for: first).isEmpty else { return }
        let now = Date(), minute: Double = 60, hour = 3_600.0, day = 86_400.0
        func paperID(_ n: Int) -> UUID { UUID(uuidString: String(format: "c4a7c4a7-0000-4000-8000-1000000000%02ld", n))! }
        let library: [(Int, String, String, Int)] = [
            (1, "Attention Is All You Need", "Ashish Vaswani, Noam Shazeer, Niki Parmar", 2017),
            (2, "Direct Preference Optimization: Your Language Model is Secretly a Reward Model", "Rafael Rafailov, Archit Sharma, Eric Mitchell", 2023),
            (3, "LoRA: Low-Rank Adaptation of Large Language Models", "Edward J. Hu, Yelong Shen, Phillip Wallis", 2021),
            (4, "Deep Residual Learning for Image Recognition", "Kaiming He, Xiangyu Zhang, Shaoqing Ren, Jian Sun", 2015),
            (5, "Adam: A Method for Stochastic Optimization", "Diederik P. Kingma, Jimmy Ba", 2014),
            (6, "Denoising Diffusion Probabilistic Models", "Jonathan Ho, Ajay Jain, Pieter Abbeel", 2020),
            (7, "Scaling Laws for Neural Language Models", "Jared Kaplan, Sam McCandlish, Tom Henighan", 2020),
        ]
        for (n, title, authors, year) in library where !papers.contains(where: { $0.id == paperID(n) }) {
            var paper = Paper(id: paperID(n), title: title, authors: authors, year: year, abstract: "", keywords: [], fileURL: nil,
                              artifactID: UUID(uuidString: String(format: "c4a7c4a7-0000-4000-8000-2000000000%02ld", n)))
            paper.authorNames = authors.components(separatedBy: ", "); paper.addedAt = now - Double(n) * 9 * day
            papers.append(paper)
        }
        let sample = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!
        let removedPaper = paperID(99)   // a paper chat whose paper is no longer in the library

        // Answers by paper (0 = the sample, 99 = removed, -1 = general chats), two or more each so previews vary.
        let answers: [Int: [String]] = [
            1: ["Scaling by $\\sqrt{d_k}$ keeps the dot products at unit variance, so the **softmax** doesn't saturate and gradients stay useful.\n\n$$\\mathrm{softmax}\\left(\\frac{QK^\\top}{\\sqrt{d_k}}\\right)V$$",
                "Sinusoids of different frequencies are added to the token embeddings, so relative offsets become linear functions of the encodings.",
                "Each head attends in its own subspace; eight heads of 64 dimensions cost about the same as one head of 512."],
            2: ["## Short answer\n\nDPO optimizes the policy directly on preference pairs with a classification-style loss; no separate reward model or RL loop is needed.",
                "The reference policy enters through the log-ratio $\\log \\pi_\\theta(y|x) - \\log \\pi_{\\mathrm{ref}}(y|x)$, scaled by $\\beta$.",
                "Small $\\beta$ lets the policy drift further from the reference; values from 0.1 to 0.5 are typical."],
            3: ["LoRA freezes $W_0$ and learns $\\Delta W = BA$ with rank $r \\ll d$. Rank 8 usually matches full fine-tuning at a fraction of the memory.",
                "Yes: after training, $W = W_0 + BA$ can be merged into the base weights, so inference has no extra latency."],
            4: ["- The identity shortcut lets the block learn a *residual* $F(x)$.\n- Very deep plain networks degrade in **training** error, not just test error.",
                "Bottleneck blocks (1×1, 3×3, 1×1) keep the cost of the 3×3 convolution low in the deeper models."],
            5: ["Adam keeps running averages of the gradient and its square; the bias correction matters most in the first few hundred steps.",
                "Decoupled weight decay (AdamW) closes much of the generalization gap reported against SGD."],
            6: ["The forward process adds Gaussian noise over $T$ steps; the model learns to predict that noise, which gives a simple weighted ELBO.",
                "Predicting $\\epsilon$ is equivalent to estimating the score up to a scale, which links DDPM to score matching."],
            7: ["Loss falls as a power law in parameters, data and compute, as long as none of the three is the bottleneck.",
                "For a fixed budget the paper favors larger models trained on fewer tokens; later work revised that ratio."],
            0: ["Equation 1 is scaled dot-product attention; the section explains each term and why the scaling is needed."],
            99: ["The ablation removes one component at a time; the largest drop comes from removing the retrieval step."],
            -1: ["Use a held-out set with the same distribution, report the median over seeds, and note the variance.",
                 "A plan: week 1 InstructGPT and Constitutional AI, week 2 DPO and its variants, week 3 evaluation.",
                 "The trick writes the sample as $z = \\mu + \\sigma \\odot \\epsilon$, so gradients flow through $\\mu$ and $\\sigma$.",
                 "Start from the problem, group prior work by approach, and say in one sentence how yours differs."],
        ]
        struct Chat { let n: Int; let paper: Int?; let title: String; let follow: [String]; let start: Double; let last: Double; var timed = true }
        // `start`/`last` are how long ago (seconds); paper 0 = the offline sample, 99 = removed from the library.
        let chats: [Chat] = [
            Chat(n: 1, paper: 1, title: "Why scale the dot products by the square root of d_k?", follow: ["What happens without the scaling?"], start: 50 * minute, last: 2 * minute),
            Chat(n: 2, paper: nil, title: "Compare DPO, IPO and KTO for a small preference dataset", follow: ["Which is most robust to noisy labels?", "And with 2k pairs?"], start: 3 * hour, last: 35 * minute),
            Chat(n: 3, paper: 3, title: "How do I pick the LoRA rank for a 7B model?", follow: [], start: 2.2 * hour, last: 2 * hour),
            Chat(n: 4, paper: 2, title: "Derive the DPO loss from the Bradley–Terry model", follow: ["Where does the reference policy enter?", "Is beta a temperature?", "What if pairs are ties?"], start: 6 * hour, last: 5 * hour),
            Chat(n: 5, paper: 0, title: "Explain in plain terms, including any symbols: \\[\\begin{equation*}\n\\operatorname{Attention}(Q, K, V)=\\operatorname{softmax}\\left(\\frac{Q K^{T}}{\\sqrt{d_{k}}}\\right) V\n\\end{equation*}\\]", follow: [], start: 26 * hour, last: 25 * hour),
            Chat(n: 6, paper: 4, title: "Why do residual connections help optimization?", follow: ["Does this explain the degradation problem?"], start: 3 * day, last: 1.2 * day),
            Chat(n: 7, paper: nil, title: "Explain the difference between KL penalty and clipping in PPO", follow: ["Which matters more for LLMs?"], start: 2 * day, last: 2 * day),
            Chat(n: 8, paper: 5, title: "Define this in the context of the paper: \\(\\hat { m } _ { t } / ( \\sqrt { \\hat { v } _ { t } } )\\)", follow: [], start: 2.5 * day, last: 2.5 * day),
            Chat(n: 9, paper: 6, title: "Why does this matter to the paper's method and results? We find it beneficial to sample quality to train on the simplified objective \\(L_{\\text{simple}}\\)", follow: ["Would cosine be better?", "How many steps T?"], start: 4 * day, last: 3 * day),
            Chat(n: 10, paper: 7, title: "Do the scaling laws hold for code models?", follow: ["What about data repetition?"], start: 5 * day, last: 4 * day),
            Chat(n: 11, paper: 1, title: "Find related papers, earlier and recent, with links: sinusoidal positional encodings let the model extrapolate to longer sequences", follow: [], start: 5 * day, last: 5 * day),
            Chat(n: 12, paper: nil, title: "Draft a reading plan for RLHF papers this month", follow: ["Add evaluation papers", "Shorter, please"], start: 6 * day, last: 5.5 * day),
            Chat(n: 13, paper: 99, title: "Find and add the paper referenced in this passage: [3] T. D. Lee and G. C. Wick. Negative metric and the unitarity of the S-matrix. Nuclear Physics B, 9(2):209–243, 1969.", follow: [], start: 9 * day, last: 8 * day),
            Chat(n: 14, paper: 3, title: "Can LoRA adapters be merged after training?", follow: ["Any accuracy loss?"], start: 10 * day, last: 9 * day),
            Chat(n: 15, paper: 2, title: "How sensitive is DPO to the beta hyperparameter?", follow: [], start: 11 * day, last: 11 * day),
            Chat(n: 16, paper: nil, title: "What is the intuition behind the reparameterization trick?", follow: ["Show the math", "Why can't we backprop through sampling?"], start: 14 * day, last: 12 * day),
            Chat(n: 17, paper: 4, title: "Bottleneck blocks versus basic blocks", follow: [], start: 15 * day, last: 15 * day),
            Chat(n: 18, paper: 6, title: "Relationship between DDPM and score matching", follow: ["And to Langevin dynamics?", "Which paper unified them?", "Summarize in one paragraph"], start: 20 * day, last: 17 * day),
            Chat(n: 19, paper: 5, title: "Why does Adam generalize worse than SGD sometimes?", follow: ["Does AdamW fix it?"], start: 22 * day, last: 21 * day),
            Chat(n: 20, paper: 7, title: "Compute-optimal model size for a fixed budget", follow: [], start: 25 * day, last: 24 * day),
            Chat(n: 21, paper: nil, title: "Recommend papers on long-context attention", follow: ["Only post-2023"], start: 30 * day, last: 28 * day),
            Chat(n: 22, paper: 1, title: "Multi-head attention: why split into heads?", follow: ["How many heads in the base model?"], start: 34 * day, last: 33 * day),
            Chat(n: 23, paper: 3, title: "Where should LoRA be applied: attention or MLP?", follow: [], start: 40 * day, last: 40 * day),
            Chat(n: 24, paper: 2, title: "Is DPO equivalent to RLHF with a KL constraint?", follow: ["Under which assumptions?"], start: 45 * day, last: 44 * day),
            Chat(n: 25, paper: nil, title: "How to write a clear related-work section", follow: [], start: 60 * day, last: 58 * day),
            Chat(n: 26, paper: 6, title: "What does the U-Net predict exactly?", follow: ["Epsilon or x0?"], start: 75 * day, last: 70 * day),
            Chat(n: 27, paper: 4, title: "Batch norm placement in the residual block", follow: [], start: 120 * day, last: 118 * day),
            Chat(n: 28, paper: nil, title: "Explain the Chinchilla result in two sentences", follow: [], start: 400 * day, last: 380 * day),
            Chat(n: 29, paper: 5, title: "Learning-rate warmup with Adam", follow: ["How long?"], start: 0, last: 0, timed: false),
            Chat(n: 30, paper: nil, title: "Notes on evaluating retrieval-augmented generation", follow: [], start: 0, last: 0, timed: false),
        ]
        // Untimed (legacy) conversations were saved first, like history from before times were recorded.
        for chat in chats.filter({ !$0.timed }) + chats.filter(\.timed).reversed() {
            let conversation = Self.chatHistoryFixtureConversation(chat.n)
            let documentID: UUID? = chat.paper.map { $0 == 0 ? sample : ($0 == 99 ? removedPaper : paperID($0)) }
            let questions = [chat.title] + chat.follow
            let pool = answers[chat.paper ?? -1] ?? answers[-1]!
            let span = chat.start - chat.last
            func time(_ step: Int) -> Int64? {
                guard chat.timed else { return nil }
                let fraction = questions.count * 2 > 1 ? Double(step) / Double(questions.count * 2 - 1) : 1
                return PrivateEvent.timestamp(now - chat.start + span * fraction)
            }
            let root = UUID()
            var batch: [(id: UUID, event: PrivateEvent)] = [(root, PrivateEvent(kind: .conversation, entityID: conversation,
                documentID: documentID, text: String(chat.title.prefix(100)), createdAt: time(0)))]
            var parent = root, step = 0
            for (turn, question) in questions.enumerated() {
                let asked = UUID()
                batch.append((asked, PrivateEvent(kind: .message, entityID: asked, parents: [parent], conversationID: conversation,
                    documentID: documentID, text: question, role: .user, status: .complete, createdAt: time(step))))
                step += 1; parent = asked
                // One conversation ends on a question that has no answer yet.
                if chat.n == 3 && turn == questions.count - 1 { continue }
                let answered = UUID()
                batch.append((answered, PrivateEvent(kind: .message, entityID: answered, parents: [parent], conversationID: conversation,
                    documentID: documentID, text: pool[(chat.n + turn) % pool.count], role: .assistant, status: .complete,
                    createdAt: time(step))))
                step += 1; parent = answered
            }
            _ = try await store.appendBatch(batch, deviceID: deviceID)
        }
    }
}
#endif
