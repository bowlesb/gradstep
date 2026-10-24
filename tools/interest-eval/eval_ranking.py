"""Evaluation 1: leave-one-out ranking of each held-out library paper among the Feed pool.

For each library paper with an abstract, the profile is the remaining library papers (recency weights from
PERSONALIZED_FEED.md); candidates are the pool minus every library paper, plus the held-out paper.
Writes OUT/eval1_ranking.json.
"""
import json
import math
import os

import numpy as np
from sklearn.cluster import AgglomerativeClustering

from common import OUT, library_labels, load_corpus, load_library

RNG = np.random.default_rng(7)


def n_clusters(n):
    return max(1, round(math.sqrt(n / 2)))


def centroids(V, w, k):
    if k <= 1 or len(V) < 3:
        c = (w[:, None] * V).sum(0, keepdims=True)
    else:
        lab = AgglomerativeClustering(n_clusters=min(k, len(V)), metric="cosine", linkage="average").fit_predict(V)
        c = np.stack([(w[lab == g, None] * V[lab == g]).sum(0) for g in np.unique(lab)])
    return c / np.linalg.norm(c, axis=1, keepdims=True)


def topk_mean(S, k=3):
    k = min(k, S.shape[1])
    return np.sort(S, axis=1)[:, -k:].mean(1)


def scorers(prof, w, cand):
    """Return {name: scores} for candidate vectors given profile vectors and weights."""
    mean = (w[:, None] * prof).sum(0)
    mean /= np.linalg.norm(mean)
    S = cand @ prof.T
    out = {
        "mean": cand @ mean,
        "knn3": topk_mean(S, 3),
        "multi-centroid": (cand @ centroids(prof, w, n_clusters(len(prof))).T).max(1),
    }
    out["blend(0.5 knn3 + 0.15 mean)"] = (0.5 * out["knn3"] + 0.15 * out["mean"]) / 0.65
    return out


def evaluate(E, lib_idx, weights, pool_idx):
    P = E[pool_idx]
    ranks = {}
    for i in range(len(lib_idx)):
        keep = np.array([j for j in range(len(lib_idx)) if j != i])
        prof, w = E[lib_idx[keep]], weights[keep]
        held = E[lib_idx[i]][None, :]
        s_pool = scorers(prof, w, P)
        s_held = scorers(prof, w, held)
        for name in s_pool:
            ranks.setdefault(name, []).append(int((s_pool[name] > s_held[name][0]).sum()) + 1)
    return {k: np.array(v) for k, v in ranks.items()}


def metrics(r, n_cand):
    boot = RNG.integers(0, len(r), size=(2000, len(r)))
    r50 = (r[boot] <= 50).mean(1)
    return {
        "recall@10": float((r <= 10).mean()), "recall@50": float((r <= 50).mean()),
        "recall@100": float((r <= 100).mean()), "mrr": float((1 / r).mean()),
        "median_rank": float(np.median(r)), "recall@50_ci95": [float(np.quantile(r50, .025)), float(np.quantile(r50, .975))],
        "auc": float((1 - (r - 1) / (n_cand - 1)).mean()), "top10pct": float((r <= n_cand / 10).mean()),
        "random_recall@50": 50 / n_cand, "n_heldout": int(len(r)), "n_candidates": int(n_cand),
    }


def category_neighbors(corpus, models, k=10):
    """Label-free proxy on the pool: share of each paper's k nearest neighbours with the same primary category, and
    with at least one category in common."""
    pool = [i for i, p in enumerate(corpus) if p["in_pool"] and p["categories"]]
    prim = np.array([corpus[i]["categories"][0] for i in pool])
    cats = [set(corpus[i]["categories"]) for i in pool]
    out = {}
    for m in models:
        E = np.load(os.path.join(OUT, "emb", f"{m}.npy"))[pool]
        same, share = [], []
        for s in range(0, len(pool), 1024):
            S = E[s:s + 1024] @ E.T
            for j in range(S.shape[0]):
                S[j, s + j] = -2
            nn = np.argpartition(-S, k, axis=1)[:, :k]
            same.append((prim[nn] == prim[s:s + S.shape[0], None]).mean(1))
            share.append([np.mean([bool(cats[s + j] & cats[x]) for x in row]) for j, row in enumerate(nn)])
        out[m] = {"primary_match@10": float(np.concatenate(same).mean()),
                  "any_category_overlap@10": float(np.mean(np.concatenate(share)))}
        print(m, out[m])
    return out


def main():
    corpus = load_corpus()
    idx = {p["source_id"]: i for i, p in enumerate(corpus)}
    info = json.load(open(os.path.join(OUT, "models.json")))
    models = [m for m in info if "skipped" not in info[m]]
    results = {"protocol": {
        "profile": "remaining library papers, weight (archived?0.5:1)*(0.4+0.6*exp(-age/120d))",
        "candidates": "Feed pool minus all library papers, plus the held-out paper",
        "multi_centroid": "agglomerative (cosine, average linkage), k = round(sqrt(n/2)), max over weighted centroids",
        "rank": "1 + number of pool candidates scoring strictly higher than the held-out paper",
    }, "libraries": {}, "results": {}}
    for label in library_labels():
        lib = load_library(label)
        lib_ids = {r["source_id"] for r in lib}
        lib_idx = np.array([idx[r["source_id"]] for r in lib])
        weights = np.array([r["weight"] for r in lib])
        pool_idx = np.array([i for i, p in enumerate(corpus) if p["in_pool"] and p["source_id"] not in lib_ids])
        results["libraries"][label] = {"papers": len(lib), "also_in_pool": sum(corpus[i]["in_pool"] for i in lib_idx),
                                       "pool_candidates": len(pool_idx) + 1,
                                       "multi_centroid_k": n_clusters(len(lib) - 1)}
        for m in models:
            E = np.load(os.path.join(OUT, "emb", f"{m}.npy"))
            for name, r in evaluate(E, lib_idx, weights, pool_idx).items():
                results["results"].setdefault(label, {}).setdefault(m, {})[name] = {
                    **metrics(r, len(pool_idx) + 1), "ranks": r.tolist()}
            print(label, m, {k: round(v["recall@50"], 3) for k, v in results["results"][label][m].items()})
        # Paired bootstrap of AUC (mean percentile of the held-out paper) against gte-small, per scorer.
        res = results["results"][label]
        n_cand = len(pool_idx) + 1
        boot = RNG.integers(0, len(lib), size=(2000, len(lib)))
        for m in models:
            for s in res[m]:
                a = 1 - (np.array(res[m][s]["ranks"]) - 1) / (n_cand - 1)
                b = 1 - (np.array(res["gte-small"][s]["ranks"]) - 1) / (n_cand - 1)
                d = (a - b)[boot].mean(1)
                res[m][s]["auc_minus_gte_ci95"] = [float(np.quantile(d, .025)), float(np.quantile(d, .975))]
    results["category_neighbors"] = category_neighbors(corpus, models)
    json.dump(results, open(os.path.join(OUT, "eval1_ranking.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
