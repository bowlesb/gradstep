"""Field-by-field comparison of two reference-shaped index.json files (numbers within 0.051)."""
import json, sys
a, b = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
def diff(x, y, path, out):
    if isinstance(x, dict) and isinstance(y, dict):
        for k in sorted(set(x) | set(y)):
            if k not in x or k not in y: out.append(f'{path}.{k}: only in {"py" if k in x else "ts"}')
            else: diff(x[k], y[k], f'{path}.{k}', out)
    elif isinstance(x, list) and isinstance(y, list):
        if len(x) != len(y): out.append(f'{path}: length {len(x)} vs {len(y)}')
        for i, (u, v) in enumerate(zip(x, y)): diff(u, v, f'{path}[{i}]', out)
    elif isinstance(x, (int, float)) and isinstance(y, (int, float)) and not isinstance(x, bool) and not isinstance(y, bool):
        if abs(x - y) > 0.051: out.append(f'{path}: {x} vs {y}')
    elif x != y: out.append(f'{path}: {str(x)[:120]!r} vs {str(y)[:120]!r}')
out = []
diff(a, b, '', out)
for k in ('blocks', 'headings', 'equations', 'figures'): print(k, len(a[k]), len(b[k]))
print(len(out), 'differences'); print('\n'.join(out[:40]))
