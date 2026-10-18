#!/usr/bin/env python3
"""Local, unpaid panel-detector experiment; not imported by the application or routine tests.

Requires torch and ultralytics in a disposable environment. The pinned research weights are
AGPL-3.0, not bundled with Gradstep. Run against verified, already-local reader assets only.
"""
import argparse, hashlib, importlib, json, pathlib, time
import torch
from PIL import Image, ImageDraw

parser = argparse.ArgumentParser()
parser.add_argument('--weights', required=True)
parser.add_argument('--bundle', required=True)
parser.add_argument('--out', required=True)
parser.add_argument('--export-coreml',action='store_true')
parser.add_argument('--coreml',action='store_true',help='Run the exported Core ML package on this Mac')
parser.add_argument('--square',action='store_true',help='Use the same fixed square letterbox as the exported Core ML model')
parser.add_argument('--size',type=int,default=1024,choices=[640,1024,1280])
args = parser.parse_args()
weights = pathlib.Path(args.weights)
digest = hashlib.sha256(weights.read_bytes()).hexdigest()
if digest != '3220e816bd0be353deea196c8b6069e6a83d82fbc42efc0b3f35568f1a5a24b5':
    raise ValueError('Unreviewed weights')
# Only the reviewed tensor/module classes; never arbitrary globals from an untrusted checkpoint.
allowed = '''ultralytics.nn.modules.head.Detect ultralytics.nn.modules.block.A2C2f
torch.nn.modules.conv.Conv2d ultralytics.nn.modules.conv.DWConv ultralytics.nn.modules.block.AAttn
torch.nn.modules.activation.SiLU ultralytics.nn.modules.block.DFL ultralytics.nn.modules.block.ABlock
ultralytics.nn.tasks.DetectionModel torch.nn.modules.linear.Identity ultralytics.nn.modules.conv.Conv
ultralytics.nn.modules.block.C3k2 ultralytics.nn.modules.conv.Concat ultralytics.nn.modules.block.Bottleneck
ultralytics.nn.modules.block.C3k torch.nn.modules.batchnorm.BatchNorm2d torch.nn.modules.upsampling.Upsample
torch.nn.modules.container.ModuleList torch.nn.modules.container.Sequential'''.split()
unknown = set(torch.serialization.get_unsafe_globals_in_checkpoint(weights)) - set(allowed)
if unknown: raise ValueError(f'Unreviewed checkpoint globals: {unknown}')
torch.serialization.add_safe_globals([getattr(importlib.import_module(p.rsplit('.',1)[0]), p.rsplit('.',1)[1]) for p in allowed])
load = torch.load
def restricted_load(*args, **kwargs):
    kwargs['weights_only'] = True
    return load(*args, **kwargs)
torch.load = restricted_load
from ultralytics import YOLO
torch.set_num_threads(4)
model = YOLO(str(weights.with_suffix('.mlpackage') if args.coreml else weights), task='detect')
if args.export_coreml:
    print(model.export(format='coreml',imgsz=640,nms=True,quantize=16),flush=True)
    raise SystemExit(0)
root, out = pathlib.Path(args.bundle), pathlib.Path(args.out)
out.mkdir(parents=True, exist_ok=True)
index = json.loads((root/'reader.json').read_text())
report = {'model':'mermermer/figpanel-yolov12', 'weights_sha256':digest,
          'device':'Mac Core ML (default compute units)' if args.coreml else 'Mac CPU, 4 torch threads',
          'license':'AGPL-3.0; research only','input_size':args.size, 'square_letterbox':args.square or args.coreml, 'images':[]}
for figure in index['figures']:
    for asset in figure['asset_paths']:
        path = root/asset
        if not path.resolve().is_relative_to(root.resolve()): raise ValueError('Invalid asset path')
        image = Image.open(path).convert('RGB')
        start = time.perf_counter()
        result = model.predict(image, imgsz=args.size, rect=not(args.square or args.coreml), conf=0.25, device='cpu', verbose=False)[0]
        elapsed = 1000*(time.perf_counter()-start)
        boxes=[]
        for box in result.boxes:
            x1,y1,x2,y2=box.xyxy[0].tolist()
            boxes.append({'kind':result.names[int(box.cls)], 'confidence':float(box.conf),
                          'x':x1/image.width,'y':y1/image.height,'w':(x2-x1)/image.width,'h':(y2-y1)/image.height})
        row={'id':figure['id'],'caption':figure['caption'],'image_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
             'width':image.width,'height':image.height,'milliseconds':round(elapsed,1),'boxes':boxes}
        report['images'].append(row)
        drawing=ImageDraw.Draw(image)
        for i,b in enumerate(boxes):
            x,y,w,h=b['x']*image.width,b['y']*image.height,b['w']*image.width,b['h']*image.height
            drawing.rectangle([x,y,x+w,y+h],outline='red' if b['kind']=='subplot' else 'blue',width=3)
            drawing.text((x+4,y+4),f"{i+1}: {b['kind']} {b['confidence']:.2f}", fill='red')
        image.save(out/(figure['id']+'.png'))
        print(row['id'], f'{elapsed:.0f}ms', [(b['kind'],round(b['confidence'],2)) for b in boxes],flush=True)
(out/'results.json').write_text(json.dumps(report,indent=2)+'\n')
