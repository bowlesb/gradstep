-- Interest index delivery limits for interest_policy.serving 'all' at the scale target of 100–1,000 readers
-- (docs/architecture/INTEREST_INDEX.md, "Serving to all"; owner approval of the privacy notice and of 'all', 2026-10-25).
--
-- What the app (TestFlight 92) asks for, per reader (InterestIndexClient, LibraryInterest, FeedRelated):
-- - `interest-index` (the Edge function's manifest and artifacts): a manifest at most every 10 minutes while the Library's
--   topics or a Feed paper's related papers are worked out, so up to 6 in an hour of use; each artifact once per digest,
--   kept on disk (first use: the map and term statistics, plus the window's shards, 3 today, when related papers are
--   first shown; then about one shard a day and the map and terms again after each rebuild).
-- - `interest-library` (v1_interest_library_fingerprints): at least one call per app launch (a page per 500 papers),
--   then at most one every 10 minutes while some library paper has no fingerprint yet.
-- The environment limits (0152: 4,000 and 1,000 an hour) bind first: about 650 readers using the app in the same clock
-- hour fill `interest-index`, and one launch each by 1,000 readers in the same hour fills `interest-library`. Past the
-- limit every reader gets 429 for the rest of that hour (topics hide, related papers fall back to the Feed results).
-- Measured on staging so far (owner only): at most 12 and 7 requests in an hour.
--
-- New environment limits: `interest-index` 10,000 an hour (the column's maximum, as `library-read` and `sync-read`),
-- `interest-library` 5,000. Per-account limits are unchanged (240 and 60 an hour).
-- Cost: expected use is unchanged, about 16–22 MB a month per active device (≈ 20 GB at 1,000 devices, inside the Pro
-- plan's 250 GB of egress: $0). The limits are ceilings. If many accounts saturated them, each still held to its own
-- limit, the worst-case egress would rise from ≈ 5.5 to ≈ 13.7 GB an hour for `interest-index` (every request the
-- largest artifact today, 1.37 MB; ≈ 16 GB with the ≈ 1.6 MB map expected at steady state) and from ≈ 0.3 to ≈ 1.6 GB
-- an hour for `interest-library` (≤ 500 papers × ≈ 650 B a call): ≈ $1.4 instead of ≈ $0.5 an hour at $0.09/GB once
-- past the included egress. Admin Health shows the index's delivery requests and accounts over 24 hours.
begin;
set local lock_timeout='15s';

do $$ begin
 if (select count(*) from app_private.api_rate_rules
     where (route='interest-index' and window_seconds=3600 and account_limit=240)
        or (route='interest-library' and window_seconds=3600 and account_limit=60))<>2 then
  raise exception 'interest_rate_rules_unexpected';
 end if;
end $$;

update app_private.api_rate_rules set environment_limit=10000 where route='interest-index';
update app_private.api_rate_rules set environment_limit=5000 where route='interest-library';
commit;
