"""Owner-device datasets are inputs; new models and runs use separate, ignored roots.

Set these before importing training modules (the CLI does this). No directory is
created on import and no network acquisition is performed by this package.
"""
from __future__ import annotations

import os
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[4]
WORK = REPO_ROOT / ".artifacts" / "device-pdf-development"


def configured(name: str, default: Path) -> Path:
    return Path(os.environ.get(name, str(default))).expanduser().resolve()


DATA = configured("SR_PDF_DATA_ROOT", WORK / "data")
MODELS = configured("SR_PDF_MODELS_ROOT", WORK / "models")
RUNS = configured("SR_PDF_RUNS_ROOT", WORK / "runs")
TAGGER = configured("SR_PDF_TAGGER_ROOT", DATA / "tagger")
ARXIV = DATA / "arxiv"
PMC = DATA / "pmc"


def paper_dir(paper_id: str) -> Path:
    return ARXIV / paper_id


def is_pmc(paper_id: str) -> bool:
    return paper_id.startswith("PMC")


def plain_pdf(paper_id: str) -> Path:
    return PMC / paper_id / f"{paper_id}.pdf" if is_pmc(paper_id) else ARXIV / paper_id / "build" / "plain.pdf"


def labels_json(paper_id: str) -> Path:
    return PMC / paper_id / "labels.json" if is_pmc(paper_id) else ARXIV / paper_id / "build" / "labels.json"
