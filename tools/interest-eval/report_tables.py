"""Render the evaluation JSON outputs as Markdown tables (OUT/report_tables.md) for REPORT.md."""
import json
import os

from common import OUT


def pct(x):
    return f"{x * 100:.1f}%"


def eval1(lines):
    r = json.load(open(os.path.join(OUT, "eval1_ranking.json")))
    models = json.load(open(os.path.join(OUT, "models.json")))
    lines.append("## Models\n")
    lines.append("| Model | Dim | Max tokens | Disk (HF cache) | Encode (papers/s, MPS) | Status |")
    lines.append("|---|---|---|---|---|---|")
    for m, i in models.items():
        if "skipped" in i:
            lines.append(f"| {m} | | | | | skipped: {i['skipped']} |")
        else:
            lines.append(f"| {m} | {i['dim']} | {i['max_tokens']} | {i['disk_mb']} MB | {i['papers_per_second']} "
                         f"({i['encode_seconds']} s for {i['papers']}) | ok |")
    for label, res in r["results"].items():
        lib = r["libraries"][label]
        lines.append(f"\n## Leave-one-out ranking: {label} ({lib['papers']} papers, {lib['pool_candidates']} candidates, "
                     f"multi-centroid k={lib['multi_centroid_k']})\n")
        lines.append("| Model | Scorer | R@10 | R@50 | R@50 95% CI | R@100 | MRR | Median rank | Top 10% | AUC | AUC − gte-small (95% CI) |")
        lines.append("|---|---|---|---|---|---|---|---|---|---|---|")
        for m, scorers in res.items():
            for s, v in scorers.items():
                ci = v["recall@50_ci95"]
                lines.append(f"| {m} | {s} | {pct(v['recall@10'])} | {pct(v['recall@50'])} | {pct(ci[0])}–{pct(ci[1])} "
                             f"| {pct(v['recall@100'])} | {v['mrr']:.3f} | {v['median_rank']:.0f} | {pct(v['top10pct'])} "
                             f"| {v['auc']:.3f} | " + ("reference" if m == "gte-small" else
                                f"{v['auc_minus_gte_ci95'][0]:+.3f} to {v['auc_minus_gte_ci95'][1]:+.3f}") + " |")
        any_v = next(iter(next(iter(res.values())).values()))
        lines.append(f"\nRandom ranking: R@50 = {pct(any_v['random_recall@50'])}, median rank ≈ {any_v['n_candidates'] // 2}.")


def by_topic_support(lines, model="gte-small", scorer="knn3"):
    """Held-out owner papers split by whether their (proposal-rule) topic keeps >= 3 other papers."""
    from common import load_library
    import numpy as np
    r = json.load(open(os.path.join(OUT, "eval1_ranking.json")))
    path = os.path.join(OUT, "interest_owner.json")
    if not os.path.exists(path):
        return
    topics = json.load(open(path))["proposal"]["topics"]
    size = {t: len(x["user_titles"]) for x in topics for t in x["user_titles"]}
    lib = load_library("owner")
    n_cand = r["libraries"]["owner"]["pool_candidates"]
    lines.append(f"\n### Owner hold-outs by topic support ({model}, {scorer})\n")
    lines.append("| Hold-out group | Papers | R@100 | Top 10% | AUC | Median rank |")
    lines.append("|---|---|---|---|---|---|")
    for sc in (scorer, "multi-centroid", "mean"):
        ranks = np.array(r["results"]["owner"][model][sc]["ranks"])
        sup = np.array([size.get(p["title"], 0) >= 4 for p in lib])
        for name, mask in ((f"{sc}: in a topic with ≥ 3 other papers", sup), (f"{sc}: in a small topic or Other", ~sup)):
            rr = ranks[mask]
            lines.append(f"| {name} | {len(rr)} | {pct((rr <= 100).mean())} | {pct((rr <= n_cand / 10).mean())} | "
                         f"{(1 - (rr - 1) / (n_cand - 1)).mean():.3f} | {np.median(rr):.0f} |")


def proxy(lines):
    r = json.load(open(os.path.join(OUT, "eval1_ranking.json")))
    lines.append("\n## Label-free proxy: arXiv categories of the 10 nearest pool neighbours\n")
    lines.append("| Model | Same primary category | Any category in common |")
    lines.append("|---|---|---|")
    for m, v in r["category_neighbors"].items():
        lines.append(f"| {m} | {pct(v['primary_match@10'])} | {pct(v['any_category_overlap@10'])} |")


def eval2(lines, label="owner"):
    path = os.path.join(OUT, f"interest_{label}.json")
    if not os.path.exists(path):
        return
    d = json.load(open(path))
    tm = json.load(open(os.path.join(OUT, "topic_map.json")))
    lines.append(f"\n## Topic map ({d['model']}): {tm['papers']} papers; level sizes {tm['levels']}; "
                 f"leaf size min/median/max {tm['leaf_size']['min']}/{tm['leaf_size']['median']:.0f}/{tm['leaf_size']['max']}\n")
    for name in ("proposal", "relaxed"):
        sel = d[name]
        lines.append(f"\n### Owner topics, {name} rule {sel['rules']}\n")
        lines.append("| # | Share | Papers | Lift | Level | Label (c-TF-IDF terms) | Central titles |")
        lines.append("|---|---|---|---|---|---|---|")
        for i, t in enumerate(sel["topics"], 1):
            lines.append(f"| {i} | {pct(t['share'])} | {t['user_papers']} | {t['lift']:.1f} | L{t['level']}"
                         f"{' (rest)' if t['residual'] else ''} | {', '.join(t['terms'])} | "
                         + "<br>".join(x[:90] for x in t["central_titles"]) + " |")
        lines.append(f"| | {pct(sel['other_share'])} | {len(sel['other_titles'])} | | | Other (papers in topics with < 3 papers) | |")
        if name == "proposal":
            lines.append("\nOwner papers per topic:\n")
            for i, t in enumerate(sel["topics"], 1):
                lines.append(f"- **{i}. {t['label']}**: " + "; ".join(x[:70] for x in t["user_titles"]))
            lines.append("- **Other**: " + "; ".join(x[:70] for x in sel["other_titles"]))
    lines.append("\n### Generic alternative A: top-level map nodes by raw count\n")
    lines.append("| Papers | Share | Lift | Label |")
    lines.append("|---|---|---|---|")
    for t in d["generic_top_level"]:
        lines.append(f"| {t['user_papers']} | {pct(t['share'])} | {t['lift']:.1f} | {t['label']} |")
    lines.append("\n### Generic alternative B: arXiv primary category by weighted count\n")
    lines.append(", ".join(f"{c['category']} {pct(c['share'])}" for c in d["generic_primary_categories"]))
    lines.append("\n### Niche leaves holding ≥ 2 owner papers (what appears as the library grows)\n")
    lines.append("| Papers | Lift | Leaf size | Label | Owner titles |")
    lines.append("|---|---|---|---|---|")
    for t in d["niche_leaves_2plus"]:
        lines.append(f"| {t['user_papers']} | {t['lift']:.1f} | {t['node_papers']} | {', '.join(t['terms'][:4])} | "
                     + "<br>".join(x[:80] for x in t["user_titles"]) + " |")
    for name in ("proposal",):
        sel = d[name]
        info = sel["sections"]
        lines.append(f"\n### Sample For-you sections ({name} topics; window {info['window']}, {info['candidates']} candidates)\n")
        for i, t in enumerate(sel["topics"], 1):
            lines.append(f"\n**{i}. {t['label']}** ({pct(t['share'])}; {info['assigned_per_section'][i - 1]} candidates assigned)\n")
            lines.append("| Score | kNN-3 cos | Centroid cos | Fresh | Upvotes | Announced | Title |")
            lines.append("|---|---|---|---|---|---|---|")
            for p in t["for_you"]:
                lines.append(f"| {p['score']:.3f} | {p['knn3_cos']:.3f} | {p['centroid_cos']:.3f} | {p['freshness']:.2f} "
                             f"| {p['upvotes']} | {p['announced_on']} | {p['title'][:100]} |")


if __name__ == "__main__":
    lines = []
    eval1(lines)
    by_topic_support(lines)
    proxy(lines)
    eval2(lines)
    open(os.path.join(OUT, "report_tables.md"), "w").write("\n".join(lines) + "\n")
    print(os.path.join(OUT, "report_tables.md"))
