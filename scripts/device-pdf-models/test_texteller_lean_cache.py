"""Small CPU tests of cache ownership, row positions and equivalence; no model checkpoint or Core ML."""
import unittest
from types import SimpleNamespace

import torch
from torch import nn

from export_texteller import DecoderStep
from probe_texteller_lean_cache import ContinuousReference, LeanCacheStep, commit_slices


def toy_model():
    def attention():
        a = nn.Module()
        for name in ("q_proj", "k_proj", "v_proj", "out_proj"):
            setattr(a, name, nn.Linear(8, 8))
        return a
    layers = nn.ModuleList()
    for _ in range(2):
        layer = nn.Module()
        layer.self_attn = attention(); layer.encoder_attn = attention()
        layer.self_attn_layer_norm = nn.LayerNorm(8)
        layer.encoder_attn_layer_norm = nn.LayerNorm(8)
        layer.final_layer_norm = nn.LayerNorm(8)
        layer.fc1 = nn.Linear(8, 16); layer.fc2 = nn.Linear(16, 8)
        layers.append(layer)
    decoder = SimpleNamespace(layers=layers, embed_tokens=nn.Embedding(32, 8),
                              embed_positions=nn.Embedding(12, 8), layernorm_embedding=nn.LayerNorm(8))
    config = SimpleNamespace(d_model=8, decoder_attention_heads=2, scale_embedding=False,
                             activation_function="gelu")
    return SimpleNamespace(decoder=SimpleNamespace(model=SimpleNamespace(decoder=decoder), config=config,
                                                   output_projection=nn.Linear(8, 32)))


class LeanCacheTests(unittest.TestCase):
    def setUp(self):
        torch.manual_seed(7)
        torch.set_num_threads(1)
        self.model = toy_model()

    @torch.no_grad()
    def test_matches_original_independent_rows_at_boundary_and_refill(self):
        ref = ContinuousReference(self.model, 8, 2).eval()
        originals = [DecoderStep(self.model, 8, 1).eval() for _ in range(2)]
        lean = LeanCacheStep(ref).eval()
        ck = torch.randn(2, 2, 2, 3, 4); cv = torch.randn_like(ck)
        k = torch.randn_like(ref.self_k); v = torch.randn_like(ref.self_v)
        for row, original in enumerate(originals):
            original.self_k.copy_(k[:, row:row+1]); original.self_v.copy_(v[:, row:row+1])
        # Boundary 7 and a return to 0 retain stale future values; rows then advance independently.
        for positions in ([0, 7], [1, 0], [2, 1], [0, 2]):
            token = torch.randint(0, 32, (2, 1), dtype=torch.int32)
            pos = torch.tensor(positions, dtype=torch.int32)
            before_k = k.clone(); before_v = v.clone()
            actual, dk, dv = lean(token, pos, k, v, ck, cv)
            expected = torch.cat([original(token[row:row+1], pos[row:row+1], ck[:, row:row+1], cv[:, row:row+1])
                                  for row, original in enumerate(originals)])
            torch.testing.assert_close(actual, expected, rtol=1e-5, atol=1e-6)
            self.assertTrue(torch.equal(k, before_k)); self.assertTrue(torch.equal(v, before_v))
            self.assertEqual(tuple(dk.shape), (2, 2, 2, 1, 4))
            commit_slices(k, v, dk, dv, pos)
            for row, original in enumerate(originals):
                torch.testing.assert_close(k[:, row:row+1], original.self_k, rtol=1e-5, atol=1e-6)
                torch.testing.assert_close(v[:, row:row+1], original.self_v, rtol=1e-5, atol=1e-6)
        self.assertEqual(list(lean.named_buffers()), [])

    @torch.no_grad()
    def test_current_and_future_slots_cannot_influence_logits(self):
        ref = ContinuousReference(self.model, 8, 2).eval(); lean = LeanCacheStep(ref).eval()
        pos = torch.tensor([0, 3], dtype=torch.int32); token = torch.tensor([[2], [3]], dtype=torch.int32)
        ck = torch.randn(2, 2, 2, 3, 4); cv = torch.randn_like(ck)
        k = torch.randn_like(ref.self_k); v = torch.randn_like(ref.self_v)
        before = lean(token, pos, k, v, ck, cv)
        for row, p in enumerate(pos.tolist()):
            k[:, row, :, p:] = torch.randn_like(k[:, row, :, p:]) * 20
            v[:, row, :, p:] = torch.randn_like(v[:, row, :, p:]) * 20
        after = lean(token, pos, k, v, ck, cv)
        for a, b in zip(before, after): torch.testing.assert_close(a, b, rtol=0, atol=0)

    @torch.no_grad()
    def test_dense_continuous_reference_matches_independent_legacy_rows(self):
        reference = ContinuousReference(self.model, 8, 2).eval()
        originals = [DecoderStep(self.model, 8, 1).eval() for _ in range(2)]
        ck = torch.randn(2, 2, 2, 3, 4); cv = torch.randn_like(ck)
        for positions in ([0, 0], [1, 1], [0, 2], [1, 3]):
            token = torch.randint(0, 32, (2, 1), dtype=torch.int32); pos = torch.tensor(positions, dtype=torch.int32)
            expected = torch.cat([original(token[row:row+1], pos[row:row+1], ck[:, row:row+1], cv[:, row:row+1])
                                  for row, original in enumerate(originals)])
            actual = reference(token, pos, ck, cv)
            torch.testing.assert_close(actual, expected, rtol=1e-5, atol=1e-6)


class LeanExportContractTests(unittest.TestCase):
    def specimen(self):
        from coremltools.proto import Model_pb2, FeatureTypes_pb2
        from export_texteller_lean_cache import interface
        spec = Model_pb2.Model(); spec.mlProgram.version = 1
        ins = {"token":interface((8,1),"int32")}
        outs = {"new_k":interface((12,8,16,1,64),"float16")}
        for name, shape, dtype, target in [
            ("token", (8,1), FeatureTypes_pb2.ArrayFeatureType.INT32, spec.description.input),
            ("new_k", (12,8,16,1,64), FeatureTypes_pb2.ArrayFeatureType.FLOAT16, spec.description.output),
        ]:
            row=target.add();row.name=name;row.type.multiArrayType.shape.extend(shape);row.type.multiArrayType.dataType=dtype
        spec.mlProgram.functions["main"].block_specializations["CoreML8"].outputs.append("new_k")
        return spec, ins, outs

    def test_contract_refuses_unexpected_state_and_full_cache_output(self):
        from export_texteller_lean_cache import inspect_spec
        spec,ins,outs=self.specimen()
        self.assertTrue(inspect_spec(spec,ins,outs,step=True)["passed"])
        spec.description.state.add().name="self_k"
        with self.assertRaisesRegex(ValueError,"description_has_state"): inspect_spec(spec,ins,outs,step=True)
        del spec.description.state[:]
        spec.description.output[0].type.multiArrayType.shape[3]=512
        with self.assertRaisesRegex(ValueError,"interface_mismatch"): inspect_spec(spec,ins,outs,step=True)

    def test_contract_refuses_state_in_MIL_even_if_description_omits_it(self):
        from export_texteller_lean_cache import inspect_spec
        spec,ins,outs=self.specimen()
        value=spec.mlProgram.functions["main"].inputs.add();value.name="cache"
        value.type.stateType.SetInParent()
        with self.assertRaisesRegex(ValueError,"MIL_state_value"): inspect_spec(spec,ins,outs,step=True)

    def test_contract_refuses_cache_scatter_and_large_cache_concat(self):
        from export_texteller_lean_cache import inspect_spec
        spec,ins,outs=self.specimen()
        block=spec.mlProgram.functions["main"].block_specializations["CoreML8"]
        op=block.operations.add();op.type="scatter_along_axis"
        with self.assertRaisesRegex(ValueError,"cache_update_operation"): inspect_spec(spec,ins,outs,step=True)
        op.type="concat";out=op.outputs.add();out.name="assembled_cache"
        out.type.tensorType.rank=4
        for dimension in [8,16,513,64]: out.type.tensorType.dimensions.add().constant.size=dimension
        with self.assertRaisesRegex(ValueError,"full_cache_concat"): inspect_spec(spec,ins,outs,step=True)


if __name__ == "__main__": unittest.main()
