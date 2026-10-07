// Gradstep's topic tags (docs/architecture/TAGS.md): one curated, stable vocabulary of
// ML research areas and topics. Catalog tags are chosen from it (by Claude Haiku from
// the title and abstract, or from arXiv categories as a fallback); the reader's own tags
// may be free text, with these as suggestions. The app keeps the same names and category
// mapping in ScienceReaderCore/TagVocabulary.swift (a backend test compares the two).
//
// Changing a name or removing a tag is a vocabulary version change: bump
// TAG_VOCABULARY_VERSION so catalog papers are re-tagged (the worker re-tags rows
// recorded under another version). Adding a tag can keep the version.

export const TAG_VOCABULARY_VERSION = 'gradstep-tags-v1';

export interface VocabularyTag {
  /** Shown to readers. Sentence case, at most 40 characters. */
  name: string;
  /** Areas are broad fields (one or two per paper); topics are specific methods, problems or applications. */
  kind: 'area' | 'topic';
  /** One line for the model (and the app's suggestions). */
  definition: string;
  /** arXiv categories that are essentially this tag (the fallback, and the Feed's chip names for those
   * categories' listings). Only where the category means the same thing: a broader category stays unmapped. */
  categories?: string[];
}

export const TAG_VOCABULARY: readonly VocabularyTag[] = Object.freeze([
  // Areas
  { name: 'Machine learning', kind: 'area', definition: 'General machine learning methods not covered by a more specific area.', categories: ['cs.LG', 'stat.ML'] },
  { name: 'Natural language processing', kind: 'area', definition: 'Understanding and generating human language.', categories: ['cs.CL'] },
  { name: 'Computer vision', kind: 'area', definition: 'Understanding and generating images and video.', categories: ['cs.CV', 'eess.IV'] },
  { name: 'Speech and audio', kind: 'area', definition: 'Speech, music and other audio signals.', categories: ['eess.AS', 'cs.SD'] },
  { name: 'Robotics', kind: 'area', definition: 'Learning and control for physical robots: manipulation, locomotion, navigation.', categories: ['cs.RO'] },
  { name: 'Reinforcement learning', kind: 'area', definition: 'Learning to act from rewards through interaction with an environment.' },
  { name: 'Information retrieval', kind: 'area', definition: 'Search, ranking and retrieval of documents or items.', categories: ['cs.IR'] },
  { name: 'Recommender systems', kind: 'area', definition: 'Personalized recommendation and user modeling.' },
  { name: 'Multimodal learning', kind: 'area', definition: 'Models that combine modalities such as text, images, audio or video.' },
  { name: 'Graph learning', kind: 'area', definition: 'Learning on graphs, networks and relational data.' },
  { name: 'Time series', kind: 'area', definition: 'Forecasting and modeling of sequential measurements over time.' },
  { name: 'AI safety', kind: 'area', definition: 'Risks from AI systems and methods to keep them safe and controllable.' },
  { name: 'AI for science', kind: 'area', definition: 'Machine learning for scientific discovery in physics, chemistry, biology, materials or climate.' },
  { name: 'Healthcare and medicine', kind: 'area', definition: 'Clinical, medical imaging and health applications.' },
  { name: 'Learning theory', kind: 'area', definition: 'Theory of learning: generalization, sample complexity, statistical guarantees.' },
  { name: 'Optimization', kind: 'area', definition: 'Optimization methods and theory, including optimizers for training.', categories: ['math.OC'] },
  { name: 'ML systems', kind: 'area', definition: 'Software and hardware for training and serving models at scale.' },
  { name: 'Security', kind: 'area', definition: 'Attacks on and defenses of ML systems, and ML for computer security.', categories: ['cs.CR'] },
  { name: 'AI and society', kind: 'area', definition: 'Social impact, ethics, policy and economics of AI.' },
  { name: 'Human-AI interaction', kind: 'area', definition: 'How people use, perceive and work with AI systems.' },
  { name: 'Artificial intelligence', kind: 'area', definition: 'Knowledge representation, search, logic and classical AI not covered by a more specific area.', categories: ['cs.AI'] },
  { name: 'Multi-agent systems', kind: 'area', definition: 'Several interacting agents: cooperation, competition, communication, game theory.', categories: ['cs.MA'] },
  { name: 'Evolutionary computation', kind: 'area', definition: 'Evolutionary algorithms, neuroevolution, and spiking or neuromorphic networks.', categories: ['cs.NE'] },

  // Models and architectures
  { name: 'Transformers', kind: 'topic', definition: 'The transformer architecture, attention and its variants.' },
  { name: 'Large language models', kind: 'topic', definition: 'Training, behavior and capabilities of large language models.' },
  { name: 'Vision-language models', kind: 'topic', definition: 'Models that jointly process images and text.' },
  { name: 'Diffusion models', kind: 'topic', definition: 'Denoising diffusion and score-based generative models.' },
  { name: 'Flow matching', kind: 'topic', definition: 'Normalizing flows, flow matching and continuous-time generative flows.' },
  { name: 'Generative adversarial networks', kind: 'topic', definition: 'GANs and adversarially trained generators (as the method studied, not a baseline).' },
  { name: 'Variational autoencoders', kind: 'topic', definition: 'VAEs and latent-variable models with amortized inference.' },
  { name: 'State space models', kind: 'topic', definition: 'Structured state space and linear recurrent sequence models.' },
  { name: 'Recurrent neural networks', kind: 'topic', definition: 'RNNs, LSTMs and other recurrent architectures.' },
  { name: 'Convolutional neural networks', kind: 'topic', definition: 'Convolutional architectures.' },
  { name: 'Graph neural networks', kind: 'topic', definition: 'Message-passing and other neural networks on graphs.' },
  { name: 'Mixture of experts', kind: 'topic', definition: 'Sparse models that route inputs to specialized expert subnetworks.' },
  { name: 'Geometric deep learning', kind: 'topic', definition: 'Symmetry, equivariance and invariance in neural networks.' },
  { name: 'Neural rendering', kind: 'topic', definition: 'Neural radiance fields, Gaussian splatting and learned 3D scene representations.' },
  { name: 'World models', kind: 'topic', definition: 'Learned models of environment dynamics used for prediction, planning or simulation.' },
  { name: 'Gaussian processes', kind: 'topic', definition: 'Gaussian process models and inference.' },
  { name: 'Kernel methods', kind: 'topic', definition: 'Kernel machines and kernel analyses such as the neural tangent kernel.' },

  // Training and learning paradigms
  { name: 'Pre-training', kind: 'topic', definition: 'How models are pre-trained: objectives, data and recipes.' },
  { name: 'Fine-tuning', kind: 'topic', definition: 'Adapting pretrained models to new tasks or domains.' },
  { name: 'Parameter-efficient fine-tuning', kind: 'topic', definition: 'Adapters, LoRA and other methods that train few parameters.' },
  { name: 'Instruction tuning', kind: 'topic', definition: 'Supervised fine-tuning on instructions and demonstrations.' },
  { name: 'Learning from human feedback', kind: 'topic', definition: 'RLHF and other training from human ratings or preferences.' },
  { name: 'Preference optimization', kind: 'topic', definition: 'Direct preference optimization and related methods learning from preference pairs.' },
  { name: 'Reward modeling', kind: 'topic', definition: 'Learning reward functions or verifiers that score model outputs.' },
  { name: 'Self-supervised learning', kind: 'topic', definition: 'Learning from unlabeled data with pretext, masked or contrastive objectives (not weak labels).' },
  { name: 'Contrastive learning', kind: 'topic', definition: 'Learning by contrasting matching and non-matching pairs.' },
  { name: 'Representation learning', kind: 'topic', definition: 'Learning useful features or embeddings.' },
  { name: 'Transfer learning', kind: 'topic', definition: 'Reusing knowledge across tasks or domains.' },
  { name: 'Distribution shift', kind: 'topic', definition: 'Domain adaptation, out-of-distribution generalization and detection.' },
  { name: 'Meta-learning', kind: 'topic', definition: 'Learning to learn across many tasks.' },
  { name: 'In-context learning', kind: 'topic', definition: 'Learning from examples given in a model\'s prompt.' },
  { name: 'Continual learning', kind: 'topic', definition: 'Learning from a stream of tasks without forgetting earlier ones.' },
  { name: 'Federated learning', kind: 'topic', definition: 'Training across decentralized data holders without pooling the data.' },
  { name: 'Semi-supervised learning', kind: 'topic', definition: 'Learning from a few labels plus unlabeled data.' },
  { name: 'Active learning', kind: 'topic', definition: 'Choosing which examples to label.' },
  { name: 'Knowledge distillation', kind: 'topic', definition: 'Training a model to imitate another, usually larger, model.' },
  { name: 'Model compression', kind: 'topic', definition: 'Pruning, low-rank and other ways to make models smaller.' },
  { name: 'Quantization', kind: 'topic', definition: 'Low-precision weights, activations or training.' },
  { name: 'Scaling laws', kind: 'topic', definition: 'How performance changes with model size, data and compute.' },
  { name: 'Data curation', kind: 'topic', definition: 'Collecting, filtering, mixing and deduplicating training data.' },
  { name: 'Synthetic data', kind: 'topic', definition: 'Generating training or evaluation data with models.' },
  { name: 'AutoML', kind: 'topic', definition: 'Neural architecture search and hyperparameter optimization.' },
  { name: 'Training dynamics', kind: 'topic', definition: 'How networks learn during training: loss landscapes, learning rates, grokking.' },
  { name: 'Test-time scaling', kind: 'topic', definition: 'Spending more computation at inference: search, sampling, longer reasoning.' },

  // Language model capabilities and applications
  { name: 'Reasoning', kind: 'topic', definition: 'Multi-step reasoning in models, including chain-of-thought.' },
  { name: 'Mathematical reasoning', kind: 'topic', definition: 'Solving math problems and formal theorem proving.' },
  { name: 'Code generation', kind: 'topic', definition: 'Generating, understanding or repairing program code.' },
  { name: 'AI agents', kind: 'topic', definition: 'Models that plan and act over many steps, operate software or use tools autonomously.' },
  { name: 'Tool use', kind: 'topic', definition: 'Models calling external tools, APIs or code.' },
  { name: 'Retrieval-augmented generation', kind: 'topic', definition: 'Grounding generation in retrieved documents.' },
  { name: 'Prompting', kind: 'topic', definition: 'Prompt design and automatic prompt optimization.' },
  { name: 'Long context', kind: 'topic', definition: 'Long inputs: context extension, memory and long-range evaluation.' },
  { name: 'Efficient inference', kind: 'topic', definition: 'Faster or cheaper inference: speculative decoding, caching, serving.' },
  { name: 'Tokenization', kind: 'topic', definition: 'How text and other inputs are split into tokens.' },
  { name: 'Factuality', kind: 'topic', definition: 'Factual accuracy, grounding and hallucination in generated text.' },
  { name: 'Evaluation', kind: 'topic', definition: 'Papers contributing a benchmark, metric or evaluation methodology.' },
  { name: 'Machine translation', kind: 'topic', definition: 'Translating between languages.' },
  { name: 'Question answering', kind: 'topic', definition: 'Answering questions from text, knowledge bases or the web.' },
  { name: 'Summarization', kind: 'topic', definition: 'Condensing documents or conversations.' },
  { name: 'Dialogue systems', kind: 'topic', definition: 'Conversational agents and chat assistants.' },
  { name: 'Multilinguality', kind: 'topic', definition: 'Models and data for many languages, including low-resource ones.' },
  { name: 'Knowledge graphs', kind: 'topic', definition: 'Structured knowledge bases and reasoning over them.' },

  // Safety, robustness and trust
  { name: 'Alignment', kind: 'topic', definition: 'Making model behavior match human intentions and values.' },
  { name: 'Interpretability', kind: 'topic', definition: 'Explaining what models compute and why they predict what they do.' },
  { name: 'Mechanistic interpretability', kind: 'topic', definition: 'Reverse-engineering the internal circuits and features of networks.' },
  { name: 'Adversarial robustness', kind: 'topic', definition: 'Robustness to adversarial examples and perturbations.' },
  { name: 'Red teaming', kind: 'topic', definition: 'Jailbreaks and adversarial testing that elicit unsafe model behavior.' },
  { name: 'Privacy', kind: 'topic', definition: 'Differential privacy, memorization and data protection.' },
  { name: 'Fairness', kind: 'topic', definition: 'Bias and fairness in data and models.' },
  { name: 'Uncertainty', kind: 'topic', definition: 'Calibration and estimates of predictive uncertainty.' },
  { name: 'Watermarking', kind: 'topic', definition: 'Marking and detecting AI-generated content.' },
  { name: 'Machine unlearning', kind: 'topic', definition: 'Removing the influence of specific training data from a model.' },

  // Vision
  { name: 'Image generation', kind: 'topic', definition: 'Generating or editing images.' },
  { name: 'Video generation', kind: 'topic', definition: 'Generating or editing video.' },
  { name: 'Object detection', kind: 'topic', definition: 'Locating and classifying objects in images.' },
  { name: 'Segmentation', kind: 'topic', definition: 'Pixel-level labeling of images or video.' },
  { name: '3D vision', kind: 'topic', definition: '3D reconstruction, depth, point clouds and scene understanding.' },
  { name: 'Video understanding', kind: 'topic', definition: 'Recognizing actions, events and content in video.' },
  { name: 'Autonomous driving', kind: 'topic', definition: 'Perception, prediction and planning for self-driving vehicles.' },

  // Decision making
  { name: 'Offline reinforcement learning', kind: 'topic', definition: 'Learning policies from fixed datasets without new interaction.' },
  { name: 'Policy optimization', kind: 'topic', definition: 'Policy gradient, actor-critic and trust-region methods for learning policies.' },
  { name: 'Model-based reinforcement learning', kind: 'topic', definition: 'Reinforcement learning that learns and uses a model of the environment\'s dynamics.' },
  { name: 'Imitation learning', kind: 'topic', definition: 'Learning behavior from demonstrations.' },
  { name: 'Planning', kind: 'topic', definition: 'Explicit search or planning over action sequences, such as tree search.' },
  { name: 'Bandits and online learning', kind: 'topic', definition: 'Multi-armed and contextual bandits, regret and online decisions.' },
  { name: 'Embodied AI', kind: 'topic', definition: 'Agents that perceive and act in physical or simulated 3D environments.' },

  // Probabilistic methods
  { name: 'Bayesian methods', kind: 'topic', definition: 'Bayesian and variational inference, sampling and probabilistic modeling.' },
  { name: 'Causal inference', kind: 'topic', definition: 'Causal discovery and estimating causal effects.' },
  { name: 'Generalization', kind: 'topic', definition: 'Why and when models generalize beyond their training data.' },

  // Science and other applications
  { name: 'Molecular modeling', kind: 'topic', definition: 'Molecules, materials and proteins: property prediction, generation and structure.', categories: ['q-bio.BM'] },
  { name: 'Computational biology', kind: 'topic', definition: 'Genomics, single-cell and other biological data.', categories: ['q-bio.GN'] },
  { name: 'Weather and climate', kind: 'topic', definition: 'Forecasting weather and modeling climate.' },
  { name: 'Physics-informed learning', kind: 'topic', definition: 'Neural PDE solvers, physics-informed networks and scientific simulation.' },
  { name: 'Tabular data', kind: 'topic', definition: 'Learning on tables and structured records.' },
  { name: 'Anomaly detection', kind: 'topic', definition: 'Finding unusual patterns or outliers.' },
  { name: 'Speech recognition', kind: 'topic', definition: 'Transcribing speech to text.' },
  { name: 'Speech synthesis', kind: 'topic', definition: 'Text-to-speech and voice generation.' },
] satisfies VocabularyTag[]);

export const TAG_NAMES: readonly string[] = Object.freeze(TAG_VOCABULARY.map(tag => tag.name));
const byLowerName = new Map(TAG_VOCABULARY.map(tag => [tag.name.toLowerCase(), tag.name]));
const byCategory = new Map(TAG_VOCABULARY.flatMap(tag => (tag.categories ?? []).map(category => [category, tag.name] as const)));

/** The vocabulary's spelling of a tag name (case-insensitive), or null. */
export function vocabularyName(value: string): string | null {
  return byLowerName.get(value.trim().toLowerCase()) ?? null;
}

/** Fallback tags from arXiv categories: distinct vocabulary names in the paper's own order, at most `limit`. */
export function tagsFromCategories(categories: readonly string[], limit = 3): string[] {
  const result: string[] = [];
  for (const category of categories) {
    const name = byCategory.get(category);
    if (name && !result.includes(name)) result.push(name);
    if (result.length === limit) break;
  }
  return result;
}
