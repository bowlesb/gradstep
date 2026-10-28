"""Thin wrappers around candidate models; each produces predictions.jsonl for the harness."""

from __future__ import annotations

import json
from pathlib import Path


def resume_state(out: Path, resume: bool) -> set[str]:
    """Keys (id@paper) already present in a predictions file, so an interrupted run can
    continue by appending instead of starting over. Empty unless resume is requested."""
    if not resume or not out.is_file():
        return set()
    done: set[str] = set()
    for line in out.read_text().splitlines():
        if line.strip():
            p = json.loads(line)
            done.add(p["id"] + "@" + p["paper"])
    return done


def pending_rows(rows: list[dict], done: set[str]) -> list[dict]:
    return [r for r in rows if r["id"] + "@" + r["paper"] not in done]
