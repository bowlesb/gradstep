"""Step 2: a specificity-first topic rule, a TF-IDF / log-odds term layer, "Other" folding and a replay over time.

Usage: topic_rule2.py [--model gte-small] [--library owner]
Writes OUT/interest_<library>_v2.json, OUT/topics_pie_<library>_v2.png and OUT/step2_tables.md.
"""
import argparse
import json
import os

import numpy as np

from common import OUT, load_corpus, load_library
from terms import Terms
from topic_map import build_tree, interest_state, label_nodes, pie

MIN_PAPERS = 3        # a topic appears at 3 papers
EMERGING_PAPERS = 2   # 2 papers in a small, high-lift leaf: shown as "emerging", not a slice
EMERGING_LIFT = 8.0
FOLD_COS = 0.86       # gte-small: an outside paper joins a topic when its nearest topic paper is at least this close


# ---------- topic rule v2 ----------

def select_specific(nodes, weights_by_row, E):
    """Deepest-first: a node becomes a topic when >= MIN_PAPERS of the user's papers in it are not already claimed
    by a deeper topic. Unclaimed papers rise to the parent; a top-level node keeps its rest as a broad topic when
    >= MIN_PAPERS remain. So the narrowest grouping the library supports wins ("KV-cache compression" over
    "tokens · decoding · inference"), and broad topics hold only what no narrower topic explains."""
    claimed, topics = set(), []
    for level in (3, 2, 1):
        for n in sorted((n for n in nodes if n["level"] == level), key=lambda n: -n["lift"]):
            free = [r for r in n["user_rows"] if r not in claimed]
            if len(free) >= MIN_PAPERS:
                topics.append({"node": n, "rows": free, "residual": len(free) < n["user_count"]})
                claimed |= set(free)
    rest = [r for r in weights_by_row if r not in claimed]
    # Fold: an outside paper joins the topic holding its nearest paper, when close enough.
    folded, other = [], []
    for r in rest:
        best, best_cos = None, -1.0
        for t in topics:
            c = float(np.max(E[t["rows"]] @ E[r]))
            if c > best_cos:
                best, best_cos = t, c
        if best is not None and best_cos >= FOLD_COS:
            best.setdefault("folded", []).append(r)
            folded.append((r, best_cos))
        else:
            other.append(r)
    emerging = [n for n in nodes if n["level"] == 3 and n["lift"] >= EMERGING_LIFT
                and len([r for r in n["user_rows"] if r in other or r in dict(folded)]) >= EMERGING_PAPERS]
    return topics, other, emerging


def other_groups(nodes, other):
    """Group what is left by top-level node, so the grey slice says what it is ("robots · control (3)")."""
    groups = {}
    for n in nodes:
        if n["level"] == 1:
            mine = [r for r in n["user_rows"] if r in other]
            if mine:
                groups[n["label"]] = mine
    return sorted(groups.items(), key=lambda kv: -len(kv[1]))


def run(corpus, E, nodes, lib, index, mass_total):
    weights_by_row = {index[r["source_id"]]: r["weight"] for r in lib}
    interest_state(nodes, corpus, lib, index)
    topics, other, emerging = select_specific(nodes, weights_by_row, E)
    total = sum(weights_by_row.values())
    out = []
    for t in topics:
        rows = t["rows"] + t.get("folded", [])
        n = t["node"]
        out.append({"node": n["id"], "level": n["level"], "label": n["label"], "terms": n["terms"],
                    "residual": t["residual"], "user_papers": len(rows), "folded": len(t.get("folded", [])),
                    "share": sum(weights_by_row[r] for r in rows) / total, "lift": round(n["lift"], 1),
                    "node_papers": int(len(n["members"])), "rows": rows,
                    "user_titles": [corpus[r]["title"] for r in rows]})
    out.sort(key=lambda t: -t["share"])
    return {"topics": out, "other": other, "other_share": sum(weights_by_row[r] for r in other) / total,
            "other_groups": [(g, len(rs)) for g, rs in other_groups(nodes, other)],
            "emerging": [{"label": n["label"], "terms": n["terms"], "lift": round(n["lift"], 1),
                          "user_papers": n["user_count"], "node_papers": int(len(n["members"]))} for n in emerging]}


def topic_terms(terms, topic_rows, weights_by_row, k=3):
    """Name a user's topic by what its papers share against the whole corpus, not by the node's label."""
    return terms.topic_terms(topic_rows, [weights_by_row[r] for r in topic_rows], k=k)


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
    weights_by_row = {index[r["source_id"]]: r["weight"] for r in lib}
    mass_total = sum(weights_by_row.values())
    terms = Terms(corpus, E)
    lines = [f"# Step 2 tables ({args.library}, {len(lib)} papers, {args.model})", ""]

    # Topics, v2 rule
    res = run(corpus, E, nodes, lib, index, mass_total)
    for t in res["topics"]:
        t["own_terms"] = topic_terms(terms, t["rows"], weights_by_row)
    lines += ["## Topics, specificity-first rule", "",
              "| # | Share | Papers (folded) | Lift | Level | Map label | Terms its papers share (log-odds) |",
              "|---|---|---|---|---|---|---|"]
    for i, t in enumerate(res["topics"], 1):
        lvl = f"L{t['level']}" + (" rest" if t["residual"] else "")
        lines.append(f"| {i} | {t['share'] * 100:.1f}% | {t['user_papers']} ({t['folded']}) | {t['lift']} | {lvl} | "
                     f"{t['label']} | {', '.join(t['own_terms'])} |")
    lines.append(f"| | {res['other_share'] * 100:.1f}% | {len(res['other'])} | | | Other: "
                 + "; ".join(f"{g} ({n})" for g, n in res["other_groups"]) + " | |")
    lines += ["", "Emerging (2 papers in a small leaf, lift ≥ 8; listed, not a slice):", ""]
    lines += [f"- {e['label']} — {e['user_papers']} of {e['node_papers']} papers, lift {e['lift']}" for e in res["emerging"]]
    lines += ["", "Papers per topic:", ""]
    for i, t in enumerate(res["topics"], 1):
        lines.append(f"- **{i}. {', '.join(t['own_terms'][:3])}**: " + "; ".join(x[:70] for x in t["user_titles"]))
    lines.append("- **Other**: " + "; ".join(corpus[r]["title"][:70] for r in res["other"]))

    # Library term profile
    prof = terms.library_terms(list(weights_by_row), list(weights_by_row.values()), k=30)
    lines += ["", "## Library keywords: weighted log-odds against the corpus (min 2 papers)", "",
              "| Term | z | Library papers | Other papers | Lift |", "|---|---|---|---|---|"]
    lines += [f"| {t['term']} | {t['z']} | {t['user_papers']} | {t['background_papers']} | {t['lift']} |" for t in prof]

    # Per-paper TF-IDF terms
    pt = {r: terms.paper_terms(r) for r in weights_by_row}
    lines += ["", "## Per-paper distinctive terms (TF-IDF, IDF from the corpus)", "", "| Paper | Terms |", "|---|---|"]
    lines += [f"| {corpus[r]['title'][:80]} | {', '.join(pt[r])} |" for r in list(weights_by_row)]

    # Replay: the library as it grew (add order)
    lines += ["", "## Replay: topics as the library grew (add order)", ""]
    replay = []
    for n_papers in (15, 30, 45, len(lib)):
        sub = lib[:n_papers]
        s = run(corpus, E, nodes, sub, index, None)
        wb = {index[r["source_id"]]: r["weight"] for r in sub}
        names = [", ".join(topic_terms(terms, t["rows"], wb, k=2)) + f" ({t['user_papers']})" for t in s["topics"]]
        replay.append({"papers": n_papers, "topics": names, "other": len(s["other"])})
        lines.append(f"- **{n_papers} papers** ({sub[-1]['added_at'][:10]}): " + "; ".join(names)
                     + f"; Other {len(s['other'])}")
    interest_state(nodes, corpus, lib, index)  # restore full-library state

    for t in res["topics"]:
        t["label"] = ", ".join(t["own_terms"][:3])
        del t["rows"]
    pie(res["topics"], res["other_share"], len(res["other"]), os.path.join(OUT, f"topics_pie_{args.library}_v2.png"),
        f"Library topics, specificity-first rule ({len(lib)} papers, {args.model})")
    json.dump({"rule": {"min_papers": MIN_PAPERS, "fold_cos": FOLD_COS, "emerging": [EMERGING_PAPERS, EMERGING_LIFT]},
               "topics": res["topics"], "other_share": res["other_share"], "other_groups": res["other_groups"],
               "emerging": res["emerging"], "keywords": prof,
               "paper_terms": {corpus[r]["source_id"]: pt[r] for r in pt}, "replay": replay},
              open(os.path.join(OUT, f"interest_{args.library}_v2.json"), "w"), indent=1)
    open(os.path.join(OUT, "step2_tables.md"), "w").write("\n".join(lines) + "\n")
    terms.save()
    print("\n".join(lines))


if __name__ == "__main__":
    main()
