#!/usr/bin/env python3
"""Copy a seeded random sample of the owner's journal PDFs into a folder the app imports as a test catalog
(docs/architecture/TEST_CATALOGS.md).

Reads the private Papers corpus without changing it and draws only from the held-out **test** split of the
family-grouped split. Excluded: train/dev families, the span study's reserved final cohort (any family listed in the
given --reserved selection files), files in needs-review.jsonl, files without a `%PDF-` header, and files the app
cannot add (over 64 MiB or 250 pages); slides and posters drawn (under 3 pages, or made by Keynote/PowerPoint) are
skipped. Light stratification: the sample is spread over publication-year eras in
proportion to the eligible pool, with at most --per-journal files from one journal.

Writes copies named "<first author> <year> - <short title>.pdf" and a selection.json (seed, method, split, counts and
each file's SHA-256; never PDF contents) into --out. Nothing from the corpus belongs in the repository.

    python3 -I scripts/select-test-pdfs.py --corpus ~/gradstep-mac/corpora/papers-library-20261026 \
        --splits .artifacts/papers-model-20261026/splits.json \
        --reserved .artifacts/device-pdf-development/spans/training-confirmation/selection.json \
        --out ~/Desktop/"Gradstep neuroscience test PDFs"
"""
import argparse
import datetime
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import sys

ERAS = [("before 2000", None, 1999), ("2000-2004", 2000, 2004), ("2005-2009", 2005, 2009),
        ("2010-2014", 2010, 2014), ("2015 and later", 2015, None), ("year unknown", None, None)]
MAX_BYTES = 64 * 1024 * 1024
MAX_PAGES = 250


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def jsonl(path):
    with open(path) as handle:
        return [json.loads(line) for line in handle if line.strip()]


def describe(row):
    """Title, first author, year and journal from the catalog records and the original file name."""
    entries = [b for b in row.get("bibliography") or [] if (b.get("title") or "").strip() and not b.get("marked_deleted")]
    entry = entries[0] if entries else {}
    title = " ".join((entry.get("title") or "").split()).rstrip(".")
    year = None
    for value in [entry.get("publication_date") or "", entry.get("publication_string") or ""]:
        match = re.search(r"(19|20)\d\d", value[2:6] if value.startswith("99") else value)
        if match:
            year = int(match.group(0))
            break
    journal, author = None, None
    for original in row.get("source_relative_paths") or []:
        parts = original.split("/")
        match = re.match(r"^(?P<journal>.+?) (?P<year>(19|20)\d\d) (?P<author>[^/]+?)(-\d+)?\.pdf$", parts[-1], re.IGNORECASE)
        if match:
            journal = journal or match.group("journal").strip()
            author = author or match.group("author").strip()
            year = year or int(match.group("year"))
        if len(parts) >= 3 and (re.fullmatch(r"(19|20)\d\d", parts[-3]) or parts[-3] == "Unknown") and parts[-2] != "Unknown":
            author = author or parts[-2].split(",")[0].strip()
        if len(parts) >= 3 and re.fullmatch(r"(19|20)\d\d", parts[-3]):
            year = year or int(parts[-3])
    if not author:
        names = (entry.get("author_string") or "").replace(" et al.", "").split(",")[0].split()
        author = names[-1] if names else None
    return {"title": title or None, "author": author, "year": year, "journal": journal}


def junk_title(title):
    """A catalog title that is really a file name, a DOI, a hash or a page header."""
    if not title or len(title.split()) < 2 or title.isupper():
        return True
    return bool(re.search(r"(^untitled$|doi[:\s]|^[0-9a-f]{8,}$|_|\.\.|^\d{4}[-_])", title, re.IGNORECASE))


def first_page_title(path):
    """The first line of the first page that reads like a title (skipping running heads), joined with the next one when
    it continues it."""
    text = subprocess.run(["pdftotext", "-q", "-l", "1", path, "-"], capture_output=True, text=True).stdout
    lines = [" ".join(line.split()) for line in text.splitlines()]
    for index, line in enumerate(lines):
        words = line.split()
        if len(words) < 3 or len(line) > 160 or re.search(r"(doi|http|www\.|©|journal|vol\.|pp\.|\d{4};|received|copyright|\(\d{4}\)|\d+\s*[–-]\s*\d+$)", line, re.IGNORECASE):
            continue
        if sum(1 for w in words if len(w) <= 2) > len(words) / 2 or line.isupper():
            continue
        following = lines[index + 1] if index + 1 < len(lines) else ""
        if following and not line.endswith(".") and len(following.split()) >= 2 and len(line) + len(following) < 160 \
                and not re.search(r"(,| and |\d)", following) and following[:1].islower() is False:
            line = f"{line} {following}"
        return line
    return None


def era(year):
    for name, low, high in ERAS[:-1]:
        if year is not None and (low is None or year >= low) and (high is None or year <= high):
            return name
    return ERAS[-1][0]


def file_name(info, sha, used):
    def clean(text):
        return re.sub(r"\s+", " ", re.sub(r"[/\\:*?\"<>|\x00-\x1f]", " ", text or "")).strip()
    words = clean(info["title"]).split()
    short = " ".join(words[:8])
    if len(short) > 60:
        short = short[:60].rsplit(" ", 1)[0]
    base = f"{clean(info['author']) or 'Unknown'} {info['year'] or 'n.d.'} - {short or sha[:12]}"
    name, n = base + ".pdf", 2
    while name.lower() in used:
        name, n = f"{base} ({n}).pdf", n + 1
    used.add(name.lower())
    return name


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True)
    parser.add_argument("--splits", required=True)
    parser.add_argument("--reserved", action="append", default=[])
    parser.add_argument("--out", required=True)
    parser.add_argument("--count", type=int, default=36)
    parser.add_argument("--per-journal", type=int, default=2)
    parser.add_argument("--seed", type=int, default=20261028)
    args = parser.parse_args()
    corpus = os.path.expanduser(args.corpus)

    splits = json.load(open(args.splits))
    reserved = set()
    for path in args.reserved:
        reserved |= {row["family"] for row in json.load(open(path))}
    review = {row["sha256"] for row in jsonl(os.path.join(corpus, "needs-review.jsonl"))}
    candidates = {row["sha256"] for row in jsonl(os.path.join(corpus, "candidate-pdfs.jsonl")) if row.get("pdf_header_present")}
    rows = {row["sha256"]: row for row in jsonl(os.path.join(corpus, "pdfs.jsonl"))}

    excluded = {"not test split": 0, "not eligible": 0, "reserved family": 0, "needs review": 0, "no PDF header": 0,
                "too large for the app": 0, "missing file": 0}
    pool = []
    for entry in splits:
        sha = entry["sha256"]
        if entry.get("split") != "test":
            excluded["not test split"] += 1; continue
        if not entry.get("eligible"):
            excluded["not eligible"] += 1; continue
        if entry["family"] in reserved:
            excluded["reserved family"] += 1; continue
        if sha in review:
            excluded["needs review"] += 1; continue
        row = rows.get(sha)
        if sha not in candidates or not row:
            excluded["no PDF header"] += 1; continue
        if row["bytes"] > MAX_BYTES or (entry.get("pages") or 0) > MAX_PAGES:
            excluded["too large for the app"] += 1; continue
        path = os.path.join(corpus, row["path"])
        if not os.path.isfile(path):
            excluded["missing file"] += 1; continue
        pool.append({"sha256": sha, "family": entry["family"], "pages": entry.get("pages"), "bytes": row["bytes"],
                     "path": path, **describe(row)})
        if junk_title(pool[-1]["title"]):
            pool[-1]["title"] = first_page_title(path) or pool[-1]["title"]
    pool.sort(key=lambda item: item["sha256"])

    # Allocation by era in proportion to the eligible pool (largest remainder), then a seeded draw within each era.
    rng = random.Random(args.seed)
    by_era = {name: [item for item in pool if era(item["year"]) == name] for name, _, _ in ERAS}
    shares = {name: args.count * len(items) / len(pool) for name, items in by_era.items()}
    allocation = {name: int(share) for name, share in shares.items()}
    for name in sorted(shares, key=lambda n: (shares[n] - int(shares[n]), n), reverse=True)[:args.count - sum(allocation.values())]:
        allocation[name] += 1
    chosen, journals, families, not_papers = [], {}, set(), []
    for name, _, _ in ERAS:
        items = by_era[name][:]
        rng.shuffle(items)
        taken = 0
        for item in items:
            if taken == allocation[name]:
                break
            journal = (item["journal"] or "").lower()
            if item["family"] in families or (journal and journals.get(journal, 0) >= args.per_journal):
                continue
            with open(item["path"], "rb") as handle:
                if handle.read(5) != b"%PDF-":
                    continue
            # Papers, not slides or posters: three pages or more, not made by a slide program.
            info = subprocess.run(["pdfinfo", item["path"]], capture_output=True, text=True).stdout
            if (item["pages"] or 0) < 3 or re.search(r"^(Creator|Producer):.*(Keynote|PowerPoint)", info, re.M | re.I):
                not_papers.append(item["sha256"])
                continue
            if sha256_file(item["path"]) != item["sha256"]:
                print(f"hash mismatch, skipped: {item['sha256']}", file=sys.stderr)
                continue
            chosen.append({**item, "era": name})
            families.add(item["family"])
            if journal:
                journals[journal] = journals.get(journal, 0) + 1
            taken += 1

    os.makedirs(args.out, exist_ok=True)
    used = {name.lower() for name in os.listdir(args.out)}
    files = []
    for item in chosen:
        name = file_name(item, item["sha256"], used)
        target = os.path.join(args.out, name)
        shutil.copyfile(item["path"], target)
        if sha256_file(target) != item["sha256"]:
            raise SystemExit(f"copy check failed: {name}")
        files.append({"file": name, "sha256": item["sha256"], "family": item["family"], "year": item["year"],
                      "journal": item["journal"], "era": item["era"], "pages": item["pages"], "bytes": item["bytes"]})
    record = {
        "created": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "seed": args.seed,
        "method": "test split only (family-grouped split); excluded reserved families, needs-review files, files without a "
                  "%PDF- header and files over 64 MiB or 250 pages; slides and posters (under 3 pages or made by Keynote or "
                  "PowerPoint) skipped when drawn; seeded draw spread over year eras in proportion to the "
                  f"pool, at most {args.per_journal} per journal and one per family; copies verified by SHA-256.",
        "split": {"file": os.path.abspath(args.splits), "sha256": sha256_file(args.splits), "split": "test"},
        "reserved": [{"file": os.path.abspath(p), "sha256": sha256_file(p)} for p in args.reserved],
        "corpus": corpus,
        "counts": {"test_split_eligible_pool": len(pool), "excluded": excluded,
                   "pool_by_era": {name: len(items) for name, items in by_era.items()},
                   "allocated_by_era": allocation, "drawn_but_not_papers": len(not_papers), "chosen": len(files)},
        "files": files,
    }
    with open(os.path.join(args.out, "selection.json"), "w") as handle:
        json.dump(record, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print(json.dumps(record["counts"], indent=2))


if __name__ == "__main__":
    main()
