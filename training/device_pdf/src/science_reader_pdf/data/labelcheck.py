"""Cheap consistency check between an inline-math label and the PDF glyphs under its box.

The factory aligns HTML math to PDF glyph runs; in tables with adjacent math-only cells the
runs are sometimes merged or shifted, so the crop shows one cell and the label is another's
(8.5% of purely numeric inline labels in factory-v2 disagreed with their glyph text, 96% of
them in tables). The label's alphanumeric characters (commands, braces and scripts stripped)
should roughly match the glyph text's; a crop is `suspect` when a numeric label's digits
differ from the glyphs' or the alphanumeric lengths are far apart.

`gs label-check <dataset>` writes `equations/suspect.json` ({paper: [ids]}) next to the index;
the trainer skips those crops and the scorer can report numbers without them. When
`equations-masked/index.jsonl` exists, crops with more foreign than own ink (misplaced boxes,
see maskcrops.py) are flagged too, for either placement.
"""

from __future__ import annotations

import json
import re
from collections import Counter, defaultdict

from science_reader_pdf.paths import DATA, paper_dir

_NUMERIC = re.compile(r"^[-+\u2212]?\d*\.?\d+%?$")
_COMMAND = re.compile(r"\\[A-Za-z]+")
_TEXTCMD = re.compile(r"\\(?:text|mathrm|mathbf|mathit|mathsf|mathtt|operatorname|mbox|textbf|textit|mathcal|mathbb|bm|boldsymbol)\s*\{([^{}]*)\}")


def _alnum(s: str) -> str:
    return re.sub(r"[^0-9A-Za-z]", "", s)


# Colour commands typeset nothing themselves: drop them with their colour arguments (\textcolor keeps its text).
_COLOUR = re.compile(r"\\(?:color|cellcolor|rowcolor|columncolor|pagecolor)(?:\[[^\]]*\])?\{[^{}]*\}")
_TEXTCOLOR = re.compile(r"\\(?:textcolor|mathcolor)(?:\[[^\]]*\])?\{[^{}]*\}")
_OPERATORS = re.compile(r"\\(log|ln|lg|exp|min|max|argmin|argmax|softmax|sin|cos|tan|cot|sec|csc|sinh|cosh|tanh|arcsin|arccos|arctan|lim|liminf|limsup|sup|inf|det|dim|ker|deg|gcd|hom|arg|Pr|mod|bmod|pmod)(?![A-Za-z])")


def label_alnum(tex: str) -> str:
    t = _COLOUR.sub("", tex)
    t = _TEXTCOLOR.sub("", t)  # the text argument that follows stays as ordinary content
    t = _TEXTCMD.sub(r"\1", t)
    t = _OPERATORS.sub(r"\1", t)  # \log typesets the letters l o g; other commands typeset symbols
    t = _COMMAND.sub("", t)
    return _alnum(t)


def is_suspect(tex: str, glyph_text: str) -> str | None:
    """Return the reason a label looks misaligned with its glyphs, or None."""
    g = (glyph_text or "").replace("\u2212", "-")
    t = tex.replace("\\%", "%").replace(" ", "")
    if _NUMERIC.match(t) and _alnum(g):
        return None if re.sub(r"[^0-9]", "", t) == re.sub(r"[^0-9]", "", g) else "numeric-mismatch"
    a, b = label_alnum(tex), _alnum(g)
    if not a or not b:
        return None  # nothing comparable (symbols only)
    ratio = len(b) / len(a)
    if ratio > 1.8 and len(b) - len(a) >= 3:
        return "glyphs-much-longer"
    if ratio < 0.5 and len(a) - len(b) >= 3:
        return "glyphs-much-shorter"
    return None


def check_dataset(dataset: str) -> dict[str, object]:
    root = DATA / "datasets" / dataset
    rows = [json.loads(line) for line in (root / "equations" / "index.jsonl").read_text().splitlines()]
    by_paper: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        if r["placement"] == "inline":
            by_paper[r["paper"]].append(r)
    suspect: dict[str, list[str]] = {}
    reasons: Counter[str] = Counter()
    kinds: Counter[str] = Counter()
    masked_index = root / "equations-masked" / "index.jsonl"
    if masked_index.is_file():  # boxes with more foreign than own ink are misplaced (any placement)
        for m in map(json.loads, masked_index.read_text().splitlines()):
            if m.get("foreign_px", 0) >= 20 and m.get("own_px", 0) < m["foreign_px"]:
                suspect.setdefault(m["paper"], []).append(m["id"])
                reasons["box-misplaced"] += 1
    for pid, items in by_paper.items():
        labels = json.loads((paper_dir(pid) / "build" / "labels.json").read_text())
        inline = {m["id"]: m for m in labels["inline_math"]}
        blocks = {b["id"]: b for b in labels["blocks"]}
        for r in items:
            m = inline.get(r["id"])
            if m is None:
                continue
            why = is_suspect(r["tex"], m.get("glyph_text") or "")
            if why and r["id"] not in suspect.get(pid, []):
                suspect.setdefault(pid, []).append(r["id"])
                reasons[why] += 1
                kinds[blocks.get(m["block_id"], {}).get("kind", "?")] += 1
    (root / "equations" / "suspect.json").write_text(json.dumps(suspect, indent=0, sort_keys=True))
    n_inline = sum(len(v) for v in by_paper.values())
    n_suspect = sum(len(set(v)) for v in suspect.values())
    per_paper = {pid: round(len(set(ids)) / sum(1 for r in rows if r["paper"] == pid), 3) for pid, ids in suspect.items()}
    worst = dict(sorted(per_paper.items(), key=lambda kv: -kv[1])[:5])
    return {"dataset": dataset, "inline": n_inline, "crops": len(rows), "suspect": n_suspect, "rate": round(n_suspect / max(1, len(rows)), 4), "reasons": dict(reasons), "block_kinds": dict(kinds.most_common(6)), "worst_papers": worst}


def load_suspect(dataset: str) -> set[tuple[str, str]]:
    path = DATA / "datasets" / dataset / "equations" / "suspect.json"
    if not path.is_file():
        return set()
    return {(pid, mid) for pid, ids in json.loads(path.read_text()).items() for mid in ids}
