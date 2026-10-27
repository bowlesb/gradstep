"""Equation recognition benchmark: fixed crop sets and LaTeX scoring.

Scores are deliberately simple and reported separately:
  exact        whitespace-stripped string equality
  normalized   equality after a light canonicalisation (spacing commands, \\left/\\right,
               \\displaystyle, redundant braces around single tokens, \\mathrm vs \\operatorname)
  cer          character edit distance / reference length, on the normalised strings
None of these is semantic correctness; a render-and-compare scorer comes later.
"""

from __future__ import annotations

import json
import random
import re
import subprocess
from collections import defaultdict
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from science_reader_pdf.paths import DATA, REPO_ROOT, RUNS

BENCH_DIR = DATA / "datasets"


def make_bench(dataset: str, name: str, n_inline: int, seed: int = 0, families: set[str] | None = None) -> Path:
    """All display crops plus a fixed random sample of inline crops; dev split kept separate.
    `families` restricts the bench to those paper families (for comparability across datasets)."""
    root = BENCH_DIR / dataset
    rows = [json.loads(line) for line in (root / "equations" / "index.jsonl").read_text().splitlines()]
    if families is not None:
        rows = [r for r in rows if r["family"] in families]
    rng = random.Random(seed)
    display = [r for r in rows if r["placement"] == "display"]
    inline = [r for r in rows if r["placement"] == "inline"]
    rng.shuffle(inline)
    chosen = display + inline[:n_inline]
    out = root / f"bench-{name}.jsonl"
    with out.open("w") as f:
        for r in chosen:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    return out


_SPACING = re.compile(r"\\[,;:!> ]|\\(?:quad|qquad|thinspace|medspace|thickspace|negthinspace|enspace)(?![a-zA-Z])|~"
                      r"|\\(?:hskip|kern|mskip|mkern)\s*-?[0-9.]+\s*(?:pt|em|ex|mu|cm|mm|in|bp)\b|\\hspace\*?\{[^{}]*\}")
_SIZE = re.compile(r"\\(?:left|right|big|Big|bigg|Bigg|bigl|bigr|Bigl|Bigr|biggl|biggr|Biggl|Biggr)(?![a-zA-Z])")
_STYLE = re.compile(r"\\(?:displaystyle|textstyle|scriptstyle|scriptscriptstyle|nonumber|notag|allowbreak|limits|nolimits|label\{[^}]*\})(?![a-zA-Z])")
_SINGLE_BRACE = re.compile(r"\{([A-Za-z0-9()\[\]|])\}")
# Font shape and weight spellings that typeset the same letters: upright/italic/typewriter/sans
# text depends on the surrounding context (theorem bodies are italic, captions may be sans),
# which the source TeX of the formula does not carry, so the string metric ignores shape.
_TEXT_LIKE = re.compile(r"\\(?:operatorname\*?|text|textrm|textit|textbf|textsf|texttt|textnormal|mathrm|mathit|mathsf|mathtt|mathnormal|mbox|hbox)\s*\{")
_BOLD_LIKE = re.compile(r"\\(?:boldsymbol|pmb|mathbf|bm)\s*\{")
_BOLDMATH = re.compile(r"\\mbox\{\\boldmath\$([^$]*)\$\}")
_OLD_FONT = re.compile(r"(?<![A-Za-z])\{\\(cal|bf|it|rm|sf|tt)\s+([^{}]*)\}")
_INNER_SHAPE = re.compile(r"\\(?:it|rm|bf|sf|tt|em)\s+")
# Delimiter spellings with the same glyph, and row containers that only change alignment, not
# content: the string metric compares glyph content; `exact` keeps the structure.
_NORMS = re.compile(r"\\(?:lVert|rVert|Vert)(?![A-Za-z])")
_VERTS = re.compile(r"\\(?:lvert|rvert|vert)(?![A-Za-z])")
_ROW_ENVS = re.compile(r"\\(?:begin|end)\{(?:split|aligned|gathered|multlined)\}")
# Same glyphs, different spelling: \mid is a relation-spaced bar; ,\dots is \ldots after a comma;
# a superscript written before the subscript typesets the same as after it.
_MID = re.compile(r"\\mid(?![A-Za-z])")
_DOTS = re.compile(r",\\dots(?![A-Za-z])")
_SCRIPT_ORDER = re.compile(r"\^(\{[^{}]*\}|[A-Za-z0-9])_(\{[^{}]*\}|[A-Za-z0-9])")
# arg min / arg max in any of their spellings typeset the same operator.
_ARGOP = re.compile(r"\\operatorname\*?\{arg\\[,;: ]?(min|max)\}|\\arg\\(min|max)|\\arg(min|max)(?![A-Za-z])")


_DELIMS = (("\\[", "\\]"), ("$$", "$$"), ("\\(", "\\)"), ("$", "$"))


def strip_delimiters(tex: str) -> str:
    t = tex.strip()
    for open_, close in _DELIMS:
        if t.startswith(open_) and t.endswith(close) and len(t) >= len(open_) + len(close):
            return t[len(open_) : len(t) - len(close)].strip()
    return t


def normalize(tex: str) -> str:
    t = strip_delimiters(tex)
    t = _STYLE.sub("", t)
    t = _SPACING.sub("", t)
    t = _SIZE.sub("", t)
    t = _BOLDMATH.sub(r"\\bm{\1}", t)
    t = _OLD_FONT.sub(lambda m: ("\\mathcal{" if m.group(1) == "cal" else "\\bm{" if m.group(1) == "bf" else "\\mathrm{") + m.group(2) + "}", t)
    t = _TEXT_LIKE.sub(r"\\mathrm{", t)
    t = _BOLD_LIKE.sub(r"\\bm{", t)
    t = _INNER_SHAPE.sub("", t)
    t = _NORMS.sub(r"\\|", t)
    t = _VERTS.sub("|", t)
    t = _MID.sub("|", t)
    t = _DOTS.sub(r",\\ldots", t)
    t = _SCRIPT_ORDER.sub(r"_\2^\1", t)
    t = _ARGOP.sub(lambda m: "\\mathrm{arg" + (m.group(1) or m.group(2) or m.group(3)) + "}", t)
    t = _ROW_ENVS.sub("", t).replace("&", "")
    t = re.sub(r"\s+", "", t)
    prev = None
    while prev != t:
        prev = t
        t = _SINGLE_BRACE.sub(r"\1", t)
    t = t.rstrip(".,;")
    return t


def edit_distance(a: str, b: str) -> int:
    if a == b:
        return 0
    if not a or not b:
        return max(len(a), len(b))
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


@dataclass
class Scored:
    id: str
    placement: str
    split: str
    exact: bool
    normalized: bool
    cer: float
    pred: str
    ref: str
    render_ok: bool | None = None  # both sides rendered
    struct_sim: float | None = None  # fraction of glyph blobs matched in order
    struct_exact: bool | None = None  # every blob matched


def score(bench: Path, predictions: Path, render: bool = True) -> tuple[list[Scored], dict[str, object]]:
    refs = {r["id"] + "@" + r["paper"]: r for r in (json.loads(line) for line in bench.read_text().splitlines())}
    preds = {p["id"] + "@" + p["paper"]: p for p in (json.loads(line) for line in predictions.read_text().splitlines())}
    rendered: dict[str, dict[str, object]] = {}
    if render:
        from science_reader_pdf.eval.render import render_scores

        rendered = render_scores({k: (r["tex"], (preds.get(k) or {}).get("tex") or "", r["placement"] == "display") for k, r in refs.items()})
    out: list[Scored] = []
    for key, r in refs.items():
        p = preds.get(key)
        pred = (p or {}).get("tex") or ""
        ref_n, pred_n = normalize(r["tex"]), normalize(pred)
        exact = re.sub(r"\s+", "", pred) == re.sub(r"\s+", "", r["tex"])
        cer = edit_distance(pred_n, ref_n) / max(1, len(ref_n))
        rs = rendered.get(key)
        sim = rs.get("sim") if rs else None
        out.append(Scored(r["id"], r["placement"], r["split"], exact, pred_n == ref_n, min(cer, 1.0), pred, r["tex"],
                          None if rs is None else bool(rs["ref_ok"] and rs["pred_ok"]), sim, None if sim is None else sim >= 1.0))  # type: ignore[arg-type]
    groups: dict[str, list[Scored]] = defaultdict(list)
    for s in out:
        groups["all"].append(s)
        groups[s.placement].append(s)
        groups[f"{s.split}/{s.placement}"].append(s)
    summary: dict[str, object] = {}
    for g, items in sorted(groups.items()):
        n = len(items)
        row: dict[str, object] = {"n": n, "exact": round(sum(s.exact for s in items) / n, 4), "normalized": round(sum(s.normalized for s in items) / n, 4), "cer": round(sum(s.cer for s in items) / n, 4), "missing": sum(1 for s in items if not s.pred)}
        if render:
            row["render_match"] = round(sum(1 for s in items if s.struct_exact) / n, 4)  # unrendered counts as no match
            row["struct_sim"] = round(sum(s.struct_sim or 0.0 for s in items) / n, 4)
            row["pred_unrenderable"] = sum(1 for s in items if s.pred and s.render_ok is False)
            row["either"] = round(sum(1 for s in items if s.normalized or s.struct_exact) / n, 4)
        summary[g] = row
    return out, summary


def record(model: str, bench: Path, predictions: Path, summary: dict[str, object], seconds: float | None) -> Path:
    RUNS.mkdir(parents=True, exist_ok=True)
    commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=REPO_ROOT, capture_output=True, text=True, check=False).stdout.strip()
    row = {"time_utc": datetime.now(UTC).isoformat(), "task": "equation-recognition", "model": model, "bench": str(bench.relative_to(DATA)), "predictions": str(predictions.relative_to(DATA)), "commit": commit, "seconds": seconds, "summary": summary}
    with (RUNS / "metrics.jsonl").open("a") as f:
        f.write(json.dumps(row) + "\n")
    return RUNS / "metrics.jsonl"
