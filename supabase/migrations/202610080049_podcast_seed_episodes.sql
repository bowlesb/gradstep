-- Seed episode cap counts episodes, not failed attempts (docs/architecture/PAPER_PODCASTS.md,
-- "Seed pilot runbook"). The owner approved "$2 total for two curated five-minute episodes".
-- 048 counted every seed job that made a paid provider attempt as one of the period's
-- max_episodes, so two failed jobs (staging, 2026-10-08: $0.44 spent) closed the pilot with
-- $1.56 of its $2 unspent. A seed episode now counts while its job is in flight (it may still
-- become an episode) or once it produced a release that is awaiting review or was published
-- (ready, or later superseded or quarantined). A failed, canceled or unknown-outcome job and a
-- release the operator rejected at review are not episodes.
--
-- The dollar cap is unchanged and stays the binding spend limit: worker_podcast_seed_admit
-- still refuses when podcast_seed_committed (unsettled ceilings, settled known spend including
-- failed jobs' actual usage, and every unresolved attempt ceiling) plus the profile's hold
-- exceeds limit_microusd (at most $2). Lock order and every caller are unchanged; the
-- signature and return type are the same, so callers (seed admission, operator status) need
-- no change.
begin;

create or replace function app_private.podcast_seed_episodes(p_period date) returns integer
language sql stable security definer set search_path='' as $$
 select count(*)::integer from app_private.podcast_jobs j
 where j.funding_kind='platform_seed' and j.seed_period=p_period
  and (j.state in ('queued','scripting','checking','synthesizing','verifying','publishing','capacity_wait')
   or exists(select 1 from app_private.podcast_releases r
    where r.job_id=j.id and r.state in ('pending_review','ready','superseded','quarantined')))
$$;

-- Internal helper: callable only through the security-definer RPCs, as in 048.
revoke all on function app_private.podcast_seed_episodes(date) from public,anon,authenticated,service_role;

notify pgrst,'reload schema';
commit;
