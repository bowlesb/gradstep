"""Step 3: fixtures for the device layer (ScienceReaderCore/Interest) and a reference of its rules.

Writes into apps/apple/ScienceReaderCore/Tests/ScienceReaderCoreTests/Fixtures/:
  interest-step2-topics.json   step 2's topic rule on the owner's library (topic_rule2.py, offline trial map), anonymised:
                               paper keys are p00…, no titles or text; the expected topics are step 2's own output.
  interest-library-v1.json     a public fixture library (38 Feed-pool papers, public metadata) on the published staging
                               map (version 1), with the expected topics, labels and keywords from this file's reference
                               of the device rules (the Swift port must match it exactly).
  interest-terms-fixture.gsi   the staging term statistics trimmed to the phrases the fixture papers use (same format,
                               same header totals), so the Swift decoder and tokenizer run on server-shaped bytes.
  interest-map-v1.gsi          the published map artifact itself (byte-identical to what devices download).
Inputs: OUT/corpus.json, OUT/emb/gte-small.npy, OUT/libraries.json (fetch_data.py, embed.py) and OUT/device/
(fetch_device_inputs.py --pool-ids …). Usage: device_fixtures.py [--skip-step2]
"""
import argparse
import base64
import gzip
import json
import math
import os
import shutil
import struct
import subprocess
from datetime import datetime, timezone

import numpy as np
from sklearn.feature_extraction.text import CountVectorizer

from common import OUT, load_corpus, load_library

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=HERE, check=True, capture_output=True, text=True).stdout.strip()
FIX = os.path.join(ROOT, "apps/apple/ScienceReaderCore/Tests/ScienceReaderCoreTests/Fixtures")
DEVICE = os.path.join(OUT, "device")
TOKEN = r"(?u)\b[a-zA-Z][a-zA-Z0-9\-]+\b"
NOW = datetime(2026, 10, 25, tzinfo=timezone.utc)

AREAS = ["machine learning", "natural language processing", "computer vision", "speech and audio", "robotics",
         "reinforcement learning", "information retrieval", "recommender systems", "multimodal learning", "graph learning",
         "time series", "ai safety", "ai for science", "healthcare and medicine", "learning theory", "optimization",
         "ml systems", "security", "ai and society", "human-ai interaction", "artificial intelligence",
         "multi-agent systems", "evolutionary computation"]
TAG_GENERIC = ["llm", "llms", "large language model", "large language models", "language model", "language models",
               "foundation model", "foundation models", "vlm", "vlms", "mllm", "mllms", "reasoning", "evaluation", "benchmark",
               "benchmarks", "deep learning", "neural network", "neural networks", "transformer", "transformers", "generative ai"]
RELATED_GENERIC = ["large language models", "reasoning", "evaluation", "ai agents", "fine-tuning", "vision-language models",
                   "transformers"]
EXTRA_GENERIC = ["artificial intelligence", "ai", "ml", "neural", "deep neural networks", "large language", "language llms",
                 "attention", "regression", "learning", "training", "inference", "algorithm", "algorithms", "network",
                 "networks", "statistics", "classification", "prediction", "accuracy", "generalization", "representation",
                 "representations", "llm-based", "ai systems"]
GENERIC = sorted(set(AREAS) | set(TAG_GENERIC) | set(RELATED_GENERIC) | set(EXTRA_GENERIC))
WEIGHT_SCALE, VECTOR_SCALE = 4096, 32768


def half_away(x):
    return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))


# ---------- artifacts ----------

def unpack(data):
    raw = gzip.decompress(data)
    assert raw[:4] == b"GSI1"
    n = struct.unpack("<I", raw[4:8])[0]
    return json.loads(raw[8:8 + n]), raw[8 + n:]


def pack(header, body):
    h = json.dumps(header, separators=(",", ":")).encode()
    return gzip.compress(b"GSI1" + struct.pack("<I", len(h)) + h + body, mtime=0)


def read_terms(body):
    out, at, prev = [], 0, b""
    while at < len(body):
        shared = body[at]; at += 1
        end = body.index(0, at)
        phrase = prev[:shared] + body[at:end]; at = end + 1
        df, mul = 0, 1
        while True:
            b = body[at]; at += 1
            df += (b & 0x7F) * mul; mul *= 128
            if not b & 0x80:
                break
        c = struct.unpack("b", body[at:at + 1])[0]; at += 1
        out.append((phrase.decode(), df, c))
        prev = phrase
    return out


def terms_body(entries):
    out, prev = bytearray(), b""
    for phrase, df, c in sorted(entries, key=lambda e: e[0].encode()):
        b = phrase.encode()
        p = 0
        while p < 255 and p < len(b) and p < len(prev) and b[p] == prev[p]:
            p += 1
        out.append(p); out += b[p:]; out.append(0)
        n = df
        while True:
            x = n & 0x7F; n >>= 7
            out.append(x | (0x80 if n else 0))
            if not n:
                break
        out += struct.pack("b", c)
        prev = b
    return bytes(out)


def q8_unit(b):
    """InterestQ8.decode: float32 products, a sequential float32 norm, float32 scaling."""
    scale = np.frombuffer(b[:4], "<f4")[0]
    v = (np.frombuffer(b[4:388], np.int8).astype(np.float32) * np.float32(scale)).astype(np.float32)
    norm = np.float32(0)
    for x in v:
        norm = np.float32(norm + np.float32(x * x))
    if norm > 0:
        v = (v * (np.float32(1) / np.sqrt(norm))).astype(np.float32)
    return v


# ---------- the device rules (reference for the Swift port) ----------

def analyzer(stop):
    return CountVectorizer(ngram_range=(1, 3), stop_words=sorted(stop), token_pattern=TOKEN, lowercase=True).build_analyzer()


def doc_text(title, abstract):
    return f"{title}. {title}. {abstract}"


class Terms:
    def __init__(self, header, entries):
        self.n = header["corpus_papers"]; self.total_df = header["total_df"]; self.concept_min = header.get("concept_min", 0.02)
        self.stop = set(header["stop_words"])
        self.df = {p: df for p, df, _ in entries}; self.concept = {p: c / 1000 for p, _, c in entries}
        self.analyze = analyzer(self.stop)

    def counts(self, text):
        out = {}
        for g in self.analyze(text):
            if g in self.df:
                out[g] = out.get(g, 0) + 1
        return out

    def idf(self, t):
        return math.log((1 + self.n) / (1 + self.df[t])) + 1

    def is_concept(self, t):
        return self.concept[t] >= self.concept_min - 1e-9


def weight(added_days_ago, archived=False, own_tags=False, reading=0, snippets=0, chats=0):
    """InterestWeights.weight with ages in whole UTC days."""
    w = (0.5 if archived else 1.0) * (0.4 + 0.6 * math.exp(-added_days_ago / 120.0))
    if own_tags:
        w *= 1.5
    return w * (1 + 0.0625 * max(0, min(4, reading)) + (0.25 if snippets > 0 else 0) + (0.25 if chats > 0 else 0))


class State:
    def __init__(self, nodes, background_total):
        self.nodes = nodes; self.bg = background_total
        self.parent = {n["id"]: n.get("parent") for n in nodes}
        self.size = {n["id"]: n["size"] for n in nodes}
        self.papers = {}  # key -> (units, quantized, vector, path)
        self.members = {}

    def path(self, leaf):
        out, c = [], leaf
        while c is not None:
            out.append(c); c = self.parent[c]
        return out

    def add(self, key, vector, leaf, w):
        units = half_away(w * WEIGHT_SCALE)
        q = [half_away(float(x) * VECTOR_SCALE) for x in vector]
        path = self.path(leaf)
        self.papers[key] = (units, q, vector, path)
        for n in path:
            self.members.setdefault(n, set()).add(key)

    @property
    def total(self):
        return sum(p[0] for p in self.papers.values())

    def mass(self, n):
        return sum(self.papers[k][0] for k in self.members.get(n, ()))

    def lift(self, n):
        t = self.total
        if not self.members.get(n) or t == 0:
            return 0.0
        if self.size[n] <= 0 or self.bg <= 0:
            return math.inf
        return (self.mass(n) / t) / (self.size[n] / self.bg)

    def cosine(self, a, b):
        x, y = self.papers[a][2], self.papers[b][2]
        s = 0.0
        for i in range(len(x)):
            s += float(x[i]) * float(y[i])
        return s

    def centroid(self, keys):
        sums = [0] * 384
        for k in sorted(keys):
            if k not in self.papers:
                continue
            units, q = self.papers[k][0], self.papers[k][1]
            for i in range(384):
                sums[i] += units * q[i]
        norm = 0.0
        for s in sums:
            norm += float(s) * float(s)
        norm = math.sqrt(norm)
        if norm == 0:
            return None
        return np.array([float(s) / norm for s in sums], dtype=np.float32)


def dot(x, y):
    s = 0.0
    for i in range(len(x)):
        s += float(x[i]) * float(y[i])
    return s


def select(state, established=frozenset(), appear=3, keep=2, fold_cos=0.86, emerging_papers=2, emerging_lift=8.0):
    claimed, chosen = set(), []
    for level in (3, 2, 1):
        nodes = [(n, state.lift(n["id"])) for n in state.nodes if n["level"] == level and state.members.get(n["id"])]
        nodes.sort(key=lambda x: (-x[1], x[0]["id"]))
        for n, lift in nodes:
            mine = state.members[n["id"]]
            free = sorted(k for k in mine if k not in claimed)
            if len(free) >= (keep if n["id"] in established else appear):
                chosen.append((n, free, len(free) < len(mine), lift))
                claimed |= set(free)
    folded, other = {}, []
    for key in sorted(state.papers):
        if key in claimed:
            continue
        best, best_cos = None, -math.inf
        for i, (_, papers, _, _) in enumerate(chosen):
            c = max(state.cosine(key, p) for p in papers)
            if c > best_cos:
                best, best_cos = i, c
        if best is not None and best_cos >= fold_cos:
            folded.setdefault(best, []).append(key)
        else:
            other.append(key)
    total = state.total

    def share(keys):
        return sum(state.papers[k][0] for k in keys) / total if total else 0

    topics = []
    for i, (n, papers, residual, lift) in enumerate(chosen):
        ps = sorted(papers + folded.get(i, []))
        topics.append({"id": n["id"], "level": n["level"], "papers": ps, "folded": len(folded.get(i, [])), "share": share(ps),
                       "lift": lift, "residual": residual})
    topics.sort(key=lambda t: (-t["share"], t["id"]))
    outside = set(other) | {k for v in folded.values() for k in v}
    emerging = []
    for n in state.nodes:
        if n["level"] != 3:
            continue
        lift = state.lift(n["id"])
        ps = sorted(k for k in state.members.get(n["id"], ()) if k in outside)
        if lift >= emerging_lift and len(ps) >= emerging_papers:
            emerging.append({"node": n["id"], "papers": ps})
    groups = []
    for n in state.nodes:
        if n["level"] == 1:
            ps = sorted(k for k in state.members.get(n["id"], ()) if k in set(other))
            if ps:
                groups.append({"node": n["id"], "papers": ps})
    groups.sort(key=lambda g: (-len(g["papers"]), g["node"]))
    return {"topics": topics, "other": sorted(other), "other_share": share(other), "other_groups": groups, "emerging": emerging}


class TextIndex:
    def __init__(self):
        self.by_paper, self.by_phrase = {}, {}

    def set(self, key, phrases):
        self.by_paper[key] = set(phrases)
        for t in phrases:
            self.by_phrase.setdefault(t, set()).add(key)

    def context(self, t, state):
        ps = self.by_phrase.get(t)
        return state.centroid(ps) if ps else None


ENDORSED_BONUS = 1.0  # a phrase the server's KeyBERT terms (real phrase embeddings) chose for one of the papers


def pick(order, terms, k, exclude=frozenset()):
    picked = []
    for t in order[:200]:
        if not terms.is_concept(t) or t in GENERIC or t in exclude:
            continue
        words = {w for w in t.split(" ") if len(w) >= 4}
        if any(p in t or t in p or words & set(p.split(" ")) for p in picked):
            continue
        picked.append(t)
        if len(picked) == k:
            break
    return picked


def topic_terms(papers, state, text, terms, k=3, endorsed=frozenset(), exclude=frozenset()):
    keys = sorted(p for p in papers if p in text.by_paper and p in state.papers)
    if not keys:
        return []
    yu, cnt, nu, used = {}, {}, 0.0, 0
    for key in keys:
        w = state.papers[key][0] / WEIGHT_SCALE
        phrases = text.by_paper[key]
        nu += w * len(phrases); used += len(phrases)
        for t in phrases:
            yu[t] = yu.get(t, 0.0) + w; cnt[t] = cnt.get(t, 0) + 1
    nb = float(max(0, terms.total_df - used))
    a0 = 1000.0

    def z(t):
        u, b = yu.get(t, 0.0), float(max(0, terms.df[t] - cnt.get(t, 0)))
        a = a0 * (u + b) / max(nu + nb, 1e-9)
        delta = math.log((u + a) / (nu + a0 - u - a)) - math.log((b + a) / (nb + a0 - b - a))
        return delta / math.sqrt(1 / (u + a) + 1 / (b + a))

    need = 2 if len(keys) <= 4 else max(2, round(0.4 * len(keys)))
    cands = [t for t, c in cnt.items() if c >= need] or list(cnt)
    scored = sorted(((t, z(t)) for t in cands), key=lambda x: (-x[1], x[0]))[:60]
    centre = state.centroid(keys)
    close = []
    for t, _ in scored:
        ctx = text.context(t, state)
        close.append(dot(ctx, centre) if ctx is not None else 0.0)
    mean = sum(close) / max(1, len(close))
    top = max(scored[0][1] if scored else 0, 1e-6)
    order = sorted(((t, s / top + 2 * (c - mean) + (ENDORSED_BONUS if t in endorsed else 0)) for (t, s), c in zip(scored, close)),
                   key=lambda x: (-x[1], x[0]))
    return pick([t for t, _ in order], terms, k, exclude)


def paper_terms(key, counts, state, text, terms, k=5, endorsed=frozenset()):
    if not counts:
        return []
    scored = sorted(((t, (1 + math.log(c)) * terms.idf(t) * (1.25 if " " in t else 1.0)) for t, c in counts.items()),
                    key=lambda x: (-x[1], x[0]))[:40]
    top = max(scored[0][1], 1e-9)
    if key in state.papers:
        v = state.papers[key][2]
        close = []
        for t, _ in scored:
            ctx = text.context(t, state)
            close.append(dot(ctx, v) if ctx is not None else None)
        known = [c for c in close if c is not None]
        mean = sum(known) / len(known) if known else 0.0
        order = [(t, s / top + 2 * ((c if c is not None else mean) - mean)) for (t, s), c in zip(scored, close)]
    else:
        order = [(t, s / top) for t, s in scored]
    order = [(t, x + (ENDORSED_BONUS if t in endorsed else 0)) for t, x in order]
    order.sort(key=lambda x: (-x[1], x[0]))
    return pick([t for t, _ in order], terms, k)


# ---------- fixture 1: step 2 on the owner's library (anonymised) ----------

def step2_fixture():
    from topic_map import build_tree, interest_state, label_nodes
    from topic_rule2 import run
    corpus = load_corpus()
    E = np.load(os.path.join(OUT, "emb", "gte-small.npy"))
    index = {p["source_id"]: i for i, p in enumerate(corpus)}
    nodes = build_tree(E)
    label_nodes(nodes, corpus, E)
    lib = load_library("owner")
    res = run(corpus, E, nodes, lib, index, None)
    stored = json.load(open(os.path.join(OUT, "interest_owner_v2.json")))
    got = sorted((t["node"], t["user_papers"], t["folded"]) for t in res["topics"])
    want = sorted((t["node"], t["user_papers"], t["folded"]) for t in stored["topics"])
    print("step 2 reproduced:", got == want, "topics", len(got))
    if got != want:
        print(" stored:", want, "\n now:   ", got)
    rows = [index[r["source_id"]] for r in lib]
    names = {r: f"p{i:02d}" for i, r in enumerate(rows)}
    weights = {index[r["source_id"]]: r["weight"] for r in lib}
    interest_state(nodes, corpus, lib, index)
    out_nodes = [{"id": n["id"], "level": n["level"], "parent": n["parent"] if n["level"] > 1 else None,
                  "size": int(n["bg_count"]), "terms": n["terms"][:3]} for n in nodes if n["level"] > 0]
    leaf = {}
    for n in nodes:
        if n["level"] == 3:
            for r in n["user_rows"]:
                leaf[r] = n["id"]
    papers = [{"key": names[r], "leaf": leaf[r], "weight": weights[r],
               "vector": base64.b64encode(E[r].astype("<f4").tobytes()).decode()} for r in rows]
    expected = {
        "topics": [{"node": t["node"], "level": t["level"], "papers": sorted(names[r] for r in t["rows"]), "folded": t["folded"],
                    "share": t["share"], "lift": t["lift"], "residual": t["residual"]} for t in res["topics"]],
        "other": sorted(names[r] for r in res["other"]),
        "other_groups": [{"label": g, "count": n} for g, n in res["other_groups"]],
        "emerging": [{"label": e["label"], "count": e["user_papers"]} for e in res["emerging"]],
    }
    groups = {}
    for n in nodes:
        if n["level"] == 1:
            groups[n["label"]] = n["id"]
    for g in expected["other_groups"]:
        g["node"] = groups[g["label"]]
    json.dump({"note": "Step 2 (tools/interest-eval/topic_rule2.py) on the owner's 62-paper library over the offline trial "
                       "map; paper keys anonymised, sizes are pool papers per node (members minus the library's).",
               "background_total": int(sum(n["bg_count"] for n in nodes if n["level"] == 1)),
               "nodes": out_nodes, "papers": papers, "expected": expected},
              open(os.path.join(FIX, "interest-step2-topics.json"), "w"), separators=(",", ":"))
    return expected


# ---------- fixture 2: a public library on the published map ----------

PROFILE = {  # index → (days ago, archived, own tags, reading level, snippets, chats); others: (index × 3 % 60 days)
    0: (2, False, True, 4, 2, 1), 1: (5, False, False, 3, 0, 1), 5: (1, False, False, 2, 1, 0), 7: (3, False, True, 1, 0, 0),
    10: (40, True, False, 0, 0, 0), 14: (12, False, False, 4, 1, 1), 20: (90, False, False, 0, 0, 0), 25: (8, False, False, 2, 0, 0),
    29: (200, True, False, 0, 0, 0), 33: (1, False, False, 0, 0, 2),
}


def library_fixture():
    header, body = unpack(open(os.path.join(DEVICE, "map.gsi"), "rb").read())
    nodes = [{"id": n["id"], "level": n["level"], "parent": n["parent"], "size": n["size"], "terms": n["terms"],
              "name": n.get("name")} for n in header["nodes"]]
    background = sum(n["size"] for n in nodes if n["level"] == 1)
    th, tb = unpack(open(os.path.join(DEVICE, "terms.gsi"), "rb").read())
    entries = read_terms(tb)
    all_terms = Terms(th, entries)
    fps = json.load(open(os.path.join(DEVICE, "fingerprints.json")))
    corpus = {p["source_id"]: p for p in load_corpus()}
    ids = json.load(open(os.environ.get("POOL_IDS", os.path.join(DEVICE, "pool_ids.json"))))
    papers = []
    for i, sid in enumerate(ids):
        days, archived, own, reading, snippets, chats = PROFILE.get(i, (i * 3 % 60, False, False, 0, 0, 0))
        p, fp = corpus[sid], fps[sid]
        papers.append({"key": sid, "title": p["title"], "abstract": p["abstract"], "days_ago": days, "archived": archived,
                       "own_tags": own, "reading": reading, "snippets": snippets, "chats": chats, "q8": fp["q8"],
                       "leaf": fp["leaf_id"], "leaf_map_version": fp["leaf_map_version"], "server_terms": fp["terms"]})
        papers[-1]["q8"] = "".join(papers[-1]["q8"].split())
    # Trim the statistics to what the fixture's texts use (header totals unchanged).
    used = set()
    for p in papers:
        used |= set(all_terms.counts(doc_text(p["title"], p["abstract"])))
    trimmed = [e for e in entries if e[0] in used]
    th_out = dict(th); th_out["phrases"] = len(trimmed); th_out["note"] = "fixture: trimmed to the fixture papers' phrases"
    open(os.path.join(FIX, "interest-terms-fixture.gsi"), "wb").write(pack(th_out, terms_body(trimmed)))
    shutil.copyfile(os.path.join(DEVICE, "map.gsi"), os.path.join(FIX, "interest-map-v1.gsi"))
    terms = Terms(th, trimmed)

    state = State(nodes, background)
    text = TextIndex()
    for p in papers:
        v = q8_unit(base64.b64decode(p["q8"]))
        w = weight(p["days_ago"], p["archived"], p["own_tags"], p["reading"], p["snippets"], p["chats"])
        state.add(p["key"], v, p["leaf"], w)
        text.set(p["key"], terms.counts(doc_text(p["title"], p["abstract"])).keys())
    sel = select(state)
    server = {p["key"]: {x.lower() for x in (p["server_terms"] or [])} for p in papers}
    used_terms = set()
    for t in sel["topics"]:  # largest first; a phrase labels one topic only
        endorsed = set().union(*(server[k] for k in t["papers"]))
        t["terms"] = topic_terms(t["papers"], state, text, terms, endorsed=endorsed, exclude=used_terms)
        used_terms |= set(t["terms"])
    keywords = {p["key"]: paper_terms(p["key"], terms.counts(doc_text(p["title"], p["abstract"])), state, text, terms,
                                      endorsed=server[p["key"]]) for p in papers}
    # Hysteresis: drop one paper from the smallest 3-paper topic; with the topic established it stays at 2.
    small = next((t for t in reversed(sel["topics"]) if len(t["papers"]) == 3 and t["folded"] == 0 and t["level"] == 3), None)
    hysteresis = None
    if small:
        gone = small["papers"][0]
        st2 = State(nodes, background)
        for p in papers:
            if p["key"] == gone:
                continue
            v = q8_unit(base64.b64decode(p["q8"]))
            st2.add(p["key"], v, p["leaf"], weight(p["days_ago"], p["archived"], p["own_tags"], p["reading"], p["snippets"], p["chats"]))
        without = select(st2)
        kept = select(st2, established=frozenset(t["id"] for t in sel["topics"]))
        hysteresis = {"topic": small["id"], "removed": gone,
                      "without_established": small["id"] in [t["id"] for t in without["topics"]],
                      "with_established": small["id"] in [t["id"] for t in kept["topics"]]}
    fixture = {"note": "Public Feed-pool papers on staging's published map (version 1); expected values from "
                       "tools/interest-eval/device_fixtures.py's reference of the device rules.",
               "now": NOW.isoformat(), "map_version": header["version"], "background_total": background,
               "nodes": nodes, "generic": GENERIC, "papers": papers,
               "expected": {"topics": [{k: t[k] for k in ("id", "level", "papers", "folded", "share", "residual", "terms")}
                                       for t in sel["topics"]],
                            "other": sel["other"], "other_groups": sel["other_groups"], "emerging": sel["emerging"],
                            "keywords": keywords, "hysteresis": hysteresis}}
    json.dump(fixture, open(os.path.join(FIX, "interest-library-v1.json"), "w"), indent=0)
    print(f"library fixture: {len(papers)} papers, {len(trimmed)} phrases, {len(sel['topics'])} topics")
    node_terms = {n["id"]: n["terms"] for n in nodes}
    for t in sel["topics"]:
        print(f"  {t['share'] * 100:5.1f}%  {len(t['papers'])} ({t['folded']})  L{t['level']}  {', '.join(t['terms'])}"
              f"   [map: {' · '.join(node_terms[t['id']][:3])}]")
    print(f"  other {len(sel['other'])}; emerging {sel['emerging']}; hysteresis {hysteresis}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-step2", action="store_true")
    args = ap.parse_args()
    if not args.skip_step2:
        step2_fixture()
    library_fixture()
