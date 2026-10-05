# Session review ledger

One row per reviewed session (see [SESSION_REVIEW.md](../SESSION_REVIEW.md)). Track whether the review gets more
reliable round by round: precision = confirmed / (confirmed + false); misses are problems the owner pointed out
later that the review did not find.

| Date | Session | Build | Length | Signals | Confirmed | False | Unsure | Fixed (tests) | Misses | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| 2026-10-05 | Simulator pipeline check | 0.1.0 (Debug) | 0:29 | 2 | — | — | — | — | — | Scripted: both planted problems (credits message, repeated taps) detected; sync found. Not an owner session. |
