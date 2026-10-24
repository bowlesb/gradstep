# Interest index: offline evaluation (step 1)

Research code for step 1 of `docs/proposals/INTEREST_INDEX.md`. It does not change the app, the schema or any
service. Outputs go to `.artifacts/interest-eval/` in the main checkout (gitignored); the findings are in
`.artifacts/interest-eval/REPORT.md`.

## Data access

`sbquery.py` sends single read-only `SELECT`/`WITH` statements to the staging project through the Supabase
Management API. The bearer token is read from the macOS Keychain (`Supabase CLI`) at call time and is never printed
or stored. Nothing contacts arXiv; all paper text comes from `app_private.feed_papers` and `catalog_metadata`.
`fetch_data.py` uses the owner's email only to find the account and stores libraries under labels (`owner`,
`account-N`), never emails or account ids.

## Run

```
python3.14 -m venv .venv
.venv/bin/pip install torch sentence-transformers adapters scikit-learn matplotlib
.venv/bin/python fetch_data.py      # pool.json, libraries.json
.venv/bin/python embed.py           # emb/<model>.npy, models.json (MPS when available; cached)
.venv/bin/python eval_ranking.py    # evaluation 1: eval1_ranking.json
.venv/bin/python topic_map.py       # evaluation 2: topic_map.json, interest_owner.json, topics_pie_owner_*.png
.venv/bin/python report_tables.py   # report_tables.md
```

`INTEREST_EVAL_OUT` overrides the output folder. Models download into the Hugging Face cache. EmbeddingGemma needs
accepted Gemma terms and an HF token, and is skipped otherwise. voyage-4-lite is never called.

## Files

- `common.py`: corpus and library loading, recency weights from `PERSONALIZED_FEED.md`.
- `embed.py`: gte-small, bge-small-en-v1.5 and SPECTER2 (proximity adapter, `title [SEP] abstract`). It records
  throughput and disk size.
- `eval_ranking.py`: leave-one-out ranking against the Feed pool, with the mean, kNN-3, multi-centroid and blend
  scorers, bootstrap CIs and a category-neighbour proxy.
- `topic_map.py`: nested k-means map (20 / ~size÷150 / ~size÷40), c-TF-IDF labels, lift-based topic selection
  (proposal and relaxed thresholds), generic contrasts, sample per-topic For-you sections and pie charts.
- `report_tables.py`: renders the JSON outputs as Markdown tables.
