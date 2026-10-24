"""Encode the corpus (Feed pool + library papers) with each candidate model, locally.

Writes OUT/emb/<model>.npy (L2-normalised float32, row order = OUT/corpus.json) and OUT/models.json
(dimensions, throughput, disk size, skip reasons). Existing .npy files are reused unless --force.
"""
import argparse
import json
import os
import shutil
import sys
import time

import numpy as np
import torch

from common import OUT, load_corpus

DEVICE = "mps" if torch.backends.mps.is_available() else "cpu"
HF_HUB = os.path.expanduser(os.environ.get("HF_HUB_CACHE", "~/.cache/huggingface/hub"))

MODELS = {
    "gte-small": {"repo": "thenlper/gte-small", "kind": "st"},
    "bge-small-en-v1.5": {"repo": "BAAI/bge-small-en-v1.5", "kind": "st"},
    "specter2-proximity": {"repo": "allenai/specter2_base", "adapter": "allenai/specter2", "kind": "specter2"},
    "embeddinggemma-300m": {"repo": "google/embeddinggemma-300m", "kind": "st", "prompt": "title: none | text: "},
    "voyage-4-lite": {"kind": "api"},
}


def hub_size(repo: str) -> int:
    path = os.path.join(HF_HUB, "models--" + repo.replace("/", "--"))
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            p = os.path.join(root, f)
            if not os.path.islink(p):
                total += os.path.getsize(p)
    return total


def texts_plain(corpus):
    return [f"{p['title'].strip()}. {p['abstract'].strip()}" for p in corpus]


def encode_st(spec, corpus, batch):
    from sentence_transformers import SentenceTransformer

    model = SentenceTransformer(spec["repo"], device=DEVICE)
    texts = texts_plain(corpus)
    if spec.get("prompt"):
        texts = [spec["prompt"] + t for t in texts]
    max_len = model.max_seq_length
    model.encode(texts[:32], batch_size=32)  # warm-up
    t0 = time.perf_counter()
    emb = model.encode(texts, batch_size=batch, normalize_embeddings=True, show_progress_bar=True,
                       convert_to_numpy=True)
    return emb, time.perf_counter() - t0, max_len


def encode_specter2(spec, corpus, batch):
    from adapters import AutoAdapterModel
    from transformers import AutoTokenizer

    tok = AutoTokenizer.from_pretrained(spec["repo"])
    model = AutoAdapterModel.from_pretrained(spec["repo"])
    model.load_adapter(spec["adapter"], source="hf", load_as="proximity", set_active=True)
    model.to(DEVICE).eval()
    texts = [p["title"].strip() + tok.sep_token + p["abstract"].strip() for p in corpus]
    # Sort by length so batches pad little; restore order afterwards.
    order = np.argsort([len(t) for t in texts])
    out = np.zeros((len(texts), model.config.hidden_size), dtype=np.float32)

    def run(idx):
        enc = tok([texts[i] for i in idx], padding=True, truncation=True, max_length=512,
                  return_token_type_ids=False, return_tensors="pt").to(DEVICE)
        with torch.no_grad():
            return model(**enc).last_hidden_state[:, 0, :].float().cpu().numpy()

    run(order[:16])  # warm-up
    t0 = time.perf_counter()
    for s in range(0, len(order), batch):
        idx = order[s:s + batch]
        out[idx] = run(idx)
        if (s // batch) % 20 == 0:
            print(f"  specter2 {s}/{len(order)}", file=sys.stderr)
    if DEVICE == "mps":
        torch.mps.synchronize()
    dt = time.perf_counter() - t0
    out /= np.linalg.norm(out, axis=1, keepdims=True)
    return out, dt, 512


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", nargs="*", default=list(MODELS))
    ap.add_argument("--batch", type=int, default=64)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    corpus = load_corpus()
    os.makedirs(os.path.join(OUT, "emb"), exist_ok=True)
    info_path = os.path.join(OUT, "models.json")
    info = json.load(open(info_path)) if os.path.exists(info_path) else {}

    for name in args.models:
        spec = MODELS[name]
        npy = os.path.join(OUT, "emb", f"{name}.npy")
        if os.path.exists(npy) and not args.force:
            print(f"{name}: cached", file=sys.stderr)
            continue
        if spec["kind"] == "api":
            have_key = bool(os.environ.get("VOYAGE_API_KEY"))
            info[name] = {"skipped": "no Voyage API key present locally; paid API calls are out of scope"
                          if not have_key else "paid API calls are out of scope for this evaluation"}
            continue
        print(f"{name}: encoding {len(corpus)} papers on {DEVICE}", file=sys.stderr)
        try:
            if spec["kind"] == "st":
                emb, dt, max_len = encode_st(spec, corpus, args.batch)
            else:
                emb, dt, max_len = encode_specter2(spec, corpus, max(8, args.batch // 2))
        except Exception as e:  # gated or failing models are recorded and skipped
            msg = f"{type(e).__name__}: {str(e).splitlines()[0][:300]}"
            if type(e).__name__ == "GatedRepoError":
                msg = "gated on Hugging Face (terms not accepted or no HF token): GatedRepoError"
            print(f"{name}: skipped ({msg})", file=sys.stderr)
            info[name] = {"skipped": msg}
            json.dump(info, open(info_path, "w"), indent=1)
            continue
        np.save(npy, emb.astype(np.float32))
        size = hub_size(spec["repo"]) + (hub_size(spec["adapter"]) if spec.get("adapter") else 0)
        info[name] = {
            "repo": spec["repo"], "adapter": spec.get("adapter"), "dim": int(emb.shape[1]),
            "max_tokens": int(max_len), "device": DEVICE, "papers": len(corpus),
            "encode_seconds": round(dt, 1), "papers_per_second": round(len(corpus) / dt, 1),
            "disk_bytes": size, "disk_mb": round(size / 1e6, 1),
        }
        json.dump(info, open(info_path, "w"), indent=1)
        print(f"{name}: {info[name]}", file=sys.stderr)
        if DEVICE == "mps":
            torch.mps.empty_cache()
    json.dump(info, open(info_path, "w"), indent=1)


if __name__ == "__main__":
    main()
