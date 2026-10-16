# Recorded lookup answers

DataCite and Crossref answers for the server's paper lookups (Ingest, Add by text or DOI, a reference's Add to
library), which replaced arXiv's API in rollout step 5 (docs/architecture/ARXIV_DEVICE_ONLY.md). Recorded once from a
developer machine; no request went to arXiv.

- datacite-title-dpo-phrase.json: https://api.datacite.org/dois?query=titles.title%3A%22direct+preference+optimization+your+language+model+is+secretly+a+reward+model%22&provider-id=arxiv&sort=name&page%5Bsize%5D=5&disable-facets=true&fields%5Bdois%5D=doi%2Ctitles%2Ccreators%2Cdescriptions%2Csubjects%2Cversion%2Cdates%2CpublicationYear (recorded 2026-10-16T02:03:33.610Z, HTTP 200, 4238 bytes)
- datacite-title-dpo-words.json: https://api.datacite.org/dois?query=titles.title%3A%28direct+AND+preference+AND+optimization+AND+your+AND+language+AND+model+AND+secretly+AND+reward+AND+model%29&provider-id=arxiv&sort=relevance&page%5Bsize%5D=10&disable-facets=true&fields%5Bdois%5D=doi%2Ctitles%2Ccreators%2Cdescriptions%2Csubjects%2Cversion%2Cdates%2CpublicationYear (recorded 2026-10-16T02:03:35.526Z, HTTP 200, 4271 bytes)
- datacite-title-optuna-phrase.json: https://api.datacite.org/dois?query=titles.title%3A%22optuna+a+next+generation+hyperparameter+optimization+framework%22&provider-id=arxiv&sort=name&page%5Bsize%5D=5&disable-facets=true&fields%5Bdois%5D=doi%2Ctitles%2Ccreators%2Cdescriptions%2Csubjects%2Cversion%2Cdates%2CpublicationYear (recorded 2026-10-16T02:03:37.095Z, HTTP 200, 3280 bytes)
- datacite-title-optuna-words.json: https://api.datacite.org/dois?query=titles.title%3A%28optuna+AND+next+AND+generation+AND+hyperparameter+AND+optimization+AND+framework%29&provider-id=arxiv&sort=relevance&page%5Bsize%5D=10&disable-facets=true&fields%5Bdois%5D=doi%2Ctitles%2Ccreators%2Cdescriptions%2Csubjects%2Cversion%2Cdates%2CpublicationYear (recorded 2026-10-16T02:03:39.144Z, HTTP 200, 3304 bytes)
- datacite-ids-cot-dpo.json: https://api.datacite.org/dois?ids=10.48550%2FarXiv.2201.11903%2C10.48550%2FarXiv.2305.18290&page%5Bsize%5D=2 (recorded 2026-10-16T02:03:40.548Z, HTTP 200, 10100 bytes)
- datacite-id-1706.03762.json: https://api.datacite.org/dois/10.48550/arXiv.1706.03762 (recorded 2026-10-16T02:03:41.738Z, HTTP 200, 15812 bytes)
- crossref-10.1145-3292500.3330701.json: https://api.crossref.org/works/10.1145%2F3292500.3330701?mailto=hello@gradstep.ai (recorded 2026-10-16T02:03:43.042Z, HTTP 200, 10388 bytes)
- datacite-id-2204.02311.json: https://api.datacite.org/dois/10.48550/arXiv.2204.02311 (recorded 2026-10-16T02:04:41.824Z, HTTP 200, 33885 bytes)
