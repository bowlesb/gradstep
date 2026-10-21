import Foundation

/// Gradstep's topic tags (docs/architecture/TAGS.md). The same names, kinds and arXiv mapping as the
/// server's `supabase/functions/_shared/tag-vocabulary.ts`; a backend test compares the two lists.
/// Catalog tags always come from this vocabulary; a reader's own tags may be any text, with these
/// as suggestions. The Feed's topic chips use the names mapped from arXiv categories.
public enum TagVocabulary {
    public static let version = "gradstep-tags-v1"

    public struct Tag: Equatable, Hashable, Sendable {
        public enum Kind: Sendable { case area, topic }
        public let name: String
        public let kind: Kind
        public let definition: String
        /// arXiv categories that map to this tag (the fallback when no model chose tags, and the Feed's names).
        public let categories: [String]
        init(_ name: String, _ kind: Kind, _ definition: String, _ categories: [String] = []) {
            self.name = name; self.kind = kind; self.definition = definition; self.categories = categories
        }
    }

    public static let tags: [Tag] = [
        .init("Machine learning", .area, "General machine learning methods not covered by a more specific area.", ["cs.LG", "stat.ML"]),
        .init("Natural language processing", .area, "Understanding and generating human language.", ["cs.CL"]),
        .init("Computer vision", .area, "Understanding and generating images and video.", ["cs.CV", "eess.IV"]),
        .init("Speech and audio", .area, "Speech, music and other audio signals.", ["eess.AS", "cs.SD"]),
        .init("Robotics", .area, "Learning and control for physical robots: manipulation, locomotion, navigation.", ["cs.RO"]),
        .init("Reinforcement learning", .area, "Learning to act from rewards through interaction with an environment."),
        .init("Information retrieval", .area, "Search, ranking and retrieval of documents or items.", ["cs.IR"]),
        .init("Recommender systems", .area, "Personalized recommendation and user modeling."),
        .init("Multimodal learning", .area, "Models that combine modalities such as text, images, audio or video."),
        .init("Graph learning", .area, "Learning on graphs, networks and relational data."),
        .init("Time series", .area, "Forecasting and modeling of sequential measurements over time."),
        .init("AI safety", .area, "Risks from AI systems and methods to keep them safe and controllable."),
        .init("AI for science", .area, "Machine learning for scientific discovery in physics, chemistry, biology, materials or climate."),
        .init("Healthcare and medicine", .area, "Clinical, medical imaging and health applications."),
        .init("Learning theory", .area, "Theory of learning: generalization, sample complexity, statistical guarantees."),
        .init("Optimization", .area, "Optimization methods and theory, including optimizers for training.", ["math.OC"]),
        .init("ML systems", .area, "Software and hardware for training and serving models at scale."),
        .init("Security", .area, "Attacks on and defenses of ML systems, and ML for computer security.", ["cs.CR"]),
        .init("AI and society", .area, "Social impact, ethics, policy and economics of AI."),
        .init("Human-AI interaction", .area, "How people use, perceive and work with AI systems."),
        .init("Artificial intelligence", .area, "Knowledge representation, search, logic and classical AI not covered by a more specific area.", ["cs.AI"]),
        .init("Multi-agent systems", .area, "Several interacting agents: cooperation, competition, communication, game theory.", ["cs.MA"]),
        .init("Evolutionary computation", .area, "Evolutionary algorithms, neuroevolution, and spiking or neuromorphic networks.", ["cs.NE"]),
        .init("Transformers", .topic, "The transformer architecture, attention and its variants."),
        .init("Large language models", .topic, "Training, behavior and capabilities of large language models."),
        .init("Vision-language models", .topic, "Models that jointly process images and text."),
        .init("Diffusion models", .topic, "Denoising diffusion and score-based generative models."),
        .init("Flow matching", .topic, "Normalizing flows, flow matching and continuous-time generative flows."),
        .init("Generative adversarial networks", .topic, "GANs and adversarially trained generators (as the method studied, not a baseline)."),
        .init("Variational autoencoders", .topic, "VAEs and latent-variable models with amortized inference."),
        .init("State space models", .topic, "Structured state space and linear recurrent sequence models."),
        .init("Recurrent neural networks", .topic, "RNNs, LSTMs and other recurrent architectures."),
        .init("Convolutional neural networks", .topic, "Convolutional architectures."),
        .init("Graph neural networks", .topic, "Message-passing and other neural networks on graphs."),
        .init("Mixture of experts", .topic, "Sparse models that route inputs to specialized expert subnetworks."),
        .init("Geometric deep learning", .topic, "Symmetry, equivariance and invariance in neural networks."),
        .init("Neural rendering", .topic, "Neural radiance fields, Gaussian splatting and learned 3D scene representations."),
        .init("World models", .topic, "Learned models of environment dynamics used for prediction, planning or simulation."),
        .init("Gaussian processes", .topic, "Gaussian process models and inference."),
        .init("Kernel methods", .topic, "Kernel machines and kernel analyses such as the neural tangent kernel."),
        .init("Pre-training", .topic, "How models are pre-trained: objectives, data and recipes."),
        .init("Fine-tuning", .topic, "Adapting pretrained models to new tasks or domains."),
        .init("Parameter-efficient fine-tuning", .topic, "Adapters, LoRA and other methods that train few parameters."),
        .init("Instruction tuning", .topic, "Supervised fine-tuning on instructions and demonstrations."),
        .init("Learning from human feedback", .topic, "RLHF and other training from human ratings or preferences."),
        .init("Preference optimization", .topic, "Direct preference optimization and related methods learning from preference pairs."),
        .init("Reward modeling", .topic, "Learning reward functions or verifiers that score model outputs."),
        .init("Self-supervised learning", .topic, "Learning from unlabeled data with pretext, masked or contrastive objectives (not weak labels)."),
        .init("Contrastive learning", .topic, "Learning by contrasting matching and non-matching pairs."),
        .init("Representation learning", .topic, "Learning useful features or embeddings."),
        .init("Transfer learning", .topic, "Reusing knowledge across tasks or domains."),
        .init("Distribution shift", .topic, "Domain adaptation, out-of-distribution generalization and detection."),
        .init("Meta-learning", .topic, "Learning to learn across many tasks."),
        .init("In-context learning", .topic, "Learning from examples given in a model's prompt."),
        .init("Continual learning", .topic, "Learning from a stream of tasks without forgetting earlier ones."),
        .init("Federated learning", .topic, "Training across decentralized data holders without pooling the data."),
        .init("Semi-supervised learning", .topic, "Learning from a few labels plus unlabeled data."),
        .init("Active learning", .topic, "Choosing which examples to label."),
        .init("Knowledge distillation", .topic, "Training a model to imitate another, usually larger, model."),
        .init("Model compression", .topic, "Pruning, low-rank and other ways to make models smaller."),
        .init("Quantization", .topic, "Low-precision weights, activations or training."),
        .init("Scaling laws", .topic, "How performance changes with model size, data and compute."),
        .init("Data curation", .topic, "Collecting, filtering, mixing and deduplicating training data."),
        .init("Synthetic data", .topic, "Generating training or evaluation data with models."),
        .init("AutoML", .topic, "Neural architecture search and hyperparameter optimization."),
        .init("Training dynamics", .topic, "How networks learn during training: loss landscapes, learning rates, grokking."),
        .init("Test-time scaling", .topic, "Spending more computation at inference: search, sampling, longer reasoning."),
        .init("Reasoning", .topic, "Multi-step reasoning in models, including chain-of-thought."),
        .init("Mathematical reasoning", .topic, "Solving math problems and formal theorem proving."),
        .init("Code generation", .topic, "Generating, understanding or repairing program code."),
        .init("AI agents", .topic, "Models that plan and act over many steps, operate software or use tools autonomously."),
        .init("Tool use", .topic, "Models calling external tools, APIs or code."),
        .init("Retrieval-augmented generation", .topic, "Grounding generation in retrieved documents."),
        .init("Prompting", .topic, "Prompt design and automatic prompt optimization."),
        .init("Long context", .topic, "Long inputs: context extension, memory and long-range evaluation."),
        .init("Efficient inference", .topic, "Faster or cheaper inference: speculative decoding, caching, serving."),
        .init("Tokenization", .topic, "How text and other inputs are split into tokens."),
        .init("Factuality", .topic, "Factual accuracy, grounding and hallucination in generated text."),
        .init("Evaluation", .topic, "Papers contributing a benchmark, metric or evaluation methodology."),
        .init("Machine translation", .topic, "Translating between languages."),
        .init("Question answering", .topic, "Answering questions from text, knowledge bases or the web."),
        .init("Summarization", .topic, "Condensing documents or conversations."),
        .init("Dialogue systems", .topic, "Conversational agents and chat assistants."),
        .init("Multilinguality", .topic, "Models and data for many languages, including low-resource ones."),
        .init("Knowledge graphs", .topic, "Structured knowledge bases and reasoning over them."),
        .init("Alignment", .topic, "Making model behavior match human intentions and values."),
        .init("Interpretability", .topic, "Explaining what models compute and why they predict what they do."),
        .init("Mechanistic interpretability", .topic, "Reverse-engineering the internal circuits and features of networks."),
        .init("Adversarial robustness", .topic, "Robustness to adversarial examples and perturbations."),
        .init("Red teaming", .topic, "Jailbreaks and adversarial testing that elicit unsafe model behavior."),
        .init("Privacy", .topic, "Differential privacy, memorization and data protection."),
        .init("Fairness", .topic, "Bias and fairness in data and models."),
        .init("Uncertainty", .topic, "Calibration and estimates of predictive uncertainty."),
        .init("Watermarking", .topic, "Marking and detecting AI-generated content."),
        .init("Machine unlearning", .topic, "Removing the influence of specific training data from a model."),
        .init("Image generation", .topic, "Generating or editing images."),
        .init("Video generation", .topic, "Generating or editing video."),
        .init("Object detection", .topic, "Locating and classifying objects in images."),
        .init("Segmentation", .topic, "Pixel-level labeling of images or video."),
        .init("3D vision", .topic, "3D reconstruction, depth, point clouds and scene understanding."),
        .init("Video understanding", .topic, "Recognizing actions, events and content in video."),
        .init("Autonomous driving", .topic, "Perception, prediction and planning for self-driving vehicles."),
        .init("Offline reinforcement learning", .topic, "Learning policies from fixed datasets without new interaction."),
        .init("Policy optimization", .topic, "Policy gradient, actor-critic and trust-region methods for learning policies."),
        .init("Model-based reinforcement learning", .topic, "Reinforcement learning that learns and uses a model of the environment's dynamics."),
        .init("Imitation learning", .topic, "Learning behavior from demonstrations."),
        .init("Planning", .topic, "Explicit search or planning over action sequences, such as tree search."),
        .init("Bandits and online learning", .topic, "Multi-armed and contextual bandits, regret and online decisions."),
        .init("Embodied AI", .topic, "Agents that perceive and act in physical or simulated 3D environments."),
        .init("Bayesian methods", .topic, "Bayesian and variational inference, sampling and probabilistic modeling."),
        .init("Causal inference", .topic, "Causal discovery and estimating causal effects."),
        .init("Generalization", .topic, "Why and when models generalize beyond their training data."),
        .init("Molecular modeling", .topic, "Molecules, materials and proteins: property prediction, generation and structure.", ["q-bio.BM"]),
        .init("Computational biology", .topic, "Genomics, single-cell and other biological data.", ["q-bio.GN"]),
        .init("Weather and climate", .topic, "Forecasting weather and modeling climate."),
        .init("Physics-informed learning", .topic, "Neural PDE solvers, physics-informed networks and scientific simulation."),
        .init("Tabular data", .topic, "Learning on tables and structured records."),
        .init("Anomaly detection", .topic, "Finding unusual patterns or outliers."),
        .init("Speech recognition", .topic, "Transcribing speech to text."),
        .init("Speech synthesis", .topic, "Text-to-speech and voice generation."),
    ]

    private static let byLowercasedName = Dictionary(tags.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    private static let byCategory = Dictionary(tags.flatMap { tag in tag.categories.map { ($0, tag.name) } }, uniquingKeysWith: { first, _ in first })

    /// The vocabulary entry for a name, ignoring case.
    public static func tag(named name: String) -> Tag? { byLowercasedName[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] }

    /// The vocabulary name for one arXiv category, if it has one ("cs.CL" → "Natural language processing").
    public static func name(forCategory category: String) -> String? { byCategory[category] }

    /// Distinct vocabulary names for a paper's arXiv categories, in the paper's order.
    public static func names(forCategories categories: [String], limit: Int = 3) -> [String] {
        var result: [String] = []
        for category in categories {
            guard let name = byCategory[category], !result.contains(name) else { continue }
            result.append(name)
            if result.count == limit { break }
        }
        return result
    }

    /// arXiv subject classes too broad to name a paper (build 70: "Hard no on AI/ML keywords"): machine learning, AI,
    /// language and vision. The server's `BROAD_CATEGORIES` is the same list (a backend test compares the two).
    public static let broadCategories: Set<String> = ["cs.LG", "stat.ML", "cs.AI", "cs.CL", "cs.CV", "eess.IV"]

    /// The last resort for a paper with no specific keyword from its title, abstract or catalog tags (owner, build 78:
    /// "No Gradstep keywords"): the names of its narrower arXiv subjects ("cs.IR" → "Information retrieval"), never the
    /// broad ones.
    public static func specificNames(forCategories categories: [String], limit: Int = 2) -> [String] {
        names(forCategories: categories.filter { !broadCategories.contains($0) }, limit: limit)
    }

    /// Keywords too broad to tell one paper from another (owner, builds 70 and 75): left out of derived keywords and
    /// of catalog tags as the reader sees them; a tag the reader typed stays theirs. Lower case, matched whole; the
    /// server's `GENERIC_KEYWORDS` is the same list (a backend test compares the two).
    public static let generic: Set<String> = [
        "llm", "llms", "large language model", "large language models", "language model", "language models",
        "foundation model", "foundation models", "vlm", "vlms", "mllm", "mllms", "reasoning", "evaluation", "benchmark",
        "benchmarks", "deep learning", "neural network", "neural networks", "transformer", "transformers", "generative ai",
    ]

    /// Suggestions for a typed prefix: names starting with it first, then names containing it (a word
    /// start before other matches), leaving out tags already chosen.
    public static func suggestions(for query: String, excluding chosen: [String], limit: Int = 8) -> [Tag] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return [] }
        let taken = Set(chosen.map { $0.lowercased() })
        let candidates = tags.filter { !taken.contains($0.name.lowercased()) }
        func rank(_ tag: Tag) -> Int? {
            let name = tag.name.lowercased()
            if name.hasPrefix(text) { return 0 }
            if name.split(separator: " ").contains(where: { $0.hasPrefix(text) }) || name.contains("-" + text) { return 1 }
            if name.contains(text) { return 2 }
            return nil
        }
        var ranked: [(tag: Tag, rank: Int)] = []
        for tag in candidates { if let value = rank(tag) { ranked.append((tag, value)) } }
        ranked.sort { left, right in left.rank == right.rank ? left.tag.name < right.tag.name : left.rank < right.rank }
        return Array(ranked.prefix(limit).map { $0.tag })
    }
}
