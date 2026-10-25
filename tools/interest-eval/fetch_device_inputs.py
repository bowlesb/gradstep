"""Step 3: fetch the published map and term statistics and library papers' public fingerprints from staging (read-only).

Outputs (in OUT/device, never committed):
  map.gsi, terms.gsi      the published artifacts, byte-identical to what devices download (SHA-256 checked)
  fingerprints.json       {source_id: {q8, leaf_id, leaf_map_version, terms}} for the owner's library papers and the
                          public pool papers listed in pool_ids.json (when present)
Usage: fetch_device_inputs.py [--pool-ids FILE]
"""
import argparse
import base64
import hashlib
import json
import os

from common import OUT
from sbquery import query


def artifacts(dest):
    rows = query(
        "select kind, map_version, encode(sha256,'hex') as sha256, encode(content,'base64') as b64 "
        "from app_private.interest_artifacts where kind in ('map','terms') and state='published' "
        "order by map_version desc nulls last, published_at desc"
    )
    seen = {}
    for r in rows:
        if r["kind"] in seen:
            continue
        data = base64.b64decode(r["b64"])
        if hashlib.sha256(data).hexdigest() != r["sha256"]:
            raise SystemExit(f"{r['kind']}: digest mismatch")
        open(os.path.join(dest, f"{r['kind']}.gsi"), "wb").write(data)
        seen[r["kind"]] = {"map_version": r["map_version"], "sha256": r["sha256"], "bytes": len(data)}
    return seen


def fingerprints(ids):
    out = {}
    ids = sorted(set(ids))
    for i in range(0, len(ids), 200):
        chunk = ",".join("'" + s.replace("'", "''") + "'" for s in ids[i:i + 200])
        for r in query(
            "select source_id, encode(fp_q8,'base64') as q8, leaf_id, leaf_map_version, terms "
            f"from app_private.interest_papers where state='embedded' and source_id in ({chunk})"
        ):
            out[r["source_id"]] = {**{k: r[k] for k in ("leaf_id", "leaf_map_version", "terms")}, "q8": "".join(r["q8"].split())}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pool-ids")
    args = ap.parse_args()
    dest = os.path.join(OUT, "device")
    os.makedirs(dest, exist_ok=True)
    info = artifacts(dest)
    libs = json.load(open(os.path.join(OUT, "libraries.json")))
    ids = [r["source_id"] for r in libs["owner"]]
    if args.pool_ids:
        ids += json.load(open(args.pool_ids))
    fps = fingerprints(ids)
    json.dump(fps, open(os.path.join(dest, "fingerprints.json"), "w"))
    json.dump(info, open(os.path.join(dest, "artifacts.json"), "w"), indent=1)
    print(json.dumps(info, indent=1), f"\nfingerprints: {len(fps)} of {len(set(ids))}")


if __name__ == "__main__":
    main()
