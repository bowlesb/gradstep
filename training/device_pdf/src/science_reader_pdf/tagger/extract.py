"""Training data for the inline tagger v5 (science-reader-device-pdf; read-only use of /home/ben/mathpix).

Per paper, every text line of every page as the v4 recipe made it (experiments/2026-10-13-inline-boundary-v0
`lines_of`, `raw_features`), plus what v4 never saw:
  - the line's neighbours in the text flow (previous and next line of the same column), for cross-line context;
  - table rows split into cells the way the converter splits them (tables.ts `tableCells`: x gaps over 0.6 x the
    row's lower-median glyph height), each cell a line of its own, as the device tags them;
  - abstract and algorithm lines (v4 dropped their text glyphs and kept their math, leaving math-only fragments).
Labels: inline_math glyphs (instrumentation colour), and the formula's shade (consecutive formulas alternate).

    PYTHONDONTWRITEBYTECODE=1 /home/ben/mathpix/.venv/bin/python extract.py <n_pool> [workers]
"""
import json, re, sys, time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import numpy as np

from science_reader_pdf.paths import DATA, TAGGER, paper_dir  # noqa: E402

HERE = Path(__file__).resolve().parent
OUT = TAGGER / "data"
CTX = {"text", "table", "float", "footnote", "inline_math", "abstract", "algorithm"}
EXCLUDED = {"display_math", "equation_tag", "bibliography"}
CELL_GAP = 0.6


def font_family(font):
    return re.sub(r"\d+$", "", re.sub(r"^[A-Z]{6}\+", "", font))


def char_class(ch):
    if ch.isdigit(): return 1
    if ch.isalpha():
        o = ord(ch)
        if 0x370 <= o <= 0x3FF: return 4
        return 2 if ch.islower() else 3
    if ch in ".,;:": return 5
    if ch in "()[]{}": return 6
    if ch in "+-=<>*/|~^_": return 7
    if ch.isspace(): return 8
    return 9


def keep_glyphs(glyphs):
    """Text-context glyphs; an inline formula between excluded classes (a bibliography's math) goes with them."""
    out = []
    n = len(glyphs)
    for i, g in enumerate(glyphs):
        if g.cls in EXCLUDED or g.cls not in CTX or not g.text.strip():
            continue
        if g.cls == "inline_math":
            p = next((glyphs[j].cls for j in range(i - 1, -1, -1) if glyphs[j].cls != "inline_math"), "text")
            q = next((glyphs[j].cls for j in range(i + 1, n) if glyphs[j].cls != "inline_math"), "text")
            if p in EXCLUDED and q in EXCLUDED:
                continue
        out.append(g)
    return out


def lines_of(gl):
    lines, cur = [], []
    top = bottom = 0.0
    for g in gl:
        if cur:
            overlap = min(g.bottom, bottom) - max(g.top, top) > 0
            back = g.x0 < cur[-1].x0 - 2.0 * max(g.size, 1.0)
            if not overlap or (back and g.top > bottom - 1.0):
                lines.append(cur); cur = []
        if not cur:
            top, bottom = g.top, g.bottom
        else:
            top, bottom = min(top, g.top), max(bottom, g.bottom)
        cur.append(g)
    if cur: lines.append(cur)
    return lines


def raw_features(line):
    sizes = np.array([g.size for g in line]); med = float(np.median(sizes)) or 1.0
    mid = np.array([(g.top + g.bottom) / 2 for g in line]); lmid = float(np.median(mid))
    feats = []
    for i, g in enumerate(line):
        gap_prev = (g.x0 - line[i - 1].x1) / med if i > 0 else 2.0
        gap_next = (line[i + 1].x0 - g.x1) / med if i + 1 < len(line) else 2.0
        feats.append([g.size / med, (mid[i] - lmid) / med, max(-2, min(2, gap_prev)), max(-2, min(2, gap_next)), float(g.upright), (g.x1 - g.x0) / med])
    return np.array(feats, dtype=np.float32)


def lower_median(v):
    s = sorted(v)
    return s[(len(s) - 1) // 2]


def cells_of(line):
    order = sorted(line, key=lambda g: g.x0)
    h = max(1.0, lower_median([g.bottom - g.top for g in order]))
    runs = [[order[0]]]
    for g in order[1:]:
        if g.x0 - runs[-1][-1].x1 > CELL_GAP * h:
            runs.append([])
        runs[-1].append(g)
    return runs


def extract_paper(pid):
    from science_reader_pdf.data.pdftext import read_pages
    items = []  # (glyphs, kind, page, prev, next)
    try:
        pages = read_pages(paper_dir(pid) / "build" / "instr.pdf")
    except Exception as e:  # noqa: BLE001
        return pid, None, str(e)[:200]
    for page in pages:
        lines = [ln for ln in lines_of(keep_glyphs(page.glyphs)) if len(ln) >= 2]
        base = len(items)
        kinds = []
        for ln in lines:
            nonmath = [g for g in ln if g.cls != "inline_math"]
            table = bool(nonmath) and sum(g.cls == "table" for g in nonmath) >= 0.5 * len(nonmath)
            kinds.append(1 if table else 0)
        for k, ln in enumerate(lines):
            prev = nxt = -1
            if kinds[k] == 0:
                med = float(np.median([g.size for g in ln])) or 1.0
                x0, x1 = min(g.x0 for g in ln), max(g.x1 for g in ln)
                top, bot = min(g.top for g in ln), max(g.bottom for g in ln)
                def near(other, above):
                    ox0, ox1 = min(g.x0 for g in other), max(g.x1 for g in other)
                    otop, obot = min(g.top for g in other), max(g.bottom for g in other)
                    gap = (top - obot) if above else (otop - bot)
                    return min(x1, ox1) - max(x0, ox0) > 0 and -0.3 * med < gap < 1.2 * med
                if k > 0 and kinds[k - 1] == 0 and near(lines[k - 1], True): prev = base + k - 1
                if k + 1 < len(lines) and kinds[k + 1] == 0 and near(lines[k + 1], False): nxt = base + k + 1
            items.append((ln, kinds[k], page.number, prev, nxt))
        for k, ln in enumerate(lines):  # table cells after the page's lines (indices of lines stay put)
            if kinds[k] == 1:
                for cell in cells_of(ln):
                    if len(cell) >= 2:
                        items.append((cell, 2, page.number, -1, -1))
    fonts, font_idx = {}, []
    feats, cls_, cps, y, shade, starts, kind, pg, prv, nxt = [], [], [], [], [], [0], [], [], [], []
    for ln, k, p, a, b in items:
        feats.append(raw_features(ln))
        for g in ln:
            fam = font_family(g.font)
            font_idx.append(fonts.setdefault(fam, len(fonts)))
            ch = g.text[:1] or " "
            cls_.append(char_class(ch)); cps.append(min(ord(ch), 0xFFFF))
            y.append(1 if g.cls == "inline_math" else 0); shade.append(g.shade)
        starts.append(starts[-1] + len(ln)); kind.append(k); pg.append(p); prv.append(a); nxt.append(b)
    if not items:
        return pid, None, "empty"
    data = dict(feats=np.concatenate(feats).astype(np.float16), font=np.array(font_idx, np.int16), fonts=np.array(list(fonts), dtype=object),
                cls=np.array(cls_, np.int8), cp=np.array(cps, np.int32), y=np.array(y, np.int8), shade=np.array(shade, np.int8),
                start=np.array(starts, np.int32), kind=np.array(kind, np.int8), page=np.array(pg, np.int16), prev=np.array(prv, np.int32), next=np.array(nxt, np.int32))
    np.savez_compressed(OUT / f"{pid}.npz", **data)
    return pid, len(items), None


def paper_lists(n_pool):
    from science_reader_pdf.data.papers import family_of
    pilot = set(json.load((DATA / "datasets" / "factory-v1" / "splits.json").open()).keys())
    exclude = set((HERE / "exclude-ids.txt").read_text().split())
    pids = [json.loads(l)["id"] for l in (DATA / "arxiv" / "papers.jsonl").read_text().splitlines()]
    pids = [p for p in pids if family_of(p) not in exclude and (paper_dir(p) / "build" / "instr.pdf").is_file() and (paper_dir(p) / "build" / "labels.json").is_file()]
    test = [p for p in pids if family_of(p) in pilot]
    pool = [p for p in pids if family_of(p) not in pilot][:n_pool]
    dev = pool[9::10]
    train = [p for p in pool if p not in set(dev)]
    return train, dev, test


if __name__ == "__main__":
    n_pool = int(sys.argv[1]); workers = int(sys.argv[2]) if len(sys.argv) > 2 else 24
    OUT.mkdir(parents=True, exist_ok=True)
    train, dev, test = paper_lists(n_pool)
    json.dump({"train": train, "dev": dev, "test": test}, (TAGGER / "papers.json").open("w"))
    todo = [p for p in test + dev + train if not (OUT / f"{p}.npz").is_file()]
    print(f"train {len(train)} dev {len(dev)} test {len(test)} to extract {len(todo)}", flush=True)
    t0 = time.monotonic(); bad = 0
    with ProcessPoolExecutor(max_workers=workers) as pool:
        for k, (pid, n, err) in enumerate(pool.map(extract_paper, todo, chunksize=2), start=1):
            if err: bad += 1
            if k % 100 == 0: print(k, round(time.monotonic() - t0), "failed", bad, flush=True)
    print("done", round(time.monotonic() - t0), "failed", bad, flush=True)
