#!/usr/bin/env python3
"""Training-only copy/paste augmentation of real single figures and panel letters.

Sources come exclusively from the frozen real training split. Full image contents
are preserved. New panels contain their letter and complete image; this teaches
layout boundaries rather than tight boxes around the physical object in a photo.
All generated labels/relationships and underlying source rights remain explicit.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import shutil

import matplotlib
import numpy as np
from PIL import Image,ImageDraw,ImageFont


def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,required=True);p.add_argument('--real',type=Path,required=True)
    p.add_argument('--parent',type=Path,required=True);p.add_argument('--images',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True);p.add_argument('--count',type=int,default=384)
    p.add_argument('--seed',type=int,default=91073);args=p.parse_args()
    if args.out.exists() or args.images.exists():raise ValueError('Immutable output already exists')
    root=args.root.resolve();real_manifest=json.loads((args.real/'manifest.json').read_text())
    parent=json.loads((args.parent/'manifest.json').read_text())
    for directory,manifest in ((args.real,real_manifest),(args.parent,parent)):
        for name,digest in manifest['files'].items():
            if sha(directory/name)!=digest:raise ValueError('Changed source split')
    real=[json.loads(s) for s in (args.real/'train.jsonl').read_text().splitlines()]
    sources=[r for r in real if len(r['boxes'])==1 and r['boxes'][0].get('origin')=='upstream_curated_single_figure']
    byclass={c:[r for r in sources if r['boxes'][0]['source_class']==c] for c in ('Image','Illustration','Chart')}
    if any(not group for group in byclass.values()):raise ValueError('Missing real training source category')
    for r in sources:
        path=(root/r['image']).resolve()
        if not path.is_relative_to(root) or sha(path)!=r['sha256']:raise ValueError('Source image identity mismatch')
    font_path=Path(matplotlib.get_data_path())/'fonts/ttf/DejaVuSans.ttf'
    args.out.mkdir(parents=True);args.images.mkdir(parents=True)
    generated=[]
    for i in range(args.count):
        rng=np.random.default_rng(args.seed+i)
        nr,nc=[(1,2),(1,3),(2,2),(2,3),(3,1),(3,2)][i%6]
        cw=int(rng.integers(300,600));ch=int(rng.integers(300,600));gap=int(rng.integers(12,40))
        width=nc*cw+(nc+1)*gap;height=nr*ch+(nr+1)*gap
        canvas=Image.new('RGB',(width,height),'white');draw=ImageDraw.Draw(canvas)
        fontsize=int(rng.integers(22,43));font=ImageFont.truetype(str(font_path),fontsize)
        category=str(rng.choice(['Image','Illustration','Chart'],p=[.35,.35,.30]));candidates=byclass[category]
        chosen=rng.choice(len(candidates),size=nr*nc,replace=len(candidates)<nr*nc)
        boxes=[];provenance=[]
        for k,source_index in enumerate(chosen):
            source=candidates[int(source_index)];image=Image.open(root/source['image']).convert('RGB')
            if image.size!=(source['width'],source['height']):raise ValueError('Source dimensions changed')
            ox=gap+(k%nc)*(cw+gap);oy=gap+(k//nc)*(ch+gap)
            available_w=cw-20;available_h=ch-fontsize-24
            scale=min(available_w/image.width,available_h/image.height)
            rw=max(1,round(image.width*scale));rh=max(1,round(image.height*scale))
            # Some narrow photos intentionally have their letter in a wide left margin.
            x=ox+int((cw-rw)*(1. if i%3==0 else .5));y=oy+(12 if i%4==2 else fontsize+12)
            canvas.paste(image.resize((rw,rh),Image.Resampling.BILINEAR),(x,y))
            label=f'({chr(97+k)})';lx=ox+5;ly=oy+3
            if i%4==2:lx=x+rw/2;ly=y+rh+3
            label_box=draw.textbbox((lx,ly),label,font=font,anchor='mt' if i%4==2 else 'lt')
            if label_box[3]>height:raise ValueError('Generated panel letter clipped')
            draw.text((lx,ly),label,font=font,fill='black',anchor='mt' if i%4==2 else 'lt')
            box=[max(0.,float(min(x,label_box[0])-4)),max(0.,float(min(y,label_box[1])-4)),
                 min(float(width),float(max(x+rw,label_box[2])+4)),min(float(height),float(max(y+rh,label_box[3])+4))]
            boxes.append({'id':f'panel-{k}','class':4,'source_class':category,'box':box,
                          'origin':'programmatic_real_training_image_composite','required_context_ids':[],
                          'panel_letter_box':list(label_box)})
            provenance.append({'id':source['id'],'paper':source['paper'],'image':source['image'],
                               'sha256':source['sha256'],'original_size':[source['width'],source['height']],
                               'paste_rectangle':[x,y,x+rw,y+rh],'full_source_image_preserved':True})
        # Reject any accidental overlap between the complete panel rectangles.
        for k,a in enumerate(boxes):
            for b in boxes[:k]:
                aa,bb=a['box'],b['box']
                if min(aa[2],bb[2])>max(aa[0],bb[0]) and min(aa[3],bb[3])>max(aa[1],bb[1]):
                    raise ValueError(f'Generated panel overlap: {i}')
        identifier=f'composite-{args.seed}-{i:04d}';path=args.images/(identifier+'.png');canvas.save(path)
        generated.append({'id':identifier,'image':str(path.resolve().relative_to(root)),'sha256':sha(path),
            'width':width,'height':height,'paper':identifier,'group':'real-composite-training-only',
            'domain':'GeneratedComposite','boxes':boxes,'split':'train','source_images':provenance,
            'source':'project augmentation of real training singles; underlying image rights unchanged',
            'review':'programmatic geometry; not independent human annotation','seed':args.seed+i,
            'generator_sha256':sha(__file__)})
        if (i+1)%32==0:print(f'Generated {i+1}/{args.count}',flush=True)
    rows=[json.loads(s) for s in (args.parent/'train.jsonl').read_text().splitlines()]+generated
    (args.out/'train.jsonl').write_text(''.join(json.dumps(r,sort_keys=True)+'\n' for r in rows))
    for split in ('validation','test'):shutil.copyfile(args.parent/f'{split}.jsonl',args.out/f'{split}.jsonl')
    shutil.copyfile(args.parent/'attribution.json',args.out/'attribution.json')
    manifest=json.loads(json.dumps(parent));manifest.update(parent_manifest_sha256=sha(args.parent/'manifest.json'),
        composite_generator={'script_sha256':sha(__file__),'seed':args.seed,'count':args.count,
                             'font_sha256':sha(font_path),'real_training_manifest_sha256':sha(args.real/'manifest.json'),
                             'training_only':True,'held_out_real_splits_unchanged':True},
        files={f'{s}.jsonl':sha(args.out/f'{s}.jsonl') for s in ('train','validation','test')})
    counts=manifest['counts']['train'];counts.update(images=len(rows),generated_images=counts.get('generated_images',0)+len(generated),
        families=len({r['group'] for r in rows}),domains=dict(collections.Counter(r['domain'] for r in rows)),
        boxes=dict(collections.Counter(manifest['classes'][b['class']] for r in rows for b in r['boxes'])),
        compound_images=sum(sum(b['class']==4 for b in r['boxes'])>1 for r in rows),
        explicit_panel_context_links=sum(len(b.get('required_context_ids',[])) for r in rows for b in r['boxes']))
    counts['generated_boxes']=dict(collections.Counter(manifest['classes'][b['class']] for r in rows
        if r['domain'].startswith('Generated') for b in r['boxes']))
    (args.out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (args.out/'composite-generator-source.py').write_bytes(Path(__file__).read_bytes())
    print(json.dumps(manifest['composite_generator']))


if __name__=='__main__':main()
