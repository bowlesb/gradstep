import json, runpy, sys
S = sys.argv[1]
ns = runpy.run_path(S + '/ann.py')
A = ns['A']
for k, e in A.items():
    if e['label'] not in ('single', 'exclude') and 'class=' not in e.get('note', ''):
        e['note'] = 'class=plot-grid; ' + e.get('note', '')
json.dump(A, open(S + '/annotations.json', 'w'), indent=0)
print(len(A))
