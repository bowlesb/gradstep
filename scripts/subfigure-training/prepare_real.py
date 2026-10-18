#!/usr/bin/env python3
"""Build an immutable real-figure corpus from manual Label Studio annotations.

Retain panel/context relations; remove enclosing category boxes, not true insets.
Keep the initial pilot's training/validation exposure out of the new final test.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re
import urllib.parse

from PIL import Image
import pyarrow.parquet as pq
from prepare import phash, sha, CLASSES, REVISION

CONTEXT={'Shared Legend':0,'Shared Title':1,'Shared X-Axis':2,'Shared Y-Axis':3}
CORE={'Chart','Image','Illustration','Table','Subpanel'}


def area(b):return max(0,b[2]-b[0])*max(0,b[3]-b[1])
def intersection(a,b):return max(0,min(a[2],b[2])-max(a[0],b[0]))*max(0,min(a[3],b[3])-max(a[1],b[1]))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,required=True);p.add_argument('--source',type=Path,required=True)
    p.add_argument('--metadata',type=Path,required=True);p.add_argument('--previous',type=Path,required=True)
    p.add_argument('--single-source',type=Path,help='Upstream curated single-panel images, for false-split controls')
    p.add_argument('--out',type=Path,required=True);args=p.parse_args()
    if args.out.exists():raise ValueError('Immutable dataset revision exists')
    root=args.root.resolve();source=args.source.resolve()
    records=json.loads((source/'label-studio_export/real_labels.json').read_text())
    publications={x['id']:x for x in pq.read_table(args.metadata).to_pylist()}
    rows=[];rejected=[];seen={}
    for item in records:
        name=Path(urllib.parse.unquote(item['data']['image'])).name
        path=source/name;identifier=path.stem;paper=identifier.split('-')[0]
        if not re.fullmatch(r'[a-f0-9]{32}',paper) or paper not in publications:raise ValueError('Missing source article')
        if not path.exists():raise ValueError(f'Missing annotated figure: {name}')
        image=Image.open(path).convert('RGB');w,h=image.size
        annotations=[a for a in item['annotations'] if not a.get('was_cancelled')]
        if len(annotations)!=1:raise ValueError('Ambiguous annotation revision')
        annotation=annotations[0];boxes=[];relations=[];bad=None
        for obj in annotation['result']:
            if obj['type']=='relation':
                relations.append({'from':obj['from_id'],'to':obj['to_id']});continue
            if obj['type']!='rectanglelabels':continue
            v=obj['value'];labels=v['rectanglelabels']
            if len(labels)!=1 or (labels[0] not in CORE and labels[0] not in CONTEXT):raise ValueError('Unknown rectangle class')
            if v.get('rotation',0) or obj.get('image_rotation',0):bad='rotated_annotation';break
            b=[v['x']*w/100,v['y']*h/100,(v['x']+v['width'])*w/100,(v['y']+v['height'])*h/100]
            if min(b[:2]) < -2 or b[2]>w+2 or b[3]>h+2 or area(b)<=0:bad='invalid_annotation_bounds';break
            b=[max(0.,b[0]),max(0.,b[1]),min(float(w),b[2]),min(float(h),b[3])]
            boxes.append({'id':obj['id'],'class':CONTEXT.get(labels[0],4),'source_class':labels[0],
                          'box':b,'origin':obj.get('origin','unspecified')})
        if bad:rejected.append({'id':identifier,'reason':bad});continue
        # A Chart rectangle around its Subpanels is a category parent, not another requested crop.
        cores=[b for b in boxes if b['class']==4];removed=[];kept=[]
        for b in cores:
            if b['source_class']=='Subpanel':kept.append(b);continue
            descendants=[c for c in cores if c['id']!=b['id'] and
                         intersection(b['box'],c['box'])/area(c['box'])>=.97 and
                         (area(b['box'])>area(c['box'])*1.08 or c['source_class']=='Subpanel')]
            if descendants:removed.append(b);continue
            # A category label for the same part can also sit just inside its Subpanel.
            if any(c['source_class']=='Subpanel' and intersection(b['box'],c['box'])/area(b['box'])>=.97 for c in cores):
                removed.append(b);continue
            kept.append(b)
        if not kept:rejected.append({'id':identifier,'reason':'no_leaf_panel'});continue
        selected=[b for b in boxes if b['class']!=4]+kept
        context_ids={b['id'] for b in selected if b['class']!=4}
        for b in selected:
            required={r['to'] for r in relations if r['from']==b['id'] and r['to'] in context_ids}
            required|={r['from'] for r in relations if r['to']==b['id'] and r['from'] in context_ids}
            # Explicit parent-to-context relations apply to each child in that category parent.
            for parent in removed:
                if intersection(parent['box'],b['box'])/area(b['box'])>=.97:
                    required|={r['to'] for r in relations if r['from']==parent['id'] and r['to'] in context_ids}
            if b['class']==4:b['required_context_ids']=sorted(required)
        digest=sha(path)
        if digest in seen:
            rejected.append({'id':identifier,'reason':'byte_duplicate','other':seen[digest]['id']})
            seen[digest].setdefault('duplicate_papers',[]).append(paper);continue
        row={'id':identifier,'image':str(path.relative_to(root)),'sha256':digest,'width':w,'height':h,
             'paper':paper,'domain':publications[paper]['pattern_name'],'boxes':selected,'relations':relations,
             'parent_boxes_removed':removed,'review':'upstream_manual_annotation; not independent local human review',
             'annotation_id':annotation['id'],'annotation_updated':annotation['updated_at'],
             'annotation_sha256':hashlib.sha256(json.dumps(annotation,sort_keys=True).encode()).hexdigest(),
             'source':'TobiPoni/CompoundFigureSeparation; SCI-3000 images','phash':phash(image)}
        rows.append(row);seen[digest]=row
    if args.single_source:
        singles=args.single_source.resolve()
        labels=json.loads((singles/'single_labels.json').read_text())
        for name,label in sorted(labels.items()):
            path=(singles/name).resolve();identifier=path.stem;paper=identifier.split('-')[0]
            if not path.is_relative_to(singles) or not re.fullmatch(r'[a-f0-9]{32}',paper):raise ValueError('Unsafe single image')
            if label not in ('Chart','Image','Illustration','Table','Other') or paper not in publications:raise ValueError('Unknown single source')
            image=Image.open(path).convert('RGB');w,h=image.size;digest=sha(path)
            if digest in seen:
                rejected.append({'id':identifier,'reason':'single_duplicate','other':seen[digest]['id']})
                seen[digest].setdefault('duplicate_papers',[]).append(paper);continue
            row={'id':identifier,'image':str(path.relative_to(root)),'sha256':digest,'width':w,'height':h,
                 'paper':paper,'domain':publications[paper]['pattern_name'],
                 'boxes':[{'id':'single','class':4,'source_class':label,'box':[0.,0.,float(w),float(h)],
                           'origin':'upstream_curated_single_figure','required_context_ids':[]}],
                 'relations':[],'parent_boxes_removed':[],
                 'review':'upstream single-figure classification; 24-image sample visually reviewed by Codex, not all independently reviewed',
                 'annotation_sha256':hashlib.sha256((name+':'+label).encode()).hexdigest(),
                 'source':'TobiPoni/CompoundFigureSeparation SCI-3000-Singles','phash':phash(image)}
            rows.append(row);seen[digest]=row
    parents={r['paper']:r['paper'] for r in rows}
    def find(a):
        parents.setdefault(a,a)
        while parents[a]!=a:parents[a]=parents[parents[a]];a=parents[a]
        return a
    def join(a,b):
        a,b=find(a),find(b);parents[max(a,b)]=min(a,b)
    authors={}
    for row in rows:
        paper=row['paper'];aa=publications[paper]['author'] or []
        for author in (aa[:1]+aa[-1:]):
            key=author.get('orcid_id') or re.sub(r'\W+',' ',author['name'].lower()).strip()
            if len(key)<7:continue
            if key in authors:join(paper,authors[key])
            else:authors[key]=paper
        for other in row.get('duplicate_papers',[]):join(paper,other)
    near=[]
    for i,a in enumerate(rows):
        for b in rows[:i]:
            if a['paper']==b['paper']:continue
            if abs((a['width']/a['height'])/(b['width']/b['height'])-1)<=.08 and (a['phash']^b['phash']).bit_count()<=4:
                join(a['paper'],b['paper']);near.append([a['id'],b['id']])
    previous={s:[json.loads(x) for x in (args.previous/f'{s}.jsonl').read_text().splitlines()] for s in ('train','validation','test')}
    exposed_train={find(x['paper']) for x in previous['train']};exposed_val={find(x['paper']) for x in previous['validation']}
    old_test={find(x['paper']) for x in previous['test']}
    for row in rows:
        group=find(row['paper']);bucket=int(hashlib.sha256(('gradstep-panels-v2:'+group).encode()).hexdigest()[:8],16)%100
        if group in exposed_train:split='train'
        elif group in exposed_val:split='validation'
        elif group in old_test:split='test'
        else:split='train' if bucket<65 else 'validation' if bucket<83 else 'test'
        row.update(group=group,split=split,phash=f"{row['phash']:016x}")
    args.out.mkdir(parents=True)
    manifest={'version':3 if args.single_source else 2,'classes':CLASSES,'source_revision':REVISION,'distribution_allowed':False,
        'source_annotations_sha256':sha(source/'label-studio_export/real_labels.json'),
        'source_images_download_manifest_sha256':sha(source/'download-manifest.json'),
        'publication_metadata_sha256':sha(args.metadata),'annotation_license_declared':'MIT',
        'source_archive_license':'CC BY-SA 4.0 in actual archive LICENSE; Zenodo landing metadata instead says CC BY 4.0',
        'article_image_rights':'article verification pending; do not distribute weights yet',
        'previous_pilot_manifest_sha256':sha(args.previous/'manifest.json'),
        'split_method':'paper + first/last author + byte/perceptual duplicates; prior pilot exposure preserved',
        'near_duplicate_pairs':near,'script_sha256':sha(__file__),'files':{},'counts':{}}
    if args.single_source:manifest['single_labels_sha256']=sha(args.single_source/'single_labels.json')
    for split in ('train','validation','test'):
        selected=sorted([r for r in rows if r['split']==split],key=lambda r:r['id'])
        if not selected:raise ValueError('Empty split')
        path=args.out/f'{split}.jsonl';path.write_text(''.join(json.dumps(r,sort_keys=True)+'\n' for r in selected))
        manifest['files'][path.name]=sha(path)
        manifest['counts'][split]={'images':len(selected),'papers':len({r['paper'] for r in selected}),
            'families':len({r['group'] for r in selected}),'domains':dict(collections.Counter(r['domain'] for r in selected)),
            'boxes':dict(collections.Counter(CLASSES[b['class']] for r in selected for b in r['boxes'])),
            'compound_images':sum(sum(b['class']==4 for b in r['boxes'])>1 for r in selected),
            'explicit_panel_context_links':sum(len(b.get('required_context_ids',[])) for r in selected for b in r['boxes'])}
    (args.out/'rejections.json').write_text(json.dumps(rejected,indent=2)+'\n')
    (args.out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    selected_papers={r['paper'] for r in rows}
    (args.out/'attribution.json').write_text(json.dumps({k:v for k,v in publications.items() if k in selected_papers},indent=2)+'\n')
    print(json.dumps({'counts':manifest['counts'],'rejected':len(rejected)},indent=2))


if __name__=='__main__':main()
