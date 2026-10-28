"""CPU-only, fixed-crop probe of a stateless TexTeller decoder that returns new cache entries.

This does not export Core ML, modify a model pack or qualify an encrypted release. The dense reference is the
continuous decoder from speed branch 0c34d1df; model weights, tokenizer and sample crops are explicit inputs.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import time
from pathlib import Path

import numpy as np
import torch
from torch import nn
from export_texteller import DecoderStep, Encoder, load


class ContinuousReference(DecoderStep):
    """Frozen dense-cache reference from speed branch 0c34d1df (CPU)."""
    def forward(self, token: torch.Tensor, position: torch.Tensor, cross_k: torch.Tensor, cross_v: torch.Tensor) -> torch.Tensor:
        b, H, hd, T = self.batch, self.heads, self.head_dim, self.max_len
        pos = position.to(torch.long)
        x = self.embed_tokens(token.to(torch.long)) * self.embed_scale  # [B, 1, D]
        idx = torch.arange(T, device=x.device)
        if pos.shape[0] == b and b > 1:
            # Protocol "continuous": every row at its own position (position [B]), so a row whose reading ended can take a
            # new crop while the others decode on. A row attends only to its own slots up to its position, so slots a
            # previous crop left behind are never read (each step writes the row's slot before reading it).
            x = x + self.embed_positions.weight[pos + self.offset].unsqueeze(1)
            slot = (idx.view(1, T) == pos.view(b, 1)).view(b, 1, T, 1)
            # The mask as a product with a scalar, not a where() between constants (at [B, T] the converter would make the
            # -inf a constant large enough to be int8-quantised; -1e4 is -inf to float16's softmax), and spread over the
            # heads: added to the scores as [B, 1, 1, T], Core ML's GPU read the attention wrongly (every sample's logits
            # off from the first step; 17/20 samples' tokens; 2026-10-25), as [B, H, 1, T] it reads them as PyTorch does.
            causal = ((idx.view(1, T) > pos.view(b, 1)).to(x.dtype) * -1e4).view(b, 1, 1, T).expand(b, H, 1, T)
        else:
            x = x + self.embed_positions.weight[pos + self.offset].unsqueeze(0)
            slot = (idx == pos).view(1, 1, T, 1)
            causal = torch.where(idx <= pos, 0.0, float("-inf")).view(1, 1, 1, T)
        x = self.layernorm_embedding(x)
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


class LeanCacheStep(nn.Module):
    """No cache state or cache mutation: input past K/V; output logits and this token's K/V only."""
    def __init__(self, reference: DecoderStep):
        super().__init__()
        for name in ("layers", "embed_tokens", "embed_positions", "layernorm_embedding", "output_projection", "act"):
            setattr(self, name, getattr(reference, name))
        for name in ("offset", "embed_scale", "heads", "head_dim", "scaling", "max_len", "batch"):
            setattr(self, name, getattr(reference, name))

    def forward(self, token, position, self_k, self_v, cross_k, cross_v):
        b, H, hd, T = self.batch, self.heads, self.head_dim, self.max_len
        pos = position.to(torch.long).view(b)
        x = self.embed_tokens(token.to(torch.long)) * self.embed_scale
        x = self.layernorm_embedding(x + self.embed_positions.weight[pos + self.offset].unsqueeze(1))
        # Cache positions strictly before p are valid. The new token is appended to the score vector, not the cache.
        # Expand the per-row mask over heads: the speed branch found incorrect Core ML GPU results without this.
        idx = torch.arange(T, device=x.device)
        past_mask = ((idx.view(1, T) >= pos.view(b, 1)).to(x.dtype) * -1e4).view(b, 1, 1, T).expand(b, H, 1, T)
        new_ks, new_vs = [], []
        for i, layer in enumerate(self.layers):
            attn = layer.self_attn
            q = (attn.q_proj(x) * self.scaling).view(b, 1, H, hd).transpose(1, 2)
            k = attn.k_proj(x).view(b, 1, H, hd).transpose(1, 2)
            v = attn.v_proj(x).view(b, 1, H, hd).transpose(1, 2)
            old_scores = torch.matmul(q, self_k[i].transpose(-1, -2)) + past_mask
            new_score = torch.matmul(q, k.transpose(-1, -2))
            attention = torch.softmax(torch.cat((old_scores, new_score), dim=-1), dim=-1)
            # Avoid a full-cache concat/scatter/output. The old and current value products have disjoint support.
            h = torch.matmul(attention[..., :T], self_v[i]) + attention[..., T:] * v
            h = h.transpose(1, 2).reshape(b, 1, -1)
            x = layer.self_attn_layer_norm(x + attn.out_proj(h))
            xa = layer.encoder_attn
            q = (xa.q_proj(x) * self.scaling).view(b, 1, H, hd).transpose(1, 2)
            a = torch.softmax(torch.matmul(q, cross_k[i].transpose(-1, -2)), dim=-1)
            h = torch.matmul(a, cross_v[i]).transpose(1, 2).reshape(b, 1, -1)
            x = layer.encoder_attn_layer_norm(x + xa.out_proj(h))
            x = layer.final_layer_norm(x + layer.fc2(self.act(layer.fc1(x))))
            new_ks.append(k); new_vs.append(v)
        return self.output_projection(x)[:, 0, :], torch.stack(new_ks), torch.stack(new_vs)


def commit_slices(cache_k, cache_v, new_k, new_v, positions):
    """Host-owned update after prediction; a slice for each row at its own current position."""
    for row, position in enumerate(positions.tolist()):
        cache_k[:, row, :, position:position+1, :].copy_(new_k[:, row])
        cache_v[:, row, :, position:position+1, :].copy_(new_v[:, row])


def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""): h.update(block)
    return h.hexdigest()


@torch.no_grad()
def run_schedule(reference, lean, encoded, samples, bos, eos, refill, logit_tolerance, probability_tolerance):
    B, T = reference.batch, reference.max_len
    ck_all, cv_all = encoded
    ck = torch.zeros_like(ck_all[:, :B]); cv = torch.zeros_like(cv_all[:, :B])
    cache_k = torch.zeros_like(reference.self_k); cache_v = torch.zeros_like(reference.self_v)
    reference.self_k.zero_(); reference.self_v.zero_()
    active = [None] * B; positions = torch.zeros(B, dtype=torch.int32)
    tokens = torch.full((B, 1), eos, dtype=torch.int32)
    generated = [[] for _ in samples]; next_crop = 0
    maximum_logit_delta = maximum_probability_delta = 0.0
    steps = refills = 0; mixed_seen = False
    def admit():
        nonlocal next_crop, refills
        for row in range(B):
            if active[row] is not None or next_crop == len(samples): continue
            if steps: refills += 1
            crop = next_crop; next_crop += 1; active[row] = crop
            ck[:, row].copy_(ck_all[:, crop]); cv[:, row].copy_(cv_all[:, crop])
            # Keep stale values deliberately: strict position masking must prevent cross-crop contamination.
            positions[row] = 0; tokens[row, 0] = bos
    while next_crop < len(samples) or any(x is not None for x in active):
        if refill or not any(x is not None for x in active): admit()
        mixed_seen |= len({int(positions[r]) for r in range(B) if active[r] is not None}) > 1
        actual, new_k, new_v = lean(tokens, positions, cache_k, cache_v, ck, cv)
        expected = reference(tokens, positions, ck, cv)
        if not torch.isfinite(actual).all() or not torch.isfinite(expected).all(): raise AssertionError("nonfinite_logits")
        max_delta = float((actual - expected).abs().max())
        maximum_logit_delta = max(maximum_logit_delta, max_delta)
        if max_delta > logit_tolerance: raise AssertionError(f"logit_delta={max_delta} step={steps}")
        expected_ids = expected.argmax(-1); actual_ids = actual.argmax(-1)
        probabilities = actual.softmax(-1).gather(1, actual_ids[:, None])[:, 0]
        expected_probabilities = expected.softmax(-1).gather(1, expected_ids[:, None])[:, 0]
        probability_delta = float((probabilities - expected_probabilities).abs().max())
        maximum_probability_delta = max(maximum_probability_delta, probability_delta)
        if probability_delta > probability_tolerance: raise AssertionError(f"probability_delta={probability_delta} step={steps}")
        commit_slices(cache_k, cache_v, new_k, new_v, positions)
        for row, crop in enumerate(active):
            if crop is None: continue
            if int(actual_ids[row]) != int(expected_ids[row]): raise AssertionError(f"token_mismatch sample={crop} position={int(positions[row])}")
            value = int(actual_ids[row]); generated[crop].append(value)
            recorded = samples[crop]["ids"][1:]
            if len(generated[crop]) > len(recorded) or value != recorded[len(generated[crop])-1]:
                raise AssertionError(f"recorded_token_mismatch sample={crop} position={int(positions[row])}")
            if value == eos:
                if generated[crop] != recorded: raise AssertionError(f"recorded_length_mismatch sample={crop}")
                active[row] = None; tokens[row, 0] = eos; positions[row] = 0
            else:
                positions[row] += 1; tokens[row, 0] = value
                if positions[row] >= T-1: raise AssertionError(f"no_eos_before_limit sample={crop}")
        steps += 1
    return {"passed": True, "samples": len(samples), "tokens": sum(map(len, generated)), "decoder_steps": steps,
            "row_refills": refills, "mixed_positions_exercised": mixed_seen,
            "max_logit_delta": maximum_logit_delta, "max_probability_delta": maximum_probability_delta,
            "token_sha256": hashlib.sha256(json.dumps(generated, separators=(",", ":")).encode()).hexdigest()}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--model", type=Path, required=True); p.add_argument("--samples", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True); p.add_argument("--threads", type=int, default=8)
    args = p.parse_args()
    torch.set_num_threads(args.threads)
    torch.set_num_interop_threads(1)
    torch.manual_seed(0)
    args.out.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "device": "cpu", "threads": args.threads, "batch": 8, "max_length": 512,
              "scope": "CPU functional prototype only; no Core ML export/loading or measured native RSS/timing", "runs": []}
    started = time.monotonic()
    def save():
        report["elapsed_seconds"] = round(time.monotonic()-started, 3)
        (args.out / "cpu-parity.json").write_text(json.dumps(report, indent=2)+"\n")
    try:
        meta_path=args.samples/"export.json"; samples=json.loads(meta_path.read_text())["equivalence"]["samples"]
        if len(samples) != 20: raise ValueError("fixed_budget_requires_exactly_20_existing_crops")
        report["source"] = {"script_sha256": sha(Path(__file__)), "exporter_sha256": sha(Path(__file__).with_name("export_texteller.py")),
                            "sample_export_sha256": sha(meta_path), "samples": [{"file":s["file"],"sha256":sha(args.samples/"samples"/s["file"])} for s in samples],
                            "model_files": {str(f.relative_to(args.model)):sha(f) for f in sorted(args.model.rglob("*")) if f.is_file()}}
        report["plan"] = {"schedules": ["whole_batches", "mixed_row_refill", "fresh_reset_repeat"], "max_logit_delta":1e-4, "max_probability_delta":1e-5,
                          "exact_recorded_tokens_required":True, "no_threshold_tuning":True}
        report["stage"]="load"; save()
        model, tokenizer=load(args.model); model.cpu()
        enc=Encoder(model,8).eval(); reference=ContinuousReference(model,512,8).eval(); lean=LeanCacheStep(reference).eval()
        if list(lean.named_buffers()): raise AssertionError("lean_model_must_not_own_cache_buffers")
        cross_k=[]; cross_v=[]
        with torch.no_grad():
            report["stage"]="encode"; save()
            for i in range(0,20,8):
                group=samples[i:i+8]; pixels=torch.zeros(8,1,448,448)
                for j,s in enumerate(group): pixels[j]=torch.from_numpy(np.load(args.samples/"samples"/s["file"]).astype(np.float32))
                ck,cv=enc(pixels); cross_k.append(ck[:,:len(group)].clone()); cross_v.append(cv[:,:len(group)].clone())
            encoded=(torch.cat(cross_k,1),torch.cat(cross_v,1))
            n=len(reference.layers); H=reference.heads; d=reference.head_dim; S=enc.seq
            report["cache_contract"]={"self_shape":[n,8,H,512,d],"cross_shape":[n,8,H,S,d],"delta_shape":[n,8,H,1,d],
                                      "deployment_cache_dtype":"float16", "self_pair_bytes":2*n*8*H*512*d*2,
                                      "cross_pair_bytes":2*n*8*H*S*d*2,"delta_pair_bytes":2*n*8*H*d*2,
                                      "note":"Tensor byte counts only, not RSS or a native memory qualification."}
            for name,refill in [("whole_batches",False),("mixed_row_refill",True),("fresh_reset_repeat",True)]:
                report["stage"]=name; save()
                result=run_schedule(reference,lean,encoded,samples,tokenizer.bos_token_id,tokenizer.eos_token_id,refill,1e-4,1e-5)
                result["schedule"]=name;report["runs"].append(result);save()
        if report["runs"][1]["token_sha256"] != report["runs"][2]["token_sha256"]: raise AssertionError("reset_changed_tokens")
        if not report["runs"][1]["mixed_positions_exercised"]: raise AssertionError("refill_failed_to_exercise_mixed_positions")
        report["passed"]=True;report["stage"]="complete";save()
    except Exception as e:
        report["error"] = f"{type(e).__name__}: {e}";save();raise
    print(json.dumps({"passed":report["passed"],"runs":report["runs"],"seconds":report["elapsed_seconds"]},indent=2))

if __name__ == "__main__": main()
