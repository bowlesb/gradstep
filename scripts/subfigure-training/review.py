#!/usr/bin/env python3
"""Render selected source annotations / predictions for visual review; never train on these images."""
import argparse
import json
from pathlib import Path
from PIL import Image, ImageDraw


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,required=True);p.add_argument('--data',type=Path,required=True)
    p.add_argument('--split',default='validation',choices=('train','validation','test'))
    p.add_argument('--predictions',type=Path);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--threshold',type=float,default=.6);p.add_argument('--start',type=int,default=0)
    p.add_argument('--count',type=int,default=6);p.add_argument('--ids',nargs='+')
    args=p.parse_args()
    rows=[json.loads(x) for x in (args.data/f'{args.split}.jsonl').read_text().splitlines()]
    if args.ids:rows=[r for r in rows if r['id'] in args.ids]
    rows=rows[args.start:args.start+args.count]
    preds={r['id']:r['predictions'] for r in json.loads(args.predictions.read_text())} if args.predictions else {}
    cell=720;sheet=Image.new('RGB',(cell*2,cell*((len(rows)+1)//2)),(230,230,230));draw=ImageDraw.Draw(sheet)
    selected=[]
    for i,row in enumerate(rows):
        im=Image.open(args.root/row['image']).convert('RGB');im.thumbnail((cell-12,cell-60))
        sx,sy=im.width/row['width'],im.height/row['height'];d=ImageDraw.Draw(im)
        for j,b in enumerate(row['boxes']):
            box=b['box'];scaled=[box[0]*sx,box[1]*sy,box[2]*sx,box[3]*sy]
            color='green' if b['class']==4 else 'blue';d.rectangle(scaled,outline=color,width=2)
            d.text((scaled[0]+2,scaled[1]+2),f"G{j}:{b['class']}",fill=color,stroke_width=1,stroke_fill='white')
        for b in preds.get(row['id'],[]):
            if b['score']<args.threshold:continue
            box=b['box'];scaled=[box[0]*sx,box[1]*sy,box[2]*sx,box[3]*sy]
            d.rectangle(scaled,outline='red',width=2)
            d.text((scaled[0]+2,max(0,scaled[1]-12)),f"P{b['class']}:{b['score']:.2f}",fill='red',stroke_width=1,stroke_fill='white')
        x=(i%2)*cell;y=(i//2)*cell;sheet.paste(im,(x+6,y+50))
        draw.text((x+5,y+4),row['id'],fill='black');draw.text((x+5,y+20),'Truth: green panel / blue context; predictions: red',fill='black')
        selected.append(row['id'])
    args.out.parent.mkdir(parents=True,exist_ok=True);sheet.save(args.out)
    args.out.with_suffix('.json').write_text(json.dumps({'split':args.split,'ids':selected,'threshold':args.threshold},indent=2)+'\n')


if __name__=='__main__':main()
