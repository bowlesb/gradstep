"""Research-only stateless lean-cache export. Does not update the production model lock or pack.

Requires the fixed CPU probe to have passed for these exact source/checkpoint/sample bytes. Conversion is supported
on the desktop; no Core ML model is loaded for execution. A passing report verifies the graph contract only.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
import platform
import time
from pathlib import Path

import numpy as np
import torch

from export_texteller import Encoder, load
from probe_texteller_lean_cache import ContinuousReference, LeanCacheStep, sha


def tensor_shape(value_type):
    if value_type.WhichOneof("type") != "tensorType":
        raise ValueError("non_tensor_MIL_value")
    shape = []
    for dim in value_type.tensorType.dimensions:
        if dim.WhichOneof("dimension") != "constant":
            raise ValueError("dynamic_MIL_dimension")
        shape.append(dim.constant.size)
    return shape


def inspect_spec(spec, inputs, outputs, *, step):
    """Reject state, unexpected interfaces, and full-cache update/output operations in a saved package."""
    from coremltools.proto import FeatureTypes_pb2
    dtypes = {FeatureTypes_pb2.ArrayFeatureType.FLOAT16: "float16",
              FeatureTypes_pb2.ArrayFeatureType.FLOAT32: "float32",
              FeatureTypes_pb2.ArrayFeatureType.INT32: "int32"}
    def features(rows):
        result = {}
        for row in rows:
            if row.name in result or row.type.WhichOneof("Type") != "multiArrayType":
                raise ValueError("unexpected_feature_type_or_duplicate")
            a = row.type.multiArrayType
            if a.HasField("shapeRange") or a.HasField("enumeratedShapes"):
                raise ValueError("flexible_feature_shape")
            result[row.name] = {"shape": list(a.shape), "dtype": dtypes.get(a.dataType, "unknown")}
        return result
    actual_inputs, actual_outputs = features(spec.description.input), features(spec.description.output)
    if actual_inputs != inputs or actual_outputs != outputs:
        raise ValueError(f"interface_mismatch: {actual_inputs!r} -> {actual_outputs!r}")
    if spec.description.state:
        raise ValueError("model_description_has_state")
    if spec.WhichOneof("Type") != "mlProgram" or set(spec.mlProgram.functions) != {"main"}:
        raise ValueError("expected_one_stateless_MLProgram_function")
    operations = Counter(); concat_shapes = []
    def check_value(value):
        kind = value.type.WhichOneof("type")
        if kind == "stateType": raise ValueError("MIL_state_value")
    def visit(block):
        for value in block.inputs: check_value(value)
        for op in block.operations:
            operations[op.type] += 1
            if "state" in op.type or (step and (op.type.startswith("scatter") or op.type == "slice_update")):
                raise ValueError("cache_update_operation:"+op.type)
            for value in op.outputs: check_value(value)
            if step and op.type == "concat":
                for value in op.outputs:
                    shape = tensor_shape(value.type); concat_shapes.append(shape)
                    if len(shape) >= 4 and shape[-1] == 64 and shape[-2] >= 512:
                        raise ValueError("full_cache_concat")
            for nested in op.blocks: visit(nested)
    function = spec.mlProgram.functions["main"]
    for value in function.inputs: check_value(value)
    for block in function.block_specializations.values(): visit(block)
    return {"inputs": actual_inputs, "outputs": actual_outputs, "state_features": 0,
            "functions": list(spec.mlProgram.functions), "operation_counts": dict(sorted(operations.items())),
            "step_concat_shapes": concat_shapes, "passed": True}


def interface(shape, dtype): return {"shape": list(shape), "dtype": dtype}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--samples", type=Path, required=True)
    parser.add_argument("--cpu-report", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--threads", type=int, default=8)
    args = parser.parse_args()
    # The research budget is fixed: do not expose implicit architecture/dtype/length searches here.
    B, T = 8, 512
    torch.set_num_threads(args.threads); torch.set_num_interop_threads(1)
    args.out.mkdir(parents=True, exist_ok=True)
    for name in ("encoder.mlpackage", "step.mlpackage"):
        if (args.out/name).exists(): raise FileExistsError(f"preserve_existing_export:{name}")
    report = {"passed": False, "stage": "input_identity", "scope": "static_export_only",
              "runtime_tested": False, "encrypted": False, "batch": B, "max_length": T, "threads": args.threads}
    start = time.monotonic()
    def save():
        report["elapsed_seconds"] = round(time.monotonic()-start, 3)
        (args.out/"export-report.json").write_text(json.dumps(report, indent=2)+"\n")
    try:
        cpu = json.loads(args.cpu_report.read_text())
        if cpu.get("passed") is not True or len(cpu.get("runs", [])) != 3:
            raise ValueError("missing_passed_fixed_CPU_probe")
        source = cpu["source"]
        probe = Path(__file__).with_name("probe_texteller_lean_cache.py")
        exporter = Path(__file__).with_name("export_texteller.py")
        if sha(probe) != source["script_sha256"] or sha(exporter) != source["exporter_sha256"]:
            raise ValueError("CPU_qualified_source_changed")
        model_files = {str(f.relative_to(args.model)):sha(f) for f in sorted(args.model.rglob("*")) if f.is_file()}
        if model_files != source["model_files"] or sha(args.samples/"export.json") != source["sample_export_sha256"]:
            raise ValueError("CPU_qualified_inputs_changed")
        for sample in source["samples"]:
            if sha(args.samples/"samples"/sample["file"]) != sample["sha256"]: raise ValueError("sample_changed")
        report["source"] = {"cpu_report_sha256":sha(args.cpu_report), "probe_sha256":sha(probe),
                            "exporter_sha256":sha(exporter), "export_script_sha256":sha(Path(__file__)),
                            "model_files":model_files, "sample_export_sha256":source["sample_export_sha256"]}
        report["stage"] = "load_checkpoint"; save()
        import coremltools as ct
        from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
        report["environment"] = {"python":platform.python_version(), "platform":platform.platform(),
                                 "torch":torch.__version__, "numpy":np.__version__, "coremltools":ct.__version__}
        report["conversion"] = {"compute_precision":"float16", "minimum_target":"iOS18",
                                "weights":"int8_linear_symmetric_per_channel", "skip_model_load":True}
        model, tokenizer = load(args.model); model.cpu()
        encoder = Encoder(model, B).eval()
        reference = ContinuousReference(model, T, B).eval()
        step = LeanCacheStep(reference).eval()
        if list(step.named_buffers()): raise ValueError("lean_step_has_buffers")
        L, H, D, S = len(reference.layers), reference.heads, reference.head_dim, encoder.seq
        if (L,H,D,S) != (12,16,64,785): raise ValueError("unexpected_checkpoint_architecture")
        self_shape = (L,B,H,T,D); cross_shape = (L,B,H,S,D); delta_shape = (L,B,H,1,D)
        vocab = model.decoder.config.vocab_size
        common = dict(convert_to="mlprogram", compute_precision=ct.precision.FLOAT16,
                      minimum_deployment_target=ct.target.iOS18, skip_model_load=True)
        contracts = {
            "encoder": ({"pixel_values":interface((B,1,448,448),"float32")},
                        {"cross_k":interface(cross_shape,"float16"),"cross_v":interface(cross_shape,"float16")}),
            "step": ({"token":interface((B,1),"int32"), "position":interface((B,),"int32"),
                      **{n:interface(self_shape,"float16") for n in ("self_k","self_v")},
                      **{n:interface(cross_shape,"float16") for n in ("cross_k","cross_v")}},
                     {"logits":interface((B,vocab),"float32"), "new_k":interface(delta_shape,"float16"),
                      "new_v":interface(delta_shape,"float16")})}
        report["contracts"] = contracts; report["packages"] = {}; save()
        dtype = {"float16":np.float16,"float32":np.float32,"int32":np.int32}
        for name, module in (("encoder",encoder),("step",step)):
            report["stage"] = name+"_trace";save()
            ins, outs = contracts[name]
            # The CPU-qualified graph is float32; conversion inserts the declared fp16 boundary and fp16 compute.
            trace_inputs = tuple(torch.zeros(row["shape"],dtype=torch.int32 if row["dtype"]=="int32" else torch.float32)
                                 for row in ins.values())
            with torch.no_grad(): traced = torch.jit.trace(module, trace_inputs, strict=True)
            report["stage"] = name+"_convert";save()
            converted = ct.convert(traced, inputs=[ct.TensorType(name=n,shape=r["shape"],dtype=dtype[r["dtype"]]) for n,r in ins.items()],
                                   outputs=[ct.TensorType(name=n,dtype=dtype[r["dtype"]]) for n,r in outs.items()], **common)
            report["stage"] = name+"_quantize";save()
            converted = linear_quantize_weights(converted, OptimizationConfig(global_config=OpLinearQuantizerConfig(
                mode="linear_symmetric", granularity="per_channel")))
            checks = inspect_spec(converted.get_spec(),ins,outs,step=name=="step")
            package = args.out/(name+".mlpackage"); converted.save(str(package))
            saved = ct.models.MLModel(str(package),skip_model_load=True)
            if inspect_spec(saved.get_spec(),ins,outs,step=name=="step") != checks:
                raise ValueError("saved_graph_contract_changed")
            files = {str(f.relative_to(package)):sha(f) for f in sorted(package.rglob("*")) if f.is_file()}
            report["packages"][name] = {"file_sha256":files,"bytes":sum(f.stat().st_size for f in package.rglob("*") if f.is_file()),
                                         "graph":checks};save()
            del saved, converted, traced, trace_inputs
        tokenizer.save_pretrained(str(args.out/"tokenizer"))
        report["passed"] = True;report["stage"]="complete";save()
    except Exception as e:
        report["error"] = f"{type(e).__name__}: {e}";save();raise
    print(json.dumps({"passed":True,"scope":report["scope"],"packages":{k:v["bytes"] for k,v in report["packages"].items()},
                      "elapsed_seconds":report["elapsed_seconds"]},indent=2))


if __name__ == "__main__": main()
