#!/usr/bin/env python3
"""Local VLM judge (Qwen2.5-VL-7B-Instruct, Apache-2.0) for discrete figure decisions — never coordinates.

Input: JSONL of queries {qid, type, image (path), marks: [{box, color, label}], prompt, answers: [allowed],
truth (optional)}. Boxes are drawn on a copy of the image (thick outlines + label tags); the model answers with
one of the allowed words. Output: JSONL with the parsed answer, raw text and seconds. Greedy decoding.
"""
import argparse, json, time
from pathlib import Path

import torch
from PIL import Image, ImageDraw, ImageFont

COLORS = {'red': (230, 0, 0), 'blue': (0, 80, 255), 'green': (0, 160, 0), 'orange': (255, 140, 0), 'purple': (150, 0, 200),
          'teal': (0, 150, 150), 'magenta': (220, 0, 180), 'brown': (140, 80, 20)}


def font(size):
    try:
        return ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', size)
    except OSError:
        return ImageFont.load_default()


def draw(path, marks, max_side=1280):
    im = Image.open(path).convert('RGB')
    s = min(1.0, max_side / max(im.size))
    if s < 1:
        im = im.resize((int(im.width * s), int(im.height * s)), Image.Resampling.LANCZOS)
    d = ImageDraw.Draw(im)
    w = max(3, int(0.004 * max(im.size)))
    f = font(max(14, int(0.025 * max(im.size))))
    for m in marks:
        x0, y0, x1, y1 = [v * s for v in m['box']]
        col = COLORS.get(m.get('color', 'red'), (230, 0, 0))
        d.rectangle([x0, y0, x1, y1], outline=col, width=w)
        if m.get('label'):
            tb = d.textbbox((x0 + w, y0 + w), m['label'], font=f)
            d.rectangle(tb, fill=col)
            d.text((x0 + w, y0 + w), m['label'], fill=(255, 255, 255), font=f)
    return im


def parse(text, allowed):
    t = text.strip().upper()
    for a in allowed:
        if t.startswith(a.upper()):
            return a
    for a in allowed:
        if a.upper() in t:
            return a
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', type=Path, required=True)
    ap.add_argument('--queries', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--batch', type=int, default=8)
    ap.add_argument('--max-pixels', type=int, default=1003520)  # 1280 * 28 * 28
    args = ap.parse_args()
    from transformers import AutoProcessor, Qwen2_5_VLForConditionalGeneration
    model = Qwen2_5_VLForConditionalGeneration.from_pretrained(str(args.model), torch_dtype=torch.bfloat16,
                                                               attn_implementation='sdpa', device_map='cuda').eval()
    proc = AutoProcessor.from_pretrained(str(args.model), min_pixels=256 * 28 * 28, max_pixels=args.max_pixels)
    proc.tokenizer.padding_side = 'left'
    qs = [json.loads(l) for l in args.queries.read_text().splitlines() if l.strip()]
    done = set()
    if args.out.exists():
        done = {json.loads(l)['qid'] for l in args.out.read_text().splitlines() if l.strip()}
    qs = [q for q in qs if q['qid'] not in done]
    t_all = time.time()
    with args.out.open('a') as fo:
        for b in range(0, len(qs), args.batch):
            chunk = qs[b:b + args.batch]
            imgs = [draw(q['image'], q.get('marks', [])) for q in chunk]
            texts = []
            for q in chunk:
                msg = [{'role': 'user', 'content': [{'type': 'image'}, {'type': 'text', 'text': q['prompt'] +
                        f"\nAnswer with exactly one word: {' or '.join(q['answers'])}."}]}]
                texts.append(proc.apply_chat_template(msg, tokenize=False, add_generation_prompt=True))
            inputs = proc(text=texts, images=imgs, padding=True, return_tensors='pt').to('cuda')
            t0 = time.time()
            with torch.inference_mode():
                out = model.generate(**inputs, max_new_tokens=6, do_sample=False)
            dt = (time.time() - t0) / len(chunk)
            gen = proc.batch_decode(out[:, inputs['input_ids'].shape[1]:], skip_special_tokens=True)
            for q, g in zip(chunk, gen):
                fo.write(json.dumps({'qid': q['qid'], 'type': q['type'], 'answer': parse(g, q['answers']), 'raw': g[:40],
                                     'truth': q.get('truth'), 'seconds': dt}) + '\n')
            fo.flush()
    print('queries', len(qs), 'seconds', round(time.time() - t_all, 1))


if __name__ == '__main__':
    main()
