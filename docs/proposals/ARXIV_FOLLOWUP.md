# Follow-up to arXiv support (ticket AH-211376) — draft for the owner to send

Status: draft, 2026-10-16. The owner sends it; nothing is sent automatically.

---

Hello,

Thank you for the clear answer on 15 October. We have since changed our design so that our servers never contact
arXiv: each reader's own device fetches the papers they open, and we added your acknowledgement and the product
disclaimer to the app, the browser version and our site. Two short questions so we stay well within your terms:

1. **Rate limits on readers' devices.** Each reader's device makes its own requests only when that person opens,
   searches for or adds a paper: one request at a time, at least 3 seconds apart, cached, backing off on 429/503 and
   stopping for 24 hours after a 403, identified as "Gradstep/<version> (+https://gradstep.ai; mailto:hello@gradstep.ai)".
   Our servers never ask devices to fetch anything for anyone else. Do you treat these requests like individual
   readers' browsers, or do they count together toward the limit for "machines under your control"?
2. **HTML papers on the device.** The device downloads a paper's official HTML version (exact version) and lays it
   out for reading on that device; it is not stored on or served from our servers, and every paper links to its
   versioned abstract page. Is that consistent with your expectations for the HTML papers?

We name arXiv only factually ("papers from arXiv", "View on arXiv"), use no arXiv logo, and our paper search is
called "ML paper search". If anything about how we acknowledge arXiv should change, we're glad to adjust.

Thank you,
Ben Bowles
