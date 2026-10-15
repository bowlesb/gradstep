"""Deterministic stand-ins for the tagger and the recogniser, shared verbatim with the TypeScript run
(tests read the same rules from rules.json): the tagger marks glyphs of math font families; the recogniser
reads a crop by its size."""
import re
MATH = re.compile(r"CMMI|CMSY|CMEX|MSAM|MSBM|Math|rsfs|eufm|wasy|stmry|Symbol", re.I)
def math_ids(vocab):
    return {i for f, i in vocab.items() if MATH.search(f)}
def recognise(w, h):
    k = (w * 7 + h * 13) % 11
    latex = "\\foo{x}" if k == 0 else f"x_{{{k}}}"
    probs = [0.70 + ((w * 31 + h * 17) % 30) / 100, 0.99, 0.93 + (k % 5) / 100]
    return latex, [round(p, 5) for p in probs]
