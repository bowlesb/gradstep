"""The paper manifest: one record per acquired arXiv revision.

Records are rebuilt from the files on disk; the abstract page saved at acquisition time is
the license evidence and is parsed directly, so no external manifest is required.
"""

from __future__ import annotations

import hashlib
import json
import re
from collections import Counter
from pathlib import Path

from pydantic import BaseModel

from science_reader_pdf.paths import ARXIV

LICENSE_RE = re.compile(r"https?://(?:creativecommons\.org/(?:licenses|publicdomain)/[^\"'\s<>]+|arxiv\.org/licenses/[^\"'\s<>]+)")
TITLE_RE = re.compile(r'<meta name="citation_title" content="([^"]*)"')
SUBJECT_RE = re.compile(r'<span class="primary-subject">([^<(]+?)\s*\(')
TRAINABLE_LICENSES = {
    "https://creativecommons.org/licenses/by/4.0/",
    "http://creativecommons.org/licenses/by/4.0/",
    "https://creativecommons.org/publicdomain/zero/1.0/",
    "http://creativecommons.org/publicdomain/zero/1.0/",
}


class Paper(BaseModel):
    id: str  # exact revision, e.g. 2610.13811v1
    family: str  # paper identity without the version, used for splits
    license: str | None
    trainable: bool
    category: str | None
    title: str | None
    pdf_sha256: str | None
    html_sha256: str | None
    source_sha256: str | None

    @property
    def dir(self) -> Path:
        return ARXIV / self.id


def sha256(path: Path) -> str | None:
    if not path.is_file():
        return None
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def family_of(paper_id: str) -> str:
    return re.sub(r"v\d+$", "", paper_id)


def record_from_dir(d: Path) -> Paper:
    abstract = d / "abstract.html"
    text = abstract.read_text(errors="replace") if abstract.is_file() else ""
    # The rights link on an abstract page is the first license URL that is not in the header nav.
    licenses = [m for m in LICENSE_RE.findall(text) if "licenses/by" in m or "publicdomain" in m or "arxiv.org/licenses" in m]
    license_url = licenses[0].rstrip("/") + "/" if licenses else None
    title_m = TITLE_RE.search(text)
    subj_m = SUBJECT_RE.search(text)
    return Paper(
        id=d.name,
        family=family_of(d.name),
        license=license_url,
        trainable=license_url in TRAINABLE_LICENSES if license_url else False,
        category=subj_m.group(1).strip() if subj_m else None,
        title=title_m.group(1) if title_m else None,
        pdf_sha256=sha256(d / "arxiv.pdf"),
        html_sha256=sha256(d / "arxiv.html"),
        source_sha256=sha256(d / "source.archive"),
    )


def paper_dirs() -> list[Path]:
    return sorted(p for p in ARXIV.iterdir() if p.is_dir() and not p.name.startswith("_"))


def build_manifest() -> list[Paper]:
    papers = [record_from_dir(d) for d in paper_dirs()]
    out = ARXIV / "papers.jsonl"
    with out.open("w") as f:
        for p in papers:
            f.write(p.model_dump_json() + "\n")
    return papers


def load_manifest() -> list[Paper]:
    out = ARXIV / "papers.jsonl"
    if not out.is_file():
        return build_manifest()
    return [Paper.model_validate_json(line) for line in out.read_text().splitlines() if line.strip()]


def summarize(papers: list[Paper]) -> dict[str, object]:
    return {
        "papers": len(papers),
        "trainable": sum(p.trainable for p in papers),
        "licenses": dict(Counter(p.license for p in papers)),
        "categories": dict(Counter(p.category for p in papers)),
        "complete": sum(all([p.pdf_sha256, p.html_sha256, p.source_sha256]) for p in papers),
    }


if __name__ == "__main__":
    print(json.dumps(summarize(build_manifest()), indent=1))
