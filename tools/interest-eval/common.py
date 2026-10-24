"""Shared data loading for the interest-index evaluation."""
import json
import math
import os
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))


def _default_out():
    # The main checkout's .artifacts (also when run from a git worktree).
    import subprocess
    try:
        common = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], cwd=HERE,
                                check=True, capture_output=True, text=True).stdout.strip()
        root = os.path.dirname(common)
    except Exception:
        root = os.path.join(HERE, "../..")
    return os.path.join(root, ".artifacts", "interest-eval")


OUT = os.path.abspath(os.environ.get("INTEREST_EVAL_OUT") or _default_out())


def _clean(s):
    return " ".join((s or "").split())


def load_corpus():
    """Feed pool plus every library paper, one row per source_id, in a stable order (cached as corpus.json)."""
    path = os.path.join(OUT, "corpus.json")
    if os.path.exists(path):
        return json.load(open(path))
    pool = json.load(open(os.path.join(OUT, "pool.json")))
    libs = json.load(open(os.path.join(OUT, "libraries.json")))
    rows, seen = [], {}
    for p in sorted(pool, key=lambda p: p["source_id"]):
        seen[p["source_id"]] = len(rows)
        rows.append({"source_id": p["source_id"], "title": _clean(p["title"]), "abstract": _clean(p["abstract"]),
                     "categories": p["categories"], "announced_on": p["announced_on"], "upvotes": p["upvotes"],
                     "in_pool": True})
    for items in libs.values():
        for r in items:
            if r["source_id"] in seen or not r.get("abstract"):
                continue
            seen[r["source_id"]] = len(rows)
            rows.append({"source_id": r["source_id"], "title": _clean(r["title"]), "abstract": _clean(r["abstract"]),
                         "categories": r["categories"], "announced_on": None, "upvotes": 0, "in_pool": False})
    json.dump(rows, open(path, "w"))
    return rows


def recency_weight(added_at: str, archived: bool, now: datetime) -> float:
    """PERSONALIZED_FEED.md: w = (archived ? 0.5 : 1) * (0.4 + 0.6 * e^(-age / 120 d))."""
    t = datetime.fromisoformat(added_at.replace("Z", "+00:00")) if added_at else now
    age_days = max(0.0, (now - t).total_seconds() / 86400)
    return (0.5 if archived else 1.0) * (0.4 + 0.6 * math.exp(-age_days / 120))


def load_library(label="owner"):
    """Library papers with an abstract, de-duplicated by source_id (earliest add kept), with recency weights."""
    libs = json.load(open(os.path.join(OUT, "libraries.json")))
    items = sorted(libs[label], key=lambda r: r["added_at"] or "")
    now = max([datetime.now(timezone.utc)] + [datetime.fromisoformat(r["added_at"]) for r in items if r["added_at"]])
    out, seen = [], set()
    for r in items:
        if r["source_id"] in seen or not r.get("abstract"):
            continue
        seen.add(r["source_id"])
        out.append({**r, "weight": recency_weight(r["added_at"], bool(r["archived"]), now)})
    return out


def library_labels():
    return list(json.load(open(os.path.join(OUT, "libraries.json"))))
