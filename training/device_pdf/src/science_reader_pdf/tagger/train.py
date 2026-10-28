"""Inline tagger v5: the v4 recipe (2-layer bidirectional GRU over a line's glyphs, boundary-weighted loss, epoch and
threshold chosen on dev) with
  - cross-line context: the previous line's last K glyphs and the next line's first K glyphs ride along the line, each
    marked by a flag feature (x gains two columns: 12), unscored; dropped at random so a line without neighbours
    (a region's first or last line, a table cell) is read as well;
  - table rows also as their cells (the device tags cells);
  - 3.6k training papers (v4: 1.08k).

    python train.py run <name> [--epochs 4] [--context 24] [--hidden 96] [--papers N] [--boundary 2] [--textmath 0]
    python -m science_reader_pdf.tagger.train v4 --checkpoint /absolute/path/tagger.pt

Historical v5 base recipe: padded/truncated batches are preserved for reproduction only.
Use papers_train_tagger.py and complete-window evaluation for new adaptation work.
"""
import argparse, json, math, os, random, sys, time, threading, queue
from collections import Counter
from pathlib import Path
import numpy as np
import torch
import torch.nn as nn

from science_reader_pdf.paths import TAGGER, RUNS as RUN_ROOT

DATA = TAGGER / "data"
RUNS = RUN_ROOT / "tagger"
FONT_VOCAB, CHAR_VOCAB, MAX_LEN = 256, 512, 400
DEFAULT_PRIOR = 0.04


class Tagger(nn.Module):
    def __init__(self, n_feats=12, hidden=96):
        super().__init__()
        self.font = nn.Embedding(FONT_VOCAB, 24); self.cls = nn.Embedding(10, 8); self.ch = nn.Embedding(CHAR_VOCAB, 16)
        self.inp = nn.Linear(n_feats + 24 + 8 + 16, hidden)
        self.gru = nn.GRU(hidden, hidden, num_layers=2, batch_first=True, bidirectional=True, dropout=0.1)
        self.out = nn.Linear(2 * hidden, 1)

    def forward(self, x, f, c, ch):
        h = torch.relu(self.inp(torch.cat([x, self.font(f), self.cls(c), self.ch(ch)], -1)))
        h, _ = self.gru(h)
        return self.out(h).squeeze(-1)


class Corpus:
    """Every paper's glyph arrays concatenated; items are lines (start, end, kind, prev, next) in global glyph indices."""

    def __init__(self, pids, data_dir=None):
        data_dir = Path(data_dir) if data_dir is not None else DATA
        feats, fonts, cls, cp, y, shade, items = [], [], [], [], [], [], []
        off = 0; nitem = 0; self.fontnames = []
        for p in pids:
            f = data_dir / f"{p}.npz"
            if not f.is_file(): raise FileNotFoundError(f)
            z = np.load(f, allow_pickle=True)
            names = list(z["fonts"]); fid = np.array([len(self.fontnames) + i for i in range(len(names))], np.int32)
            self.fontnames += names
            ft = z["feats"].astype(np.float32); ft = np.nan_to_num(ft, nan=0.0, posinf=50.0, neginf=-50.0)
            feats.append(ft); fonts.append(fid[z["font"].astype(np.int64)]); cls.append(z["cls"]); cp.append(z["cp"]); y.append(z["y"]); shade.append(z["shade"])
            s = z["start"].astype(np.int64); n = len(z["kind"])
            prev = z["prev"].astype(np.int64); nxt = z["next"].astype(np.int64)
            it = np.stack([s[:-1] + off, s[1:] + off, z["kind"].astype(np.int64), np.where(prev >= 0, prev + nitem, -1), np.where(nxt >= 0, nxt + nitem, -1)], 1)
            items.append(it); off += int(s[-1]); nitem += n
        self.feats = np.concatenate(feats); self.font_raw = np.concatenate(fonts); self.cls = np.concatenate(cls).astype(np.int64)
        self.cp = np.concatenate(cp).astype(np.int64); self.y = np.concatenate(y).astype(np.int64); self.shade = np.concatenate(shade)
        self.items = np.concatenate(items)

    def encode(self, vocab, prior, cvocab):
        fam_ids = {n: i for i, n in enumerate(sorted(set(self.fontnames)))}
        uniq = sorted(fam_ids, key=fam_ids.get)
        name_of_raw = np.array([fam_ids[n] for n in self.fontnames], np.int64)
        u = name_of_raw[self.font_raw]
        self.font = np.array([vocab.get(n, 0) for n in uniq], np.int64)[u]
        self.prior = np.array([prior.get(n, DEFAULT_PRIOR) for n in uniq], np.float32)[u]
        lut = np.zeros(0x10000, np.int64)
        for k, v in cvocab.items(): lut[k] = v
        self.char = lut[np.minimum(self.cp, 0xFFFF)]
        self.famid = u


def vocabularies(c: Corpus):
    n = len(c.fontnames)
    allc = np.bincount(c.font_raw, minlength=n); mathc = np.bincount(c.font_raw[c.y == 1], minlength=n)
    counts, math_c = Counter(), Counter()
    for name, a, m in zip(c.fontnames, allc.tolist(), mathc.tolist()):
        counts[name] += a; math_c[name] += m
    counts = Counter({k: v for k, v in counts.items() if v > 0})
    vocab = {f: i + 1 for i, (f, _) in enumerate(counts.most_common(FONT_VOCAB - 1))}
    prior = {f: math_c[f] / counts[f] for f in counts}
    cc = np.bincount(np.minimum(c.cp, 0xFFFF), minlength=0x10000)
    top = np.argsort(-cc, kind="stable")[: CHAR_VOCAB - 1]
    cvocab = {int(cp): i + 1 for i, cp in enumerate(top) if cc[cp] > 0}
    return vocab, prior, cvocab


def sequence(c: Corpus, i, K, rng=None, drop=0.0):
    """Glyph indices of item i with its context, and the flag per glyph (0 own, 1 previous line, 2 next line)."""
    s, e, kind, p, n = c.items[i]
    own = np.arange(s, e)
    pre = np.arange(0); post = np.arange(0)
    if K > 0 and kind == 0:
        if p >= 0 and not (rng and rng.random() < drop):
            ps, pe = c.items[p][:2]; pre = np.arange(max(ps, pe - K), pe)
        if n >= 0 and not (rng and rng.random() < drop):
            ns, ne = c.items[n][:2]; post = np.arange(ns, min(ne, ns + K))
    own = own[: MAX_LEN - len(pre) - len(post)]
    idx = np.concatenate([pre, own, post])
    flag = np.concatenate([np.full(len(pre), 1), np.zeros(len(own), np.int64), np.full(len(post), 2)])
    return idx, flag


def tensors(c: Corpus, idx, flag, K):
    """The model's inputs for one sequence (as the converter's tagInput builds them)."""
    pr = c.prior[idx]
    prev = np.concatenate([[DEFAULT_PRIOR], pr[:-1]]); nxt = np.concatenate([pr[1:], [DEFAULT_PRIOR]])
    fam = c.famid[idx]
    same = np.concatenate([[1.0], (fam[1:] == fam[:-1]).astype(np.float32)])
    cols = [c.feats[idx], pr[:, None], prev[:, None], nxt[:, None], same[:, None]]
    if K > 0: cols += [(flag == 1).astype(np.float32)[:, None], (flag == 2).astype(np.float32)[:, None]]
    return np.concatenate(cols, 1).astype(np.float32), c.font[idx], c.cls[idx], c.char[idx]


def batches(c: Corpus, order, K, budget, rng=None, drop=0.0, device="cuda"):
    """Batches of about `budget` glyphs, items of similar length together."""
    lens = (c.items[order, 1] - c.items[order, 0])
    order = order[np.argsort(lens + (np.array([rng.random() for _ in order]) * 8 if rng else 0), kind="stable")]
    groups, cur, longest = [], [], 0
    for i in order:
        L = int(c.items[i, 1] - c.items[i, 0]) + 2 * K
        if cur and max(longest, L) * (len(cur) + 1) > budget:
            groups.append(cur); cur, longest = [], 0
        cur.append(i); longest = max(longest, L)
    if cur: groups.append(cur)
    if rng: rng.shuffle(groups)
    nf = 12 if K > 0 else 10

    def make(group):
        seqs = [sequence(c, i, K, rng, drop) for i in group]
        lens = np.array([len(s[0]) for s in seqs]); L = int(lens.max()); B = len(group)
        idx = np.concatenate([s[0] for s in seqs]); flag = np.concatenate([s[1] for s in seqs])
        row = np.repeat(np.arange(B), lens); col = np.arange(len(idx)) - np.repeat(np.cumsum(lens) - lens, lens)
        first = col == 0; last = col == np.repeat(lens - 1, lens)
        pr = c.prior[idx]
        prev = np.where(first, DEFAULT_PRIOR, np.concatenate([[DEFAULT_PRIOR], pr[:-1]]))
        nxt = np.where(last, DEFAULT_PRIOR, np.concatenate([pr[1:], [DEFAULT_PRIOR]]))
        fam = c.famid[idx]
        same = np.where(first, 1.0, np.concatenate([[1], (fam[1:] == fam[:-1])]).astype(np.float32))
        cols = [c.feats[idx], pr[:, None], prev[:, None], nxt[:, None], same[:, None]]
        if K > 0: cols += [(flag == 1).astype(np.float32)[:, None], (flag == 2).astype(np.float32)[:, None]]
        x = np.zeros((B, L, nf), np.float32); x[row, col] = np.concatenate(cols, 1)
        f = np.zeros((B, L), np.int64); cl = np.zeros_like(f); ch = np.zeros_like(f)
        f[row, col] = c.font[idx]; cl[row, col] = c.cls[idx]; ch[row, col] = c.char[idx]
        y = np.full((B, L), -1.0, np.float32); y[row, col] = np.where(flag == 0, c.y[idx], -1)
        return group, seqs, x, f, cl, ch, y

    q = queue.Queue(maxsize=64)
    def worker(part):
        for g in part: q.put(make(g))
        q.put(None)
    nthreads = 6
    parts = [groups[k::nthreads] for k in range(nthreads)]
    for part in parts: threading.Thread(target=worker, args=(part,), daemon=True).start()
    done = 0
    while done < nthreads:
        b = q.get()
        if b is None: done += 1; continue
        group, seqs, x, f, cl, ch, y = b
        yield group, seqs, torch.from_numpy(x).to(device), torch.from_numpy(f).to(device), torch.from_numpy(cl).to(device), torch.from_numpy(ch).to(device), torch.from_numpy(y).to(device)


def spans(bits):
    out, start = [], None
    for i, b in enumerate(list(bits) + [False]):
        if b and start is None: start = i
        if not b and start is not None: out.append((start, i)); start = None
    return out


@torch.no_grad()
def predict(model, c, order, K, device="cuda"):
    """Sigmoid per own glyph of every item, as {item: probs}."""
    model.eval(); out = {}
    for group, seqs, x, f, cl, ch, y in batches(c, order, K, 60000, device=device):
        p = torch.sigmoid(model(x, f, cl, ch)).float().cpu().numpy()
        for k, i in enumerate(group):
            idx, flag = seqs[k]
            out[int(i)] = p[k, :len(idx)][flag == 0]
    return out


def score(c, probs, threshold, kinds=None):
    """Glyph and exact-span precision/recall; the spans' kinds of error; by item kind."""
    tp = fp = fn = 0; hit = npred = ngold = 0
    err = Counter()
    for i, p in probs.items():
        s, e, kind = c.items[i][:3]
        if kinds is not None and kind not in kinds: continue
        yk = c.y[s:s + len(p)] > 0; pk = p > threshold
        tp += int((pk & yk).sum()); fp += int((pk & ~yk).sum()); fn += int((~pk & yk).sum())
        # gold spans split by shade changes too (two formulas side by side)
        sh = c.shade[s:s + len(p)]
        gs = []
        for a, b in spans(yk.tolist()):
            st = a
            for j in range(a + 1, b):
                if sh[j] != sh[j - 1]: gs.append((st, j)); st = j
            gs.append((st, b))
        ps = spans(pk.tolist())
        gset, pset = set(gs), set(ps)
        hit += len(gset & pset); npred += len(ps); ngold += len(gs)
        n = len(p)
        for a, b in gs:
            if (a, b) in pset: continue
            ov = [(x, z) for x, z in ps if min(z, b) > max(x, a)]
            edge = a == 0 or b == n
            if not ov: err["missed" + ("@edge" if edge else "")] += 1
            elif len(ov) > 1: err["split"] += 1
            else:
                x, z = ov[0]
                if x <= a and z >= b: err["overgrown"] += 1
                elif x >= a and z <= b: err["cut" + ("@edge" if edge else "")] += 1
                else: err["shifted"] += 1
    P = hit / max(1, npred); R = hit / max(1, ngold)
    return {"glyph_p": round(tp / max(1, tp + fp), 4), "glyph_r": round(tp / max(1, tp + fn), 4), "span_p": round(P, 4), "span_r": round(R, 4),
            "span_f1": round(2 * P * R / max(1e-9, P + R), 4), "gold": ngold, "errors": dict(err.most_common())}


def load_lists(n_papers=None, root=None):
    root = Path(root) if root is not None else TAGGER
    data_dir = root / "data"
    lists = json.load((root / "papers.json").open())
    tr = [p for p in lists["train"] if (data_dir / f"{p}.npz").is_file()]
    if n_papers: tr = tr[:n_papers]
    dv = [p for p in lists["dev"] if (data_dir / f"{p}.npz").is_file()]
    te = [p for p in lists["test"] if (data_dir / f"{p}.npz").is_file()]
    return tr, dv, te


def run(args):
    out = RUNS / args.name; out.mkdir(parents=True, exist_ok=True)
    log = (out / "log.jsonl").open("a")
    def emit(row): print(json.dumps(row), flush=True); log.write(json.dumps(row) + "\n"); log.flush()
    tr_ids, dv_ids, te_ids = load_lists(args.papers)
    t0 = time.monotonic()
    tr, dv, te = Corpus(tr_ids), Corpus(dv_ids), Corpus(te_ids)
    vocab, prior, cvocab = vocabularies(tr)
    for c in (tr, dv, te): c.encode(vocab, prior, cvocab)
    emit({"args": vars(args), "train_papers": len(tr_ids), "train_items": len(tr.items), "train_glyphs": len(tr.y), "dev_items": len(dv.items), "test_items": len(te.items), "load_s": round(time.monotonic() - t0)})
    torch.manual_seed(args.seed); random.seed(args.seed); rng = random.Random(args.seed)
    K = args.context
    model = Tagger(12 if K > 0 else 10, args.hidden).cuda()
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=0.01)
    pos_weight = torch.tensor(3.0, device="cuda")
    order = np.arange(len(tr.items))
    # table cells and rows: oversample cells so they are a visible share of the data
    cells = order[tr.items[:, 2] == 2]
    steps_per_epoch = None; step = 0
    best = (-1.0, None, None, None)
    thresholds = (0.3, 0.4, 0.5, 0.6, 0.7, 0.8)
    for epoch in range(args.epochs):
        model.train(); tot = n = 0
        ep_order = np.concatenate([order] + [cells] * args.cell_repeat)
        for group, seqs, x, f, cl, ch, y in batches(tr, ep_order, K, args.budget, rng, args.ctx_drop):
            if steps_per_epoch is None: pass
            logits = model(x, f, cl, ch); mask = y >= 0
            yy = y.clamp(min=0)
            w = torch.ones_like(yy)
            if args.boundary > 0:
                edge = torch.zeros_like(yy)
                ch_ = (yy[:, 1:] != yy[:, :-1]).float() * mask[:, 1:].float() * mask[:, :-1].float()
                edge[:, 1:] += ch_; edge[:, :-1] += ch_
                w = w + args.boundary * (edge > 0).float()
            if args.textmath > 0:
                # math glyphs whose font is mostly text (operator names, upright digits, \mathrm) weigh more
                w = w + args.textmath * ((x[..., 6] < 0.3) & (yy > 0.5)).float()
            loss = (nn.functional.binary_cross_entropy_with_logits(logits[mask], y[mask], pos_weight=pos_weight, reduction="none") * w[mask]).sum() / w[mask].sum()
            opt.zero_grad(); loss.backward(); nn.utils.clip_grad_norm_(model.parameters(), 1.0); opt.step()
            tot += float(loss.detach()); n += 1; step += 1
        row = {"epoch": epoch + 1, "loss": round(tot / max(1, n), 4), "batches": n, "minutes": round((time.monotonic() - t0) / 60, 1)}
        dp = predict(model, dv, np.arange(len(dv.items)), K)
        sweep = {thr: score(dv, dp, thr) for thr in thresholds}
        thr_best = max(sweep, key=lambda t: sweep[t]["span_f1"])
        row["dev_f1"] = {str(t): sweep[t]["span_f1"] for t in thresholds}; row["dev_threshold"] = thr_best
        row["dev_cells"] = score(dv, dp, thr_best, {2})["span_f1"]
        if sweep[thr_best]["span_f1"] > best[0]:
            best = (sweep[thr_best]["span_f1"], epoch + 1, thr_best, {k: v.detach().cpu().clone() for k, v in model.state_dict().items()})
        emit(row)
        for g in opt.param_groups: g["lr"] *= args.decay
    model.load_state_dict(best[3])
    tp = predict(model, te, np.arange(len(te.items)), K)
    res = {"selected_epoch": best[1], "selected_threshold": best[2], "dev_span_f1": round(best[0], 4),
           "test": score(te, tp, best[2]), "test_text": score(te, tp, best[2], {0}), "test_rows": score(te, tp, best[2], {1}), "test_cells": score(te, tp, best[2], {2}),
           "test_thresholds": {str(t): score(te, tp, t)["span_f1"] for t in thresholds}}
    emit(res)
    torch.save({"model": model.state_dict(), "vocab": vocab, "prior": prior, "cvocab": cvocab, "threshold": best[2], "context": K, "hidden": args.hidden,
                "n_feats": 12 if K > 0 else 10}, out / "tagger.pt")


def evaluate_v4(args):
    """v4's weights on the same test items (no context; its own vocabularies)."""
    ck = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    model = Tagger(10, 96); model.load_state_dict(ck["model"]); model.cuda()
    _, dv_ids, te_ids = load_lists()
    out = {}
    for name, ids in (("dev", dv_ids), ("test", te_ids)):
        c = Corpus(ids); c.encode(ck["vocab"], ck["prior"], ck["cvocab"])
        p = predict(model, c, np.arange(len(c.items)), 0)
        for thr in (0.5, 0.7):
            out[f"{name}@{thr}"] = {"all": score(c, p, thr), "text": score(c, p, thr, {0}), "rows": score(c, p, thr, {1}), "cells": score(c, p, thr, {2})}
    print(json.dumps(out, indent=1))
    (RUNS / "v4-eval.json").write_text(json.dumps(out, indent=1))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", type=Path); ap.add_argument("cmd", choices=["run", "v4"]); ap.add_argument("name", nargs="?", default="v5a")
    ap.add_argument("--epochs", type=int, default=4); ap.add_argument("--context", type=int, default=24); ap.add_argument("--hidden", type=int, default=96)
    ap.add_argument("--papers", type=int, default=None); ap.add_argument("--boundary", type=float, default=2.0); ap.add_argument("--textmath", type=float, default=0.0)
    ap.add_argument("--lr", type=float, default=2e-3); ap.add_argument("--decay", type=float, default=0.7); ap.add_argument("--budget", type=int, default=24000)
    ap.add_argument("--ctx-drop", type=float, default=0.15); ap.add_argument("--cell-repeat", type=int, default=1); ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()
    if a.cmd == "run": run(a)
    elif a.cmd == "v4":
        if a.checkpoint is None: ap.error("v4 requires --checkpoint")
        evaluate_v4(a)
