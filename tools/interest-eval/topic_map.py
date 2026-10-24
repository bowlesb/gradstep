"""Evaluation 2: a trial hierarchical topic map, the owner's lift-selected topics, and sample For-you sections.

Usage: topic_map.py [--model gte-small] [--library owner]
Writes OUT/topic_map.json, OUT/interest_<library>.json and OUT/topics_pie_<library>.png.
"""
import argparse
import json
import os
import re
from datetime import date

import numpy as np
from scipy import sparse
from sklearn.cluster import KMeans
from sklearn.feature_extraction.text import ENGLISH_STOP_WORDS, CountVectorizer

from common import OUT, load_corpus, load_library

TOP_K = 20          # level-1 nodes
MID_SIZE = 150      # target papers per level-2 node
LEAF_SIZE = 40      # target papers per leaf (level 3)
DOMAIN_STOP = set("""
paper papers propose proposed proposes approach approaches method methods result results show shows shown based using use
used novel framework frameworks existing achieve achieves achieved demonstrate demonstrates performance state art
new task tasks model models work works study studies also however furthermore address problem problems significantly
significant extensive experiments experimental code available github com https http introduce introduces present
presents first well across various wide range different large effectiveness effective improve improves improved
improvement improvements outperforms baseline baselines benchmark benchmarks including data dataset datasets
key challenge challenges recent despite remains remain often need needs enable enables enabling lead leads via
""".split())
STOP = list(ENGLISH_STOP_WORDS | DOMAIN_STOP)

# Topic selection (INTEREST_INDEX.md): go deeper when the child has >= 3 papers, >= 40% of the parent's user mass and
# more than 2x the parent's lift. A topic appears at 3 papers.
MIN_PAPERS, MIN_MASS_SHARE, LIFT_GAIN = 3, 0.40, 2.0


def spherical_kmeans(X, k, seed=0):
    k = max(1, min(k, len(X)))
    if k == 1:
        return np.zeros(len(X), dtype=int)
    return KMeans(n_clusters=k, n_init=4, random_state=seed).fit_predict(X)


def build_tree(E):
    """Nested k-means: TOP_K nodes, then ~MID_SIZE-paper children, then ~LEAF_SIZE-paper leaves."""
    nodes = []  # {id, level, parent, members}

    def add(level, parent, members):
        nodes.append({"id": len(nodes), "level": level, "parent": parent, "members": members, "children": []})
        if parent is not None:
            nodes[parent]["children"].append(len(nodes) - 1)
        return len(nodes) - 1

    root = add(0, None, np.arange(len(E)))
    for g in np.unique(lab := spherical_kmeans(E, TOP_K)):
        n1 = add(1, root, np.where(lab == g)[0])
        m1 = nodes[n1]["members"]
        lab2 = spherical_kmeans(E[m1], max(2, round(len(m1) / MID_SIZE)), seed=1)
        for g2 in np.unique(lab2):
            n2 = add(2, n1, m1[lab2 == g2])
            m2 = nodes[n2]["members"]
            lab3 = spherical_kmeans(E[m2], max(1, round(len(m2) / LEAF_SIZE)), seed=2)
            for g3 in np.unique(lab3):
                add(3, n2, m2[lab3 == g3])
    for n in nodes:
        c = E[n["members"]].mean(0)
        n["centroid"] = c / np.linalg.norm(c)
    return nodes


def label_nodes(nodes, corpus, E):
    """Class-based TF-IDF (1-3-grams, stopwords removed) per level, plus the 3 most central titles."""
    texts = [f"{p['title']}. {p['abstract']}" for p in corpus]
    cv = CountVectorizer(ngram_range=(1, 3), stop_words=STOP, min_df=3, max_df=0.15,
                         token_pattern=r"(?u)\b[a-zA-Z][a-zA-Z0-9\-]+\b")
    X = cv.fit_transform(texts)
    vocab = np.array(cv.get_feature_names_out())
    for level in (1, 2, 3):
        lv = [n for n in nodes if n["level"] == level]
        M = sparse.csr_matrix((np.ones(len(corpus)), (np.concatenate([n["members"] for n in lv]),
                               np.concatenate([[i] * len(n["members"]) for i, n in enumerate(lv)]))),
                              shape=(len(corpus), len(lv)))
        C = (M.T @ X).toarray().astype(float)                  # classes x terms
        tf = C / np.maximum(C.sum(1, keepdims=True), 1)
        A = C.sum(1).mean()
        idf = np.log(1 + A / np.maximum(C.sum(0), 1))
        W = tf * idf
        # Prefer terms spread across the node's papers over one paper repeating a phrase.
        doc_share = (M.T @ (X > 0).astype(float)).toarray() / np.array([len(n["members"]) for n in lv])[:, None]
        W *= np.sqrt(np.clip(doc_share, 0, 1))
        for i, n in enumerate(lv):
            terms = []
            for t in vocab[np.argsort(-W[i])[:40]]:
                if any(t in k or k in t for k in terms):
                    continue
                terms.append(t)
                if len(terms) == 6:
                    break
            n["terms"] = terms
            sims = E[n["members"]] @ n["centroid"]
            n["central"] = [corpus[n["members"][j]]["title"] for j in np.argsort(-sims)[:3]]
            n["label"] = " · ".join(terms[:3])


def interest_state(nodes, corpus, lib, lib_index):
    """Per node: user paper count, weighted mass, background share, lift (user share / background share)."""
    lib_rows = {lib_index[r["source_id"]]: r for r in lib}
    bg_total = len(corpus) - len(lib_rows)
    mass_total = sum(r["weight"] for r in lib)
    for n in nodes:
        mine = [m for m in n["members"] if m in lib_rows]
        n["user_rows"] = mine
        n["user_count"] = len(mine)
        n["user_mass"] = sum(lib_rows[m]["weight"] for m in mine)
        n["bg_count"] = len(n["members"]) - len(mine)
        n["user_share"] = n["user_mass"] / mass_total
        n["bg_share"] = n["bg_count"] / bg_total
        n["lift"] = n["user_share"] / n["bg_share"] if n["bg_count"] else float("inf")
    return mass_total


def select_topics(nodes, min_mass_share=MIN_MASS_SHARE, lift_gain=LIFT_GAIN):
    topics, other = [], []

    def visit(n, rows):
        kids = [nodes[c] for c in n["children"]]
        good = [c for c in kids if c["user_count"] >= MIN_PAPERS and c["user_mass"] >= min_mass_share * n["user_mass"]
                and c["lift"] > lift_gain * n["lift"]]
        if not good:
            topics.append((n, rows))
            return
        taken = set()
        for c in good:
            visit(c, list(c["user_rows"]))
            taken |= set(c["user_rows"])
        rest = [r for r in rows if r not in taken]
        if len(rest) >= MIN_PAPERS:
            topics.append((n, rest))
        else:
            other.extend(rest)

    for n in nodes:
        if n["level"] == 1 and n["user_count"]:
            if n["user_count"] >= MIN_PAPERS:
                visit(n, list(n["user_rows"]))
            else:
                other.extend(n["user_rows"])
    return topics, other


def sections(topics, corpus, E, lib_set, weights_by_row, top_n=5, window_days=14):
    """Multi-interest ranking of the last 14 days of the pool into per-topic sections (proposal weights; authors and
    dismissals unavailable offline). Each candidate joins the section whose papers it is closest to (kNN-3)."""
    dates = [date.fromisoformat(p["announced_on"]) for p in corpus if p["in_pool"]]
    newest = max(dates)
    cand = np.array([i for i, p in enumerate(corpus) if p["in_pool"] and i not in lib_set
                     and (newest - date.fromisoformat(p["announced_on"])).days < window_days])
    C = E[cand]
    knn, cen = [], []
    for _, rows in topics:
        U = E[rows]
        w = np.array([weights_by_row[r] for r in rows])
        S = C @ U.T
        knn.append(np.sort(S, 1)[:, -min(3, len(rows)):].mean(1))
        c = (w[:, None] * U).sum(0)
        cen.append(C @ (c / np.linalg.norm(c)))
    knn, cen = np.array(knn), np.array(cen)
    best = knn.argmax(0)

    def pct(x):
        return (np.argsort(np.argsort(x)) + 0.5) / len(x)

    age = np.array([(newest - date.fromisoformat(corpus[i]["announced_on"])).days for i in cand])
    fresh = 0.5 ** (age / 5)
    up = np.array([corpus[i]["upvotes"] or 0 for i in cand], dtype=float)
    pop = np.minimum(1, np.log1p(up) / np.log1p(50))
    out = []
    for t in range(len(topics)):
        score = 0.5 * pct(knn[t]) + 0.15 * pct(cen[t]) + 0.15 * fresh + 0.1 * pop
        pool = [j for j in np.argsort(-score) if best[j] == t][:50]
        picked = []
        while pool and len(picked) < top_n:  # MMR inside the section (lambda 0.8)
            def mmr(j):
                red = max((float(C[j] @ C[k]) for k in picked), default=0.0)
                return 0.8 * score[j] - 0.2 * red
            j = max(pool, key=mmr)
            picked.append(j)
            pool.remove(j)
        out.append([{"source_id": corpus[cand[j]]["source_id"], "title": corpus[cand[j]]["title"],
                     "announced_on": corpus[cand[j]]["announced_on"], "score": round(float(score[j]), 3),
                     "knn3_cos": round(float(knn[t, j]), 3), "centroid_cos": round(float(cen[t, j]), 3),
                     "freshness": round(float(fresh[j]), 2), "upvotes": int(up[j])} for j in picked])
    return out, {"window": f"{date.fromordinal(newest.toordinal() - window_days + 1)} .. {newest}",
                 "candidates": int(len(cand)), "assigned_per_section": [int((best == t).sum()) for t in range(len(topics))]}


def pie(topics_out, other_share, other_papers, path, title):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    palette = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"]
    rows = sorted(topics_out, key=lambda t: -t["share"])
    shown, rest = rows[:8], rows[8:]
    vals = [t["share"] for t in shown]
    labels = [t["label"] for t in shown]
    colors = palette[:len(shown)]
    rest_share = sum(t["share"] for t in rest) + other_share
    if rest_share > 0:
        vals.append(rest_share)
        parts = ([f"{len(rest)} smaller topic" + ("s" if len(rest) > 1 else "")] if rest else []) + \
            ([f"{other_papers} papers outside topics"] if other_papers else [])
        labels.append("Other: " + ", ".join(parts))
        colors.append("#a3a29b")
    fig, ax = plt.subplots(figsize=(9, 5), dpi=150)
    fig.patch.set_facecolor("#fcfcfb")
    wedges, _ = ax.pie(vals, colors=colors, startangle=90, counterclock=False,
                       wedgeprops={"width": 0.42, "edgecolor": "#fcfcfb", "linewidth": 2})
    ax.set_aspect("equal")
    ax.legend(wedges, [f"{v * 100:4.1f}%  {l}" for v, l in zip(vals, labels)], loc="center left",
              bbox_to_anchor=(1.0, 0.5), frameon=False, fontsize=9, labelcolor="#3d3d3a")
    fig.suptitle(title, x=0.02, ha="left", fontsize=12, color="#1f1f1d")
    fig.savefig(path, facecolor=fig.get_facecolor(), bbox_inches="tight", pad_inches=0.25)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="gte-small")
    ap.add_argument("--library", default="owner")
    args = ap.parse_args()

    corpus = load_corpus()
    E = np.load(os.path.join(OUT, "emb", f"{args.model}.npy"))
    index = {p["source_id"]: i for i, p in enumerate(corpus)}
    nodes = build_tree(E)
    label_nodes(nodes, corpus, E)
    lib = load_library(args.library)
    mass_total = interest_state(nodes, corpus, lib, index)
    weights_by_row = {index[r["source_id"]]: r["weight"] for r in lib}

    def path_of(n):
        out = []
        while n["parent"] is not None and n["level"] > 0:
            out.append(n["label"])
            n = nodes[n["parent"]]
        return " › ".join(reversed(out))

    def node_out(n, rows):
        m = sum(weights_by_row[r] for r in rows)
        return {"node": n["id"], "level": n["level"], "label": n["label"], "path": path_of(n), "terms": n["terms"],
                "central_titles": n["central"], "node_papers": len(n["members"]), "user_papers": len(rows),
                "user_mass": round(m, 3), "share": m / mass_total, "lift": round(n["lift"], 2),
                "residual": len(rows) < n["user_count"],
                "user_titles": [corpus[r]["title"] for r in rows]}

    def run(min_mass_share, lift_gain, with_sections):
        topics, other = select_topics(nodes, min_mass_share, lift_gain)
        topics = sorted(topics, key=lambda t: -sum(weights_by_row[r] for r in t[1]))
        out = [node_out(n, rows) for n, rows in topics]
        info = None
        if with_sections:
            sec, info = sections(topics, corpus, E, set(weights_by_row), weights_by_row)
            for t, s_ in zip(out, sec):
                t["for_you"] = s_
        return {"rules": {"min_papers": MIN_PAPERS, "min_mass_share": min_mass_share, "lift_gain": lift_gain},
                "topics": out, "other_share": sum(weights_by_row[r] for r in other) / mass_total,
                "other_titles": [corpus[r]["title"] for r in other], "sections": info}

    proposal = run(MIN_MASS_SHARE, LIFT_GAIN, True)
    relaxed = run(0.25, 1.5, True)
    generic_out = [node_out(n, n["user_rows"]) for n in
                   sorted((n for n in nodes if n["level"] == 1 and n["user_count"]), key=lambda n: -n["user_count"])]
    cats = {}
    for r in lib:
        if r["categories"]:
            cats[r["categories"][0]] = cats.get(r["categories"][0], 0) + r["weight"]
    categories_out = [{"category": c, "share": m / mass_total} for c, m in sorted(cats.items(), key=lambda kv: -kv[1])]
    niche = [node_out(n, n["user_rows"]) for n in
             sorted((n for n in nodes if n["level"] == 3 and n["user_count"] >= 2), key=lambda n: -n["lift"])]

    tree = [{"id": n["id"], "level": n["level"], "parent": n["parent"], "size": int(len(n["members"])),
             "label": n.get("label"), "terms": n.get("terms"), "central_titles": n.get("central")}
            for n in nodes if n["level"] > 0]
    leaf_sizes = [len(n["members"]) for n in nodes if n["level"] == 3]
    json.dump({"model": args.model, "papers": len(corpus), "levels": {
        str(l): sum(n["level"] == l for n in nodes) for l in (1, 2, 3)},
        "leaf_size": {"min": int(min(leaf_sizes)), "median": float(np.median(leaf_sizes)), "max": int(max(leaf_sizes))},
        "nodes": tree}, open(os.path.join(OUT, "topic_map.json"), "w"), indent=1)
    result = {"model": args.model, "library": args.library, "papers": len(lib), "total_mass": round(mass_total, 3),
              "proposal": proposal, "relaxed": relaxed, "generic_top_level": generic_out,
              "generic_primary_categories": categories_out, "niche_leaves_2plus": niche}
    json.dump(result, open(os.path.join(OUT, f"interest_{args.library}.json"), "w"), indent=1)
    for name, sel in (("proposal", proposal), ("relaxed", relaxed)):
        pie(sel["topics"], sel["other_share"], len(sel["other_titles"]), os.path.join(OUT, f"topics_pie_{args.library}_{name}.png"),
            f"Library topics, {name} rule ({len(lib)} papers, trial map, {args.model})")
        print(f"== {name} {sel['rules']}")
        for t in sel["topics"]:
            print(f"{t['share'] * 100:5.1f}%  n={t['user_papers']:2d} lift={t['lift']:6.1f} L{t['level']} {t['label']}")
        print(f"other {sel['other_share'] * 100:.1f}%")
    print(f"leaves {len(leaf_sizes)}, sizes {min(leaf_sizes)}-{max(leaf_sizes)}")

if __name__ == "__main__":
    main()
