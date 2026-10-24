"""Fetch the Feed pool and staff/test libraries from staging (read-only) into the artifacts folder.

Outputs (in OUT):
  pool.json       Feed pool papers: source_id, title, abstract, categories, announced_on, upvotes
  libraries.json  {account_label: [ {source_id, title, abstract, categories, added_at, archived, kind} ]}
                  Account ids are replaced by labels ("owner", "account-2", ...); no emails are stored.
"""
import json
import os
import sys

from common import OUT
from sbquery import query

OWNER_EMAIL = "ben.bowles@gmail.com"  # used only to identify the owner's account
MIN_LIBRARY = 10


def fetch_pool():
    rows, last = [], ""
    while True:
        page = query(
            "select source_id, title, abstract, categories, announced_on::text as announced_on, "
            "coalesce(upvotes,0) as upvotes from app_private.feed_papers "
            f"where source_id > '{last}' order by source_id limit 2000"
        )
        if not page:
            return rows
        rows += page
        last = page[-1]["source_id"].replace("'", "''")
        print(f"pool: {len(rows)}", file=sys.stderr)


def fetch_libraries():
    accounts = query(
        "select q.account_id, bool_or(lower(u.email) = '" + OWNER_EMAIL + "') as is_owner, count(*) as n "
        "from app_private.library_query_entries q join app_private.accounts a on a.id = q.account_id "
        "join auth.users u on u.id = a.auth_user_id where q.visible group by q.account_id "
        "order by is_owner desc, n desc"
    )
    libs, labels = {}, {}
    for i, a in enumerate(accounts):
        if not a["is_owner"] and a["n"] < MIN_LIBRARY:
            continue
        label = "owner" if a["is_owner"] else f"account-{i + 1}"
        labels[label] = a["n"]
        rows = query(
            "select q.source_id, q.kind, q.archived, coalesce(e.entry->>'added_at', '') as added_at, "
            "m.metadata->>'title' as title, m.metadata->>'abstract' as abstract, "
            "coalesce(m.metadata->'categories', '[]'::jsonb) as categories "
            "from app_private.library_query_entries q "
            "join app_private.library_v4_entries e on e.id = q.id and e.account_id = q.account_id "
            "left join app_private.catalog_metadata m on m.id = q.metadata_id "
            f"where q.visible and q.account_id = '{a['account_id']}'"
        )
        libs[label] = rows
        print(f"{label}: {len(rows)} visible entries", file=sys.stderr)
    return libs


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    pool = fetch_pool()
    with open(os.path.join(OUT, "pool.json"), "w") as f:
        json.dump(pool, f)
    libs = fetch_libraries()
    with open(os.path.join(OUT, "libraries.json"), "w") as f:
        json.dump(libs, f, indent=1)
    print(f"pool {len(pool)}; libraries " + ", ".join(f"{k}={len(v)}" for k, v in libs.items()), file=sys.stderr)
