"""Opt-in import parity on existing owner-device data; no training, download or promotion.

Legacy source is imported only by this comparison, never by the training workflow.
Pass the desktop's existing source/data/checkpoint paths explicitly. Results contain
counts and hashes, not private paper text. Run with PYTHONPATH=training/device_pdf/src.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import sys
from pathlib import Path


def legacy_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for arg in ("legacy-src", "tagger-root", "data-root", "tagger-checkpoint", "recognizer", "layout", "out"):
        p.add_argument("--" + arg, type=Path, required=True)
    a = p.parse_args()
    os.environ["SR_PDF_DATA_ROOT"] = str(a.data_root)
    os.environ["SR_PDF_TAGGER_ROOT"] = str(a.tagger_root)
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    sys.path.insert(0, str(a.legacy_src))
    import numpy as np
    import torch
    from PIL import Image
    from science_reader_pdf.tagger import train as new
    from science_reader_pdf.models import train_layout_fcos as nl, texteller as nr
    from science_reader_pdf.models import train_texteller as nt
    from gradstep.models import train_layout_fcos as ol, texteller as oldr, train_texteller as ot
    torch.set_num_threads(4)
    torch.manual_seed(0)
    result = {"device": torch.cuda.get_device_name(), "torch": torch.__version__}
    old = legacy_module("legacy_tagger", a.tagger_root / "train.py")
    ids = old.load_lists()[0][:2]
    assert old.load_lists() == new.load_lists(root=a.tagger_root)
    ca, cb = old.Corpus(ids), new.Corpus(ids, data_dir=a.tagger_root / "data")
    ck = torch.load(a.tagger_checkpoint, map_location="cpu", weights_only=False)
    for c in (ca, cb):
        c.encode(ck["vocab"], ck["prior"], ck["cvocab"])
    for name in ("feats", "font_raw", "cls", "cp", "y", "shade", "items"):
        np.testing.assert_array_equal(getattr(ca, name), getattr(cb, name))
    ma, mb = old.Tagger(12, ck["hidden"]).cuda().eval(), new.Tagger(12, ck["hidden"]).cuda().eval()
    for model in (ma, mb):
        model.load_state_dict(ck["model"])
    with torch.no_grad():
        for length in (2, 17, 64, 399, 400):
            x = torch.randn(2, length, 12, device="cuda")
            ints = [torch.randint(n, (2, length), device="cuda") for n in (256, 10, 512)]
            torch.testing.assert_close(ma(x, *ints), mb(x, *ints), atol=0, rtol=0)
    result["tagger"] = {"papers": len(ids), "glyphs": len(ca.y), "items": len(ca.items),
                         "lengths": [2, 17, 64, 399, 400], "logit_max_difference": 0,
                         "checkpoint_sha256": hashlib.sha256(a.tagger_checkpoint.read_bytes()).hexdigest()}
    del ma, mb
    # Real factory crops, dataset selection, preprocessing and decoded answers must agree.
    cfg = dict(run="parity", dataset="factory-v3", limit_train=8, dev_per_placement=2)
    rows, dev = nt.load_rows(nt.TrainConfig(**cfg))
    assert (rows, dev) == ot.load_rows(ot.TrainConfig(**cfg))
    images = [np.asarray(Image.open(a.data_root / "datasets/factory-v3" / r["path"]).convert("RGB")) for r in rows[:4]]
    for im in images:
        torch.testing.assert_close(nr.preprocess_image(im), oldr.preprocess_image(im), atol=0, rtol=0)
    predictions = []
    for module in (oldr, nr):
        model = module.Recogniser(a.recognizer, max_new_tokens=64)
        predictions.append(model.predict_many(images))
        del model
        torch.cuda.empty_cache()
    assert predictions[0] == predictions[1]
    result["recognizer"] = {"crops": len(images), "dataset_selection_identical": True,
                             "pixels_identical": True, "decodes_and_confidence_identical": True,
                             "max_new_tokens": 64}
    # One real page through both FCOS implementations, loading weights without a download.
    info = json.loads((a.layout / "train-run.json").read_text())
    weights = torch.load(a.layout / "model.pt", map_location="cpu", weights_only=True)
    coco = a.data_root / "datasets/factory-v4/layout-full/dev.json"
    ims, by, names = nl.load_coco(coco)
    predictions = []
    for module in (ol, nl):
        model = module.build_model(info["size"], assign=info["assign"], pretrained=False).cuda().eval()
        model.load_state_dict(weights)
        predictions.append(module.predict(model, a.data_root / "datasets/factory-v4", ims[:1], torch.device("cuda")))
        del model
        torch.cuda.empty_cache()
    assert predictions[0] == predictions[1]
    result["layout"] = {"pages": 1, "detections": sum(map(len, predictions[0].values())), "detections_identical": True}
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
