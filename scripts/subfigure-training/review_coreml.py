#!/usr/bin/env python3
"""Render preserved, image-bound Core ML predictions without new inference."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image,ImageDraw


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--report',type=Path,required=True);p.add_argument('--bundle',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True);p.add_argument('--threshold',type=float,default=.7)
    args=p.parse_args();report=json.loads(args.report.read_text())
    index=json.loads((args.bundle/'reader.json').read_text());assets={}
    for figure in index['figures']:
        for asset in figure['asset_paths']:
            path=(args.bundle/asset).resolve()
            if not path.is_relative_to(args.bundle.resolve()):raise ValueError('Asset outside bundle')
            assets[hashlib.sha256(path.read_bytes()).hexdigest()]=path
    rows=[];tiles=[]
    for row in report['images']:
        identifier=row['id']
        if Path(identifier).name!=identifier:raise ValueError('Unsafe saved image identity')
        path=assets[row['image_sha256']];im=Image.open(path).convert('RGB');w,h=im.size
        if list(im.size)!=row['size']:raise ValueError('Image dimensions changed')
        with np.load(args.report.parent/(identifier+'.npz'),allow_pickle=False) as data:
            scores=1/(1+np.exp(-np.clip(data['coreml_logits'][0],-80,80)))
            boxes=data['coreml_boxes'][0]
        left,top,rw,rh=row['letterbox'];pred=[]
        for probabilities,box in zip(scores,boxes):
            cls=int(probabilities.argmax());score=float(probabilities[cls])
            if score<args.threshold:continue
            cx,cy,bw,bh=box*640
            raw=[max(0.,float((cx-bw/2-left)/(rw/w))),max(0.,float((cy-bh/2-top)/(rh/h))),
                 min(float(w),float((cx+bw/2-left)/(rw/w))),min(float(h),float((cy+bh/2-top)/(rh/h)))]
            if raw[2]<=raw[0] or raw[3]<=raw[1]:continue
            pred.append({'class':cls,'score':score,'box':raw})
        im.thumbnail((708,650));sx,sy=im.width/w,im.height/h;draw=ImageDraw.Draw(im)
        for b in pred:
            x0,y0,x1,y1=b['box'];rectangle=[x0*sx,y0*sy,x1*sx,y1*sy]
            color='red' if b['class']==4 else 'blue';draw.rectangle(rectangle,outline=color,width=2)
            draw.text((rectangle[0]+2,max(0,rectangle[1]-12)),f'{b["class"]}: {b["score"]:.2f}',fill=color,stroke_width=1,stroke_fill='white')
        tile=Image.new('RGB',(720,720),'#eeeeee');tile.paste(im,(6,55));d=ImageDraw.Draw(tile)
        d.text((6,6),identifier,fill='black');d.text((6,24),'Saved Core ML output; red panels, blue context; no ground truth',fill='black')
        tiles.append(tile);rows.append({**row,'predictions':pred,'threshold':args.threshold})
    sheet=Image.new('RGB',(1440,720*((len(tiles)+1)//2)),'#eeeeee')
    for i,tile in enumerate(tiles):sheet.paste(tile,((i%2)*720,(i//2)*720))
    args.out.parent.mkdir(parents=True,exist_ok=True);sheet.save(args.out)
    args.out.with_suffix('.json').write_text(json.dumps({'report_sha256':hashlib.sha256(args.report.read_bytes()).hexdigest(),
        'images':rows,'quality_qualified':False},indent=2)+'\n')


if __name__=='__main__':main()
