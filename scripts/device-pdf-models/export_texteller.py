"""Core ML exports of the device route's formula recogniser (TexTeller, ViT encoder + TrOCR decoder) for the app
(docs/architecture/DEVICE_PDF_ROUTE.md, docs/reviews/DEVICE_PDF_ROUTE_20261021.md).

The first export (the desktop's `texteller-ft-v4-coreml-int8`, port kit 0.1.0) decodes one crop at a time: a step
costs about 8.7 ms on an M1 Max GPU whatever the work, so the recogniser is mostly per-step overhead. These exports
add a batch dimension so B crops share every encoder pass and every decoder step:

- `encoder.mlpackage`: pixel_values [B, 1, 448, 448] float32 -> cross_k, cross_v [L, B, H, S, hd] float16.
- `decoder-step.mlpackage`: token [B, 1] int32, position [1] int32 (the crops of a batch step together),
  cross_k, cross_v [L, B, H, S, hd] (float32 by default: the first export's fast form) -> logits [B, V];
  state self_k, self_v [L, B, H, max_len, hd] float16.

The decoder re-implements the TrOCR step as the desktop's export does (fixed cache, one-hot slot update) and is checked
token for token against transformers' greedy decoding before conversion. Weights are int8 per output channel like the
shipped export (`--int8`). Runs on macOS or Linux (prediction needs macOS):

    ~/gradstep-mac/export-venv/bin/python scripts/device-pdf-models/export_texteller.py \
        --model ~/gradstep-mac/texteller-ft-v4 --out ~/gradstep-mac/texteller-ft-v4-b8-int8 --batch 8 --int8
"""

from __future__ import annotations

import argparse
import json
import math
import time
from pathlib import Path

import numpy as np
import torch
from torch import nn


class Encoder(nn.Module):
    def __init__(self, model, batch: int) -> None:  # type: ignore[no-untyped-def]
        super().__init__()
        self.batch = batch  # a constant, so every reshape in the trace is static
        self.encoder = model.encoder
        self.enc_to_dec = getattr(model, "enc_to_dec_proj", None)
        layers = model.decoder.model.decoder.layers
        self.k_proj = nn.ModuleList([layer.encoder_attn.k_proj for layer in layers])
        self.v_proj = nn.ModuleList([layer.encoder_attn.v_proj for layer in layers])
        self.heads = layers[0].encoder_attn.num_heads
        self.head_dim = layers[0].encoder_attn.head_dim
        cfg = model.encoder.config
        self.seq = (cfg.image_size // cfg.patch_size) ** 2 + 1

    def forward(self, pixel_values: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        b = self.batch
        h = self.encoder(pixel_values=pixel_values).last_hidden_state  # [B, S, 768]
        if self.enc_to_dec is not None:
            h = self.enc_to_dec(h)
        s = self.seq
        ks = [k(h).view(b, s, self.heads, self.head_dim).transpose(1, 2) for k in self.k_proj]
        vs = [v(h).view(b, s, self.heads, self.head_dim).transpose(1, 2) for v in self.v_proj]
        return torch.stack(ks), torch.stack(vs)  # [L, B, H, S, hd]


class DecoderStep(nn.Module):
    def __init__(self, model, max_len: int, batch: int) -> None:  # type: ignore[no-untyped-def]
        super().__init__()
        dec = model.decoder.model.decoder
        cfg = model.decoder.config
        self.layers = dec.layers
        self.embed_tokens = dec.embed_tokens
        self.embed_positions = dec.embed_positions
        self.offset = int(getattr(dec.embed_positions, "offset", 2))
        self.layernorm_embedding = dec.layernorm_embedding
        self.embed_scale = math.sqrt(cfg.d_model) if cfg.scale_embedding else 1.0
        self.output_projection = model.decoder.output_projection
        self.heads = cfg.decoder_attention_heads
        self.head_dim = cfg.d_model // cfg.decoder_attention_heads
        self.scaling = self.head_dim**-0.5
        self.max_len = max_len
        self.batch = batch
        self.act = nn.GELU() if cfg.activation_function == "gelu" else nn.ReLU()
        n = len(self.layers)
        self.register_buffer("self_k", torch.zeros(n, batch, self.heads, max_len, self.head_dim))
        self.register_buffer("self_v", torch.zeros(n, batch, self.heads, max_len, self.head_dim))

    def forward(self, token: torch.Tensor, position: torch.Tensor, cross_k: torch.Tensor, cross_v: torch.Tensor) -> torch.Tensor:
        b, H, hd, T = self.batch, self.heads, self.head_dim, self.max_len
        pos = position.to(torch.long)
        x = self.embed_tokens(token.to(torch.long)) * self.embed_scale  # [B, 1, D]
        x = x + self.embed_positions.weight[pos + self.offset].unsqueeze(0)
        x = self.layernorm_embedding(x)
        idx = torch.arange(T, device=x.device)
        slot = (idx == pos).view(1, 1, T, 1)
        causal = torch.where(idx <= pos, 0.0, float("-inf")).view(1, 1, 1, T)
        for i, layer in enumerate(self.layers):
            attn = layer.self_attn
            q = (attn.q_proj(x) * self.scaling).view(b, 1, H, hd).transpose(1, 2)  # [B, H, 1, hd]
            k = attn.k_proj(x).view(b, 1, H, hd).transpose(1, 2)
            v = attn.v_proj(x).view(b, 1, H, hd).transpose(1, 2)
            k_cache = torch.where(slot, k.expand(b, H, T, hd), self.self_k[i])
            v_cache = torch.where(slot, v.expand(b, H, T, hd), self.self_v[i])
            self.self_k[i] = k_cache
            self.self_v[i] = v_cache
            a = torch.softmax(torch.matmul(q, k_cache.transpose(-1, -2)) + causal, dim=-1)
            h = torch.matmul(a, v_cache).transpose(1, 2).reshape(b, 1, -1)
            x = layer.self_attn_layer_norm(x + attn.out_proj(h))
            xa = layer.encoder_attn
            q = (xa.q_proj(x) * self.scaling).view(b, 1, H, hd).transpose(1, 2)
            a = torch.softmax(torch.matmul(q, cross_k[i].transpose(-1, -2)), dim=-1)
            h = torch.matmul(a, cross_v[i]).transpose(1, 2).reshape(b, 1, -1)
            x = layer.encoder_attn_layer_norm(x + xa.out_proj(h))
            x = layer.final_layer_norm(x + layer.fc2(self.act(layer.fc1(x))))
        return self.output_projection(x)[:, 0, :]


class StatefulStep(DecoderStep):
    """Protocol "multifunction", function `step`: the cross-attention keys and values live in state, written once per
    batch by the `prefill` function of the same package (a state made by one function serves the other)."""

    def __init__(self, model, max_len: int, batch: int, seq: int) -> None:  # type: ignore[no-untyped-def]
        super().__init__(model, max_len, batch)
        n = len(self.layers)
        self.register_buffer("cross_k", torch.zeros(n, batch, self.heads, seq, self.head_dim))
        self.register_buffer("cross_v", torch.zeros(n, batch, self.heads, seq, self.head_dim))

    def forward(self, token: torch.Tensor, position: torch.Tensor) -> torch.Tensor:  # type: ignore[override]
        return super().forward(token, position, self.cross_k, self.cross_v)


class Prefill(nn.Module):
    """Protocol "multifunction", function `prefill`: the batch's pixels through the encoder into the cross state (and a
    clean self-attention cache). Fixed shapes in both functions, so Core ML never re-specialises between calls."""

    def __init__(self, enc: Encoder, step: StatefulStep) -> None:
        super().__init__()
        self.enc = enc
        for name in ("self_k", "self_v", "cross_k", "cross_v"):
            self.register_buffer(name, torch.zeros_like(getattr(step, name)))

    def forward(self, pixel_values: torch.Tensor) -> torch.Tensor:
        k, v = self.enc(pixel_values)
        self.cross_k[:] = k
        self.cross_v[:] = v
        self.self_k[:] = self.self_k * 0.0
        self.self_v[:] = self.self_v * 0.0
        return k[0, :, 0, 0, 0:1]  # [B, 1]: a function needs an output


def load(model_dir: Path):  # type: ignore[no-untyped-def]
    from transformers import RobertaTokenizerFast, VisionEncoderDecoderModel

    model = VisionEncoderDecoderModel.from_pretrained(str(model_dir), attn_implementation="eager").eval()
    return model, RobertaTokenizerFast.from_pretrained(str(model_dir))


@torch.no_grad()
def greedy_batch(enc: Encoder, step: DecoderStep, pixels: torch.Tensor, bos: int, eos: int, max_new: int) -> list[list[int]]:
    ck, cv = enc(pixels)
    step.self_k.zero_(); step.self_v.zero_()
    b = pixels.shape[0]
    ids = [[bos] for _ in range(b)]
    done = [False] * b
    for t in range(max_new):
        logits = step(torch.tensor([[r[-1]] for r in ids], dtype=torch.int32), torch.tensor([t], dtype=torch.int32), ck, cv)
        nxt = logits.argmax(-1).tolist()
        for i in range(b):
            if not done[i]:
                ids[i].append(int(nxt[i])); done[i] = nxt[i] == eos
        if all(done):
            break
    return ids


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--max-len", type=int, default=256)
    ap.add_argument("--cross-dtype", choices=["float32", "float16"], default="float32")
    ap.add_argument("--int8", action="store_true")
    ap.add_argument("--samples", type=Path, help="the first export's directory (samples/*.npy and export.json token ids) for the equivalence check")
    ap.add_argument("--skip-encoder", action="store_true")
    ap.add_argument("--protocol", choices=["cross-input", "multifunction"], default="cross-input")
    args = ap.parse_args()
    import coremltools as ct

    model, tok = load(args.model)
    B, max_len = args.batch, args.max_len
    enc, step = Encoder(model, B).eval(), DecoderStep(model, max_len, B).eval()
    # The re-implementation against transformers on the first export's sample crops, batched as the app will batch them.
    check = None
    if args.samples:
        meta = json.loads((args.samples / "export.json").read_text())
        samples = meta["equivalence"]["samples"]
        agree = 0
        for i in range(0, len(samples), B):
            group = samples[i : i + B]
            px = torch.zeros(B, 1, 448, 448)
            for j, s in enumerate(group):
                px[j] = torch.from_numpy(np.load(args.samples / "samples" / s["file"]).astype(np.float32))
            out = greedy_batch(enc, step, px, tok.bos_token_id, tok.eos_token_id, max_len - 1)
            agree += sum(out[j] == s["ids"] for j, s in enumerate(group))
        check = {"n": len(samples), "agree": agree}
        print(f"PyTorch batched re-implementation vs recorded ids: {agree}/{len(samples)}")
    args.out.mkdir(parents=True, exist_ok=True)
    common = dict(convert_to="mlprogram", compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.iOS18)
    pixels = torch.zeros(B, 1, 448, 448)
    t0 = time.monotonic()
    if args.protocol == "multifunction":
        export_multifunction(args, model, tok, enc, common, check, t0)
        return
    with torch.no_grad():
        ck, cv = enc(pixels)
        if not args.skip_encoder:
            traced_enc = torch.jit.trace(enc, pixels)
        traced_step = torch.jit.trace(step, (torch.zeros(B, 1, dtype=torch.int32), torch.zeros(1, dtype=torch.int32), ck, cv))
    cross_dtype = np.float32 if args.cross_dtype == "float32" else np.float16
    packages = {}
    if not args.skip_encoder:
        packages["encoder"] = ct.convert(traced_enc, inputs=[ct.TensorType(name="pixel_values", shape=pixels.shape, dtype=np.float32)],
                                         outputs=[ct.TensorType(name="cross_k", dtype=np.float16), ct.TensorType(name="cross_v", dtype=np.float16)], **common)
    cache = tuple(step.self_k.shape)
    packages["decoder-step"] = ct.convert(
        traced_step,
        inputs=[ct.TensorType(name="token", shape=(B, 1), dtype=np.int32), ct.TensorType(name="position", shape=(1,), dtype=np.int32),
                ct.TensorType(name="cross_k", shape=tuple(ck.shape), dtype=cross_dtype), ct.TensorType(name="cross_v", shape=tuple(cv.shape), dtype=cross_dtype)],
        outputs=[ct.TensorType(name="logits")],
        states=[ct.StateType(wrapped_type=ct.TensorType(shape=cache, dtype=np.float16), name="self_k"),
                ct.StateType(wrapped_type=ct.TensorType(shape=cache, dtype=np.float16), name="self_v")],
        **common)
    for name, m in packages.items():
        if args.int8:
            from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
            m = linear_quantize_weights(m, OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric", granularity="per_channel")))
        m.save(str(args.out / f"{name}.mlpackage"))
    tok.save_pretrained(str(args.out / "tokenizer"))
    meta = {"model_dir": str(args.model), "batch": B, "max_len": max_len, "image_size": 448, "bos": tok.bos_token_id, "eos": tok.eos_token_id,
            "cross_shape": list(ck.shape), "cache_shape": list(cache), "cross_dtype": args.cross_dtype, "int8": args.int8,
            "protocol": "batched-cross-input", "conversion_seconds": round(time.monotonic() - t0, 1), "equivalence": check,
            "calls": "encoder: pixel_values [B,1,448,448] -> cross_k, cross_v [L,B,H,S,hd] fp16; decoder: state = make_state(); each step token [B,1], position [t], cross_k, cross_v; rows past their end token are ignored"}
    (args.out / "export.json").write_text(json.dumps(meta, indent=1))
    print(json.dumps(meta, indent=1))


@torch.no_grad()
def greedy_stateful(prefill: Prefill, step: StatefulStep, pixels: torch.Tensor, bos: int, eos: int, max_new: int) -> list[list[int]]:
    """Greedy decoding the way the app calls the multifunction package (the two modules share their buffers here)."""
    prefill(pixels)
    for name in ("self_k", "self_v", "cross_k", "cross_v"):
        getattr(step, name).copy_(getattr(prefill, name))
    b = pixels.shape[0]
    ids, done = [[bos] for _ in range(b)], [False] * b
    for t in range(max_new):
        nxt = step(torch.tensor([[r[-1]] for r in ids], dtype=torch.int32), torch.tensor([t], dtype=torch.int32)).argmax(-1).tolist()
        for i in range(b):
            if not done[i]:
                ids[i].append(int(nxt[i])); done[i] = nxt[i] == eos
        if all(done):
            break
    return ids


def export_multifunction(args, model, tok, enc: Encoder, common: dict, check, t0: float) -> None:  # type: ignore[no-untyped-def]
    """One package, `recogniser.mlpackage`, with two functions sharing one state (self_k, self_v, cross_k, cross_v):
    `prefill` (pixel_values [B,1,448,448] float32 -> the cross state, a clean cache) and `step` (token [B,1] int32,
    position [1] int32 -> logits [B,V])."""
    import coremltools as ct

    B, max_len = args.batch, args.max_len
    step = StatefulStep(model, max_len, B, enc.seq).eval()
    prefill = Prefill(enc, step).eval()
    if args.samples:
        meta = json.loads((args.samples / "export.json").read_text())
        samples = meta["equivalence"]["samples"]
        agree = 0
        for i in range(0, len(samples), B):
            group = samples[i : i + B]
            px = torch.zeros(B, 1, 448, 448)
            for j, s in enumerate(group):
                px[j] = torch.from_numpy(np.load(args.samples / "samples" / s["file"]).astype(np.float32))
            out = greedy_stateful(prefill, step, px, tok.bos_token_id, tok.eos_token_id, max_len - 1)
            agree += sum(out[j] == s["ids"] for j, s in enumerate(group))
        check = {"n": len(samples), "agree": agree}
        print(f"PyTorch multifunction re-implementation vs recorded ids: {agree}/{len(samples)}")
    pixels = torch.zeros(B, 1, 448, 448)
    with torch.no_grad():
        traced_prefill = torch.jit.trace(prefill, pixels)
        traced_step = torch.jit.trace(step, (torch.zeros(B, 1, dtype=torch.int32), torch.zeros(1, dtype=torch.int32)))
    states = [ct.StateType(wrapped_type=ct.TensorType(shape=tuple(getattr(step, n).shape), dtype=np.float16), name=n)
              for n in ("self_k", "self_v", "cross_k", "cross_v")]
    parts = {
        "prefill": ct.convert(traced_prefill, inputs=[ct.TensorType(name="pixel_values", shape=pixels.shape, dtype=np.float32)],
                              outputs=[ct.TensorType(name="ready")], states=states, **common),
        "step": ct.convert(traced_step, inputs=[ct.TensorType(name="token", shape=(B, 1), dtype=np.int32), ct.TensorType(name="position", shape=(1,), dtype=np.int32)],
                           outputs=[ct.TensorType(name="logits")], states=states, **common),
    }
    work = args.out / "parts"
    work.mkdir(exist_ok=True)
    desc = ct.utils.MultiFunctionDescriptor()
    for name, m in parts.items():
        if args.int8:
            from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
            m = linear_quantize_weights(m, OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric", granularity="per_channel")))
        m.save(str(work / f"{name}.mlpackage"))
        desc.add_function(str(work / f"{name}.mlpackage"), src_function_name="main", target_function_name=name)
    desc.default_function_name = "step"
    ct.utils.save_multifunction(desc, str(args.out / "recogniser.mlpackage"))
    import shutil
    shutil.rmtree(work)
    tok.save_pretrained(str(args.out / "tokenizer"))
    meta = {"model_dir": str(args.model), "batch": B, "max_len": max_len, "image_size": 448, "bos": tok.bos_token_id, "eos": tok.eos_token_id,
            "cache_shape": list(step.self_k.shape), "cross_shape": list(step.cross_k.shape), "int8": args.int8, "protocol": "multifunction",
            "conversion_seconds": round(time.monotonic() - t0, 1), "equivalence": check,
            "calls": "state = step.make_state(); prefill(pixel_values [B,1,448,448], state); each step: step(token [B,1], position [t], state) -> logits [B,V]; rows past their end token are ignored"}
    (args.out / "export.json").write_text(json.dumps(meta, indent=1))
    print(json.dumps(meta, indent=1))


if __name__ == "__main__":
    main()
