"""Source-only contact sheets for reviewing proposed statistics spans (no model predictions)."""
import argparse,json,math,subprocess
from pathlib import Path
from PIL import Image,ImageDraw,ImageFont

p=argparse.ArgumentParser();p.add_argument('labels',type=Path);p.add_argument('out',type=Path)
p.add_argument('--include-prose',action='store_true',help='Render selected prose controls as well as positive source proposals.')
a=p.parse_args()
a.out.mkdir(parents=True,exist_ok=True)
rows=[r for r in map(json.loads,a.labels.read_text().splitlines()) if a.include_prose or r['proposed_spans']]
cache={}; font=ImageFont.truetype('/System/Library/Fonts/Menlo.ttc',12)
sheets=[]
for start in range(0,len(rows),12):
 canvas=Image.new('RGB',(1500,12*108),(245,245,245));draw=ImageDraw.Draw(canvas)
 for index,row in enumerate(rows[start:start+12]):
  key=(row['source'],row['page'])
  if key not in cache:
   name=a.out/(row['paper']+f'-p{row["page"]}')
   if not name.with_suffix('.png').exists():
    subprocess.run(['pdftoppm','-cropbox','-f',str(row['page']+1),'-l',str(row['page']+1),'-singlefile','-r','150','-png',row['source'],str(name)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   cache[key]=Image.open(name.with_suffix('.png')).convert('RGB')
  image=cache[key];scale=150/72
  x0,y0,x1,y1=row['box'];x0=max(0,x0-8);y0=max(0,y0-5);x1=min(image.width/scale,x1+8);y1=min(image.height/scale,y1+5)
  crop=image.crop(tuple(round(v*scale) for v in (x0,y0,x1,y1)))
  cd=ImageDraw.Draw(crop)
  for span in row['proposed_spans']:
   gs=row['glyphs'][span['from']:span['to']]
   box=[min(g['x0'] for g in gs),min(g['top'] for g in gs),max(g['x1'] for g in gs),max(g['bottom'] for g in gs)]
   cd.rectangle([(box[0]-x0)*scale,(box[1]-y0)*scale,(box[2]-x0)*scale,(box[3]-y0)*scale],outline=(150,30,150),width=1)
  if crop.width>1460:crop=crop.resize((1460,max(1,round(crop.height*1460/crop.width))))
  y=index*108
  draw.text((12,y+2),str(start+index)+' '+row['id'][:10]+' '+row['id'].split('-p')[-1],fill='black',font=font)
  canvas.paste(crop,(12,y+23))
  draw.text((12,y+83),' | '.join(s['text'] for s in row['proposed_spans']),fill='black',font=font)
 target=a.out/f'sheet-{start//12:02}.png';canvas.save(target);sheets.append(str(target))
(a.out/'review-index.json').write_text(json.dumps([{'index':i,'id':r['id'],'spans':r['proposed_spans']} for i,r in enumerate(rows)],indent=2)+'\n')
print(json.dumps({'sheets':sheets,'lines':len(rows)}))
