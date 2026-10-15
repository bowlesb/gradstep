"""Layout detections for a PDF with the exported Core ML detector, decoded as the reference does (per-class
thresholds, NMS 0.6 per class, best 300 by score; boxes 0.1 px, scores 4 dp like coreml_layout.detect)."""
import json, os, sys
import numpy as np, pypdfium2 as pdfium, coremltools as ct
from PIL import Image
pdf, out = sys.argv[1], sys.argv[2]
d = os.environ['LAYOUT_EXPORT']  # the layout-fcos-v5-coreml export directory
meta = json.load(open(d + '/export.json'))
model = ct.models.MLModel(d + '/layout.mlpackage', compute_units=ct.ComputeUnit.CPU_AND_NE)
classes, th, W, H = meta['classes'], meta['thresholds'], 1024, 1440
def nms(boxes, scores, iou):
    order = np.argsort(-scores, kind='stable'); keep = []
    while order.size:
        i = int(order[0]); keep.append(i); rest = order[1:]
        if not rest.size: break
        x0 = np.maximum(boxes[i, 0], boxes[rest, 0]); y0 = np.maximum(boxes[i, 1], boxes[rest, 1])
        x1 = np.minimum(boxes[i, 2], boxes[rest, 2]); y1 = np.minimum(boxes[i, 3], boxes[rest, 3])
        inter = np.clip(x1 - x0, 0, None) * np.clip(y1 - y0, 0, None)
        ai = (boxes[i, 2] - boxes[i, 0]) * (boxes[i, 3] - boxes[i, 1]); ar = (boxes[rest, 2] - boxes[rest, 0]) * (boxes[rest, 3] - boxes[rest, 1])
        order = rest[inter / (ai + ar - inter + 1e-9) <= iou]
    return keep
doc = pdfium.PdfDocument(pdf); pages = []
for p in range(len(doc)):
    img = doc[p].render(scale=150 / 72, draw_annots=False).to_pil().convert('RGB')
    s = min(W / img.width, H / img.height)
    canvas = Image.new('RGB', (W, H), (255, 255, 255)); canvas.paste(img.resize((max(1, round(img.width * s)), max(1, round(img.height * s))), Image.BILINEAR), (0, 0))
    o = model.predict({'image': canvas})
    boxes, scores = np.asarray(o['boxes'], dtype=np.float32), np.asarray(o['scores'], dtype=np.float32)
    found = []
    for ci, c in enumerate(classes):
        idx = np.nonzero(scores[:, ci] >= th[c])[0]
        if not idx.size: continue
        for k in nms(boxes[idx], scores[idx, ci], meta['nms_iou']):
            found.append({'cls': c, 'score': round(float(scores[idx[k], ci]), 4), 'box': [round(float(v), 1) for v in boxes[idx[k]]]})
    found.sort(key=lambda f: -f['score'])
    pw, ph = doc[p].get_size()
    pages.append({'width': pw, 'height': ph, 'image_width': img.width, 'image_height': img.height, 'scale': s, 'detections': found[:meta['max_detections']]})
    print(f'page {p}: {len(found)} detections', file=sys.stderr)
json.dump({'pages': pages}, open(out, 'w'))
