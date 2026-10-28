"""Run the existing trainers with explicit local inputs and fresh output directories."""
from __future__ import annotations

import argparse
import inspect
import json
import os
import re
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("data", "models", "runs", "tagger"):
        parser.add_argument(f"--{name}-root", type=Path)
    parser.add_argument("task", choices=["paths", "train-recognizer", "train-layout"])
    parser.add_argument("config", type=Path, nargs="?")
    args = parser.parse_args()
    for name in ("data", "models", "runs", "tagger"):
        value = getattr(args, name + "_root")
        if value is not None:
            os.environ[f"SR_PDF_{name.upper()}_ROOT"] = str(value.expanduser().resolve())
    from . import paths
    if args.task == "paths":
        print(json.dumps({n: str(getattr(paths, n)) for n in ("REPO_ROOT", "DATA", "MODELS", "RUNS", "TAGGER")}, indent=2))
        return
    if args.config is None:
        parser.error("training requires a JSON config; see training/device_pdf/README.md")
    config = json.loads(args.config.read_text())
    run = config.get("run", "")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", run):
        parser.error("run must be a simple name, not a path")
    if (paths.MODELS / run).exists():
        parser.error(f"output already exists: {paths.MODELS / run}; choose a new run name")
    if not paths.DATA.is_dir():
        parser.error(f"dataset root is missing: {paths.DATA}")
    if args.task == "train-recognizer":
        from .models.train_texteller import TrainConfig, train
        train(TrainConfig(**config))
    else:
        from .models.train_layout_fcos import train
        inspect.signature(train).bind(**config)  # reject misspelled options before training
        train(**config)


if __name__ == "__main__":
    main()
