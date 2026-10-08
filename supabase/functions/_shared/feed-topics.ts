// Topic tags for the Feed's shared pool without a model (docs/architecture/PERSONALIZED_FEED.md).
// Curated keyword rules map a new paper's title and abstract onto Gradstep's tag vocabulary
// (tag-vocabulary.ts), so the pool speaks the same language as readers' catalog and personal tags.
// Free and deterministic; coarser than the Haiku catalog tagger, which is why paying to tag the pool
// is the separate option C in the design.
//
// Changing a rule changes which papers get a tag: bump FEED_TOPICS_VERSION (pool rows record it).
import { TAG_VOCABULARY, tagsFromCategories } from './tag-vocabulary.ts';

export const FEED_TOPICS_VERSION = 'feed-topics-v1';

/** A rule: its patterns (one alternation is built from them) and the points it needs. A title match
 * is worth 2 points, each abstract match 1 (at most 2), so `min: 2` means "in the title, or twice". */
interface Rule { tag: string; any: RegExp[]; min?: number }

// Acronyms are matched case-sensitively; words case-insensitively.
const RULES: readonly Rule[] = [
  // Areas (broad; ranking weighs them lightly)
  { tag: 'Natural language processing', any: [/natural language|language models?|\bNLP\b|linguistic/i], min: 2 },
  { tag: 'Computer vision', any: [/\bimages?\b|computer vision|visual|video|pixel/i], min: 2 },
  { tag: 'Speech and audio', any: [/speech|audio|acoustic|spoken|music/i], min: 2 },
  { tag: 'Robotics', any: [/robot|manipulat(ion|or)|locomotion|grasp/i], min: 2 },
  { tag: 'Reinforcement learning', any: [/reinforcement learning|policy gradient|q-learning|markov decision process|reward shaping/i, /\bRL\b|\bMDPs?\b/] },
  { tag: 'Information retrieval', any: [/retrieval|search engines?|re-?ranking|dense retriev/i], min: 2 },
  { tag: 'Recommender systems', any: [/recommend(er|ation)|collaborative filtering|click-through/i] },
  { tag: 'Multimodal learning', any: [/multi-?modal|audio-visual|cross-modal/i] },
  { tag: 'Graph learning', any: [/\bgraphs?\b|node classification|link prediction/i], min: 2 },
  { tag: 'Time series', any: [/time[- ]series|forecasting/i] },
  { tag: 'AI safety', any: [/ai safety|catastrophic risks?|existential risk|deceptive (alignment|behaviou?r)|scheming|sandbagging|safety (evaluation|guardrails?)|harmful (content|outputs?|behaviou?r)/i] },
  { tag: 'AI for science', any: [/scientific discovery|physics|chemi(stry|cal)|materials? science|protein|molecul|astronom|climate|biolog/i], min: 2 },
  { tag: 'Healthcare and medicine', any: [/clinical|medical|patients?|health ?care|radiolog|diagnos|electronic health/i, /\bEHRs?\b/], min: 2 },
  { tag: 'Learning theory', any: [/generalization bounds?|sample complexity|regret bounds?|minimax|vc[- ]dimension|rademacher|statistical guarantees?|pac[- ]learn/i] },
  { tag: 'Optimization', any: [/optimizers?\b|stochastic gradient|non-?convex|\bconvex\b|convergence (rate|analysis|guarantee)/i, /\bSGD\b|\bAdamW?\b/], min: 2 },
  { tag: 'ML systems', any: [/\bGPUs?\b|\bTPUs?\b|\bFLOPs\b/, /throughput|distributed training|kernel fusion|memory footprint|accelerators?|compilers?|inference engine|pipeline parallel|tensor parallel/i], min: 2 },
  { tag: 'Security', any: [/malware|intrusion|vulnerabilit|backdoor|data poisoning|exploits?\b|cyber/i], min: 2 },
  { tag: 'AI and society', any: [/societ(y|al)|ethic|regulation|governance|labou?r market|misinformation|public policy/i], min: 2 },
  { tag: 'Human-AI interaction', any: [/user stud(y|ies)|participants|human-ai|human-computer|crowd ?workers|interviews? with/i], min: 2 },
  { tag: 'Multi-agent systems', any: [/multi-?agent/i] },
  { tag: 'Evolutionary computation', any: [/evolutionary|genetic algorithms?|neuroevolution|spiking neural|neuromorphic/i] },

  // Models and architectures
  { tag: 'Transformers', any: [/transformers?\b|self-attention|attention (mechanism|heads?|layers?)/i] },
  { tag: 'Large language models', any: [/large language models?|language models?/i, /\bLLMs?\b/] },
  { tag: 'Vision-language models', any: [/vision[- ]language|multimodal (large )?language models?|image-text/i, /\bVLMs?\b|\bMLLMs?\b|\bCLIP\b/] },
  { tag: 'Diffusion models', any: [/diffusion (models?|polic(y|ies)|transformers?|sampling|process(es)?)|denoising diffusion|score-based|latent diffusion|stable diffusion/i, /\bDDPMs?\b|\bDDIM\b/] },
  { tag: 'Flow matching', any: [/flow matching|normalizing flows?|rectified flows?|continuous normalizing/i] },
  { tag: 'Generative adversarial networks', any: [/generative adversarial/i, /\bGANs?\b/] },
  { tag: 'Variational autoencoders', any: [/variational auto-?encoders?/i, /\bVAEs?\b/] },
  { tag: 'State space models', any: [/state[- ]space models?|linear recurren|selective scan/i, /\bSSMs?\b|\bMamba\b|\bS4\b/] },
  { tag: 'Recurrent neural networks', any: [/recurrent neural/i, /\bRNNs?\b|\bLSTMs?\b|\bGRUs?\b/] },
  { tag: 'Convolutional neural networks', any: [/convolutional neural|convnets?/i, /\bCNNs?\b|\bResNets?\b/] },
  { tag: 'Graph neural networks', any: [/graph neural networks?|message[- ]passing|graph convolution|graph attention networks?/i, /\bGNNs?\b/] },
  { tag: 'Mixture of experts', any: [/mixture[- ]of[- ]experts|expert routing|sparse(ly[- ]activated)? experts|routed experts/i, /\bMoEs?\b/] },
  { tag: 'Geometric deep learning', any: [/equivarian|geometric deep learning|group convolution|symmetry-preserving/i, /\bSE\(3\)|\bE\(3\)|\bSO\(3\)/] },
  { tag: 'Neural rendering', any: [/neural radiance|gaussian splatting|novel[- ]view synthesis|neural rendering/i, /\bNeRFs?\b|\b3DGS\b/] },
  { tag: 'World models', any: [/world models?/i] },
  { tag: 'Gaussian processes', any: [/gaussian process/i] },
  { tag: 'Kernel methods', any: [/kernel (methods?|machines?|ridge|regression)|neural tangent kernel|reproducing kernel/i, /\bNTK\b|\bRKHS\b/] },

  // Training and learning paradigms
  { tag: 'Pre-training', any: [/pre-?training\b|pre-?training (data|corpus|objective|recipe)/i] },
  { tag: 'Fine-tuning', any: [/fine-?tun(e|es|ing|ed)/i] },
  { tag: 'Parameter-efficient fine-tuning', any: [/parameter-efficient|low-rank adaptation|prefix[- ]tuning|prompt[- ]tuning|adapter (layers?|modules?|tuning)/i, /\bLoRA\b|\bPEFT\b|\bQLoRA\b/] },
  { tag: 'Instruction tuning', any: [/instruction[- ](tun|follow)|supervised fine-tuning/i, /\bSFT\b/] },
  { tag: 'Learning from human feedback', any: [/human feedback|human preferences?|preference data/i, /\bRLHF\b|\bRLAIF\b/] },
  { tag: 'Preference optimization', any: [/preference optimi[sz]ation|direct preference|preference pairs/i, /\bDPO\b|\bKTO\b|\bORPO\b|\bSimPO\b|\bIPO\b/] },
  { tag: 'Reward modeling', any: [/reward models?|reward modeling|process reward|outcome reward|verifiers?\b/i, /\bPRMs?\b|\bORMs?\b/] },
  { tag: 'Self-supervised learning', any: [/self-supervised|masked (image|autoencod|language model)|pretext tasks?/i, /\bMAE\b/] },
  { tag: 'Contrastive learning', any: [/contrastive/i] },
  { tag: 'Representation learning', any: [/representation learning|learn(s|ed|ing)? (useful |rich |robust |good )?representations/i] },
  { tag: 'Transfer learning', any: [/transfer learning|knowledge transfer|transferab/i] },
  { tag: 'Distribution shift', any: [/distribution(al)? shifts?|domain adaptation|out-of-distribution|domain generali[sz]ation|covariate shift/i, /\bOOD\b/] },
  { tag: 'Meta-learning', any: [/meta-?learn|learning to learn|few-shot learning/i] },
  { tag: 'In-context learning', any: [/in-context learning|in-context examples|in-context demonstrations/i, /\bICL\b/] },
  { tag: 'Continual learning', any: [/continual learning|lifelong learning|catastrophic forgetting|class-incremental/i] },
  { tag: 'Federated learning', any: [/federated/i] },
  { tag: 'Semi-supervised learning', any: [/semi-supervised|pseudo-?label/i] },
  { tag: 'Active learning', any: [/active learning/i] },
  { tag: 'Knowledge distillation', any: [/distillation|distil(l|led|ling) (into|from)|teacher[- ]student/i] },
  { tag: 'Model compression', any: [/\bpruning\b|model compression|low-rank (approximation|factori[sz]ation|compression)|sparsif/i] },
  { tag: 'Quantization', any: [/quantiz|quantis/i] },
  { tag: 'Scaling laws', any: [/scaling laws?|compute-optimal|scaling behaviou?r/i] },
  { tag: 'Data curation', any: [/data (curation|filtering|selection|mixtures?|deduplication|quality)|dataset curation/i] },
  { tag: 'Synthetic data', any: [/synthetic data|data synthesis|synthetically generated/i] },
  { tag: 'AutoML', any: [/neural architecture search|hyperparameter (optimi[sz]ation|tuning|search)|automl/i, /\bNAS\b/] },
  { tag: 'Training dynamics', any: [/training dynamics|loss landscapes?|grokking|edge of stability|learning[- ]rate (schedules?|warm-?up)/i] },
  { tag: 'Test-time scaling', any: [/test-time (compute|scaling|training|adaptation)|inference-time (compute|scaling)|best-of-n|self-consistency/i] },

  // Language model capabilities and applications
  { tag: 'Reasoning', any: [/reasoning|chain[- ]of[- ]thought/i, /\bCoT\b/] },
  { tag: 'Mathematical reasoning', any: [/math(ematical)? (reasoning|problems?|word problems)|theorem proving|olympiad/i, /\bGSM8K\b|\bLean 4\b|\bMATH-500\b/] },
  { tag: 'Code generation', any: [/code generation|program synthesis|coding (agents?|tasks?|benchmarks?)|code (llms?|models?|completion)|software engineering tasks/i, /\bSWE-bench\b|\bHumanEval\b/] },
  { tag: 'AI agents', any: [/agentic|(llm|language|web|computer-use|gui|autonomous|software|coding|research) agents?/i] },
  { tag: 'Tool use', any: [/tool[- ](use|calling|learning|augmented)|function calling/i] },
  { tag: 'Retrieval-augmented generation', any: [/retrieval[- ]augmented/i, /\bRAG\b/] },
  { tag: 'Prompting', any: [/prompt(ing| engineering| optimi[sz]ation| design)/i] },
  { tag: 'Long context', any: [/long[- ]context|context (window|length) (extension|scaling)|million[- ]tokens?/i] },
  { tag: 'Efficient inference', any: [/speculative decoding|kv[- ]cache|inference (efficiency|acceleration|latency|cost)|efficient inference|early[- ]exit/i] },
  { tag: 'Tokenization', any: [/tokeni[sz](ation|er)/i] },
  { tag: 'Factuality', any: [/hallucinat|factual(ity)?|faithfulness/i] },
  { tag: 'Evaluation', any: [/benchmarks?\b|evaluation (framework|protocol|suite|methodology)|leaderboard/i], min: 2 },
  { tag: 'Machine translation', any: [/machine translation|translation quality/i, /\bNMT\b/] },
  { tag: 'Question answering', any: [/question[- ]answering/i, /\bQA\b|\bVQA\b/] },
  { tag: 'Summarization', any: [/summari[sz]/i] },
  { tag: 'Dialogue systems', any: [/dialog(ue)? (systems?|agents?|generation)|conversational (agents?|systems?|ai)|chatbots?/i] },
  { tag: 'Multilinguality', any: [/multilingual|cross-lingual|low-resource languages?/i] },
  { tag: 'Knowledge graphs', any: [/knowledge graphs?|knowledge bases?/i, /\bKGs?\b/] },

  // Safety, robustness and trust
  { tag: 'Alignment', any: [/align(ment|ing)? (with )?(human (values|preferences|intent)|language models|llms)|value alignment|ai alignment|alignment (tax|methods?|techniques?|training)/i] },
  { tag: 'Interpretability', any: [/interpretab|explainab|saliency|feature attribution|probing (classifiers?|experiments?)/i, /\bXAI\b/] },
  { tag: 'Mechanistic interpretability', any: [/mechanistic|sparse auto-?encoders?|superposition|activation patching|monosemantic|circuit discovery/i, /\bSAEs?\b/] },
  { tag: 'Adversarial robustness', any: [/adversarial (examples?|attacks?|robustness|perturbations?|training)|certified robustness/i] },
  { tag: 'Red teaming', any: [/red[- ]teaming|jailbreak/i] },
  { tag: 'Privacy', any: [/differential(ly)? priva|membership inference|privacy[- ]preserving|data leakage|memori[sz]ation/i] },
  { tag: 'Fairness', any: [/fairness|debias|demographic (bias|parity)|social bias/i] },
  { tag: 'Uncertainty', any: [/uncertainty (quantification|estimation|estimates)|(model|confidence|probabilistic) calibration|well-calibrated|miscalibrat|expected calibration error|conformal prediction|predictive uncertainty|epistemic uncertainty/i] },
  { tag: 'Watermarking', any: [/watermark/i] },
  { tag: 'Machine unlearning', any: [/unlearning/i] },

  // Vision
  { tag: 'Image generation', any: [/image (generation|synthesis|editing)|text-to-image/i] },
  { tag: 'Video generation', any: [/video (generation|synthesis|diffusion)|text-to-video/i] },
  { tag: 'Object detection', any: [/object detection|bounding box|open-vocabulary detection/i, /\bYOLO/] },
  { tag: 'Segmentation', any: [/(image|semantic|instance|panoptic|medical|video|object|scene|3d|point cloud|part|referring|lesion|tumou?r) segmentation|segmentation (masks?|models?|networks?|tasks?)|segment anything/i] },
  { tag: '3D vision', any: [/point clouds?|depth estimation|3d (reconstruction|scenes?|object|generation|understanding)|multi-view stereo/i, /\bSLAM\b/] },
  { tag: 'Video understanding', any: [/video (understanding|question answering|recognition|retrieval|captioning)|action recognition|temporal grounding/i] },
  { tag: 'Autonomous driving', any: [/autonomous (driving|vehicles?)|self-driving|motion forecasting|trajectory prediction for (vehicles|agents)/i, /\bnuScenes\b/] },

  // Decision making
  { tag: 'Offline reinforcement learning', any: [/offline (reinforcement learning|rl)\b|batch reinforcement learning/i] },
  { tag: 'Policy optimization', any: [/policy optimi[sz]ation|policy gradients?|actor-critic/i, /\bPPO\b|\bGRPO\b|\bTRPO\b/] },
  { tag: 'Model-based reinforcement learning', any: [/model-based (reinforcement learning|rl)\b|learned dynamics models?/i] },
  { tag: 'Imitation learning', any: [/imitation learning|behaviou?r(al)? cloning|learning from demonstrations?/i] },
  { tag: 'Planning', any: [/\bplanning\b|tree search|monte carlo tree/i, /\bMCTS\b/] },
  { tag: 'Bandits and online learning', any: [/\bbandits?\b|online learning|online convex/i] },
  { tag: 'Embodied AI', any: [/embodied|vision-language-action|household tasks/i, /\bVLAs?\b/] },

  // Probabilistic methods and science
  { tag: 'Bayesian methods', any: [/bayesian|variational inference|langevin/i, /\bMCMC\b/] },
  { tag: 'Causal inference', any: [/causal/i] },
  { tag: 'Generalization', any: [/generali[sz]ation (gap|bounds?|error|ability|performance)|overfitting|benign overfitting/i], min: 2 },
  { tag: 'Molecular modeling', any: [/molecul|proteins?\b|drug discovery|materials? (discovery|design|property)|crystal structures?/i] },
  { tag: 'Computational biology', any: [/genom|single-cell|gene expression|biological sequences/i, /\bDNA\b|\bRNA\b/] },
  { tag: 'Weather and climate', any: [/weather|climate|precipitation|meteorolog/i] },
  { tag: 'Physics-informed learning', any: [/physics-informed|neural operators?|pde solvers?|partial differential equations?/i, /\bPINNs?\b/] },
  { tag: 'Tabular data', any: [/tabular/i] },
  { tag: 'Anomaly detection', any: [/anomal(y|ies|ous)|outlier detection|novelty detection/i] },
  { tag: 'Speech recognition', any: [/speech recognition|automatic speech/i, /\bASR\b/] },
  { tag: 'Speech synthesis', any: [/text-to-speech|speech synthesis|voice (cloning|conversion)/i, /\bTTS\b/] },
];

/** The rule set's tags (a backend test checks each is a vocabulary name). */
export const FEED_TOPIC_TAGS: readonly string[] = Object.freeze(RULES.map(rule => rule.tag));

// One case-insensitive and one case-sensitive alternation per rule, global for counting.
const COMPILED = RULES.map(rule => {
  const insensitive = rule.any.filter(p => p.flags.includes('i')).map(p => `(?:${p.source})`);
  const sensitive = rule.any.filter(p => !p.flags.includes('i')).map(p => `(?:${p.source})`);
  return { tag: rule.tag, min: rule.min ?? 1,
    patterns: [insensitive.length ? new RegExp(insensitive.join('|'), 'giu') : null, sensitive.length ? new RegExp(sensitive.join('|'), 'gu') : null]
      .filter((p): p is RegExp => p !== null) };
});

function count(pattern: RegExp, text: string, limit: number): number {
  pattern.lastIndex = 0;
  let n = 0;
  while (n < limit && pattern.exec(text)) n++;
  pattern.lastIndex = 0;
  return n;
}

/** Vocabulary tags for a pool paper: rule matches, strongest first (at most 8), then the tags its
 * arXiv categories name (at most 2 more). */
export function feedTopics(title: string, abstract: string | null, categories: readonly string[]): string[] {
  const head = title.normalize('NFKC'), body = (abstract ?? '').normalize('NFKC');
  const scored: { tag: string; points: number; order: number }[] = [];
  COMPILED.forEach((rule, order) => {
    let points = 0;
    for (const pattern of rule.patterns) {
      points += count(pattern, head, 1) * 2 + count(pattern, body, 2);
      if (points >= 4) break;
    }
    if (points >= rule.min) scored.push({ tag: rule.tag, points: Math.min(points, 4), order });
  });
  const topics = scored.sort((a, b) => b.points - a.points || a.order - b.order).slice(0, 8).map(s => s.tag);
  for (const tag of tagsFromCategories(categories, 2)) if (!topics.includes(tag)) topics.push(tag);
  return topics;
}

// Broad areas: the vocabulary's areas that are an arXiv category's name ("Machine learning" for
// cs.LG/stat.ML, "Natural language processing" for cs.CL, …). The Feed reaches those through its
// category chips ("More topics"); as a paper's topic they say little (owner feedback, build 21).
const AREA_NAMES = new Set(TAG_VOCABULARY.filter(tag => tag.kind === 'area').map(tag => tag.name));
const BROAD_AREAS = new Set(TAG_VOCABULARY.filter(tag => tag.kind === 'area' && (tag.categories?.length ?? 0) > 0).map(tag => tag.name));

/** Whether a vocabulary tag is an area (a field), not a specific topic. */
export function isArea(tag: string): boolean { return AREA_NAMES.has(tag); }
/** Whether a vocabulary tag is a broad area named after an arXiv category. */
export function isBroadArea(tag: string): boolean { return BROAD_AREAS.has(tag); }

/** A paper's topics as the Feed shows them (the Topics column, row details): specific topics first in
 * their rule order, then other areas; broad category areas only when nothing more specific applies. */
export function displayTopics(topics: readonly string[], limit = 4): string[] {
  const unique = [...new Set(topics)];
  const specific = unique.filter(tag => !AREA_NAMES.has(tag));
  const areas = unique.filter(tag => AREA_NAMES.has(tag) && !BROAD_AREAS.has(tag));
  const broad = unique.filter(tag => BROAD_AREAS.has(tag));
  const chosen = [...specific, ...areas];
  return (chosen.length ? chosen : broad).slice(0, limit);
}
