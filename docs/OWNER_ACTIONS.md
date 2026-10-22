# Waiting on the owner

Open items only the owner can do or decide, collected 2026-10-22 UTC. None is urgent; each says what is needed, why,
and the default Claude would choose. Remove an item when it is done or decided (record decisions in DECISIONS.md).

| # | Item | What's needed | Why | Default if no answer |
|---|---|---|---|---|
| 1 | Subfigure test labels | Tap through more figures on the private labeling page (https://claude.ai/artifact/6VAvKtgD8fC1LqDQuCAf3h): one tap inside each lettered panel, or Single figure / Exclude. 22 done; 60–100 for a first number, 200+ for a solid one. | The only independent test of whether figure zooms land on the right panel (DECISIONS.md "Subfigures: rough zoom is the goal"). | Wait; no release claim about subfigure accuracy until scored. |
| 2 | Recovery code in TestFlight feedback | Delete the build-75 feedback item with no comment (2026-10-19 ~16:31 UTC) in App Store Connect › Gradstep › TestFlight › Feedback; it shows the full recovery code. | The code sits in Apple's systems and the app cannot rotate a recovery code yet. | Offer to build "Create new recovery code". |
| 3 | On-device PDF display formulas | Keep the confidence threshold (≈41% typeset, 89% correct) or lower it (≈72% typeset, 85% correct). | Trade between more typeset maths and more misread equations (docs/reviews/DEVICE_PDF_ROUTE_20261021.md). | Keep. |
| 4 | Figure part count check | Agreement with either the caption's letters or the figure's sub-images (today), or require both. | Both is safer but falls back to the whole figure more often. | Either. |
| 5 | Taller Paper/Chat/Settings screens | Replace the system navigation bar with Gradstep's own header (like Library) so header icons can sit higher (build-78 feedback 15:11). | Medium change touching back-swipe and Mac behavior. | Skip unless wanted. |
| 6 | Terms of Service and privacy policy | Decide whether Claude drafts both from what the app does (OpenRouter AI, encrypted snippets, device-side arXiv), for a lawyer's review before public launch. | App Store review expects a privacy policy; the app links only Apple's standard license today. | Draft before public launch. |
| 7 | Per-feature OpenRouter keys (optional) | Create keys for tags and podcasts with their own limits; add `OPENROUTER_TAGS_API_KEY` and `OPENROUTER_PODCAST_API_KEY` to `.env.providers`. | Per-feature spend in OpenRouter's dashboard; a podcast runaway can't drain chat. Per-user costs are already in Admin › Costs. | Single key (works today). |
| 8 | Device testing | Resume physical-iPhone testing when convenient (paused since 2026-10-03); builds 78–80 add Snippets, the figure top row, zoomable figure parts, recommendations and the faster on-device PDF route. If TestFlight screenshot feedback is missing, check TestFlight › Gradstep › Send Beta Feedback. | Nothing since build 77 has been verified on a real device. | Simulator only. |
