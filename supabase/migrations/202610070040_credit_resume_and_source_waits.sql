-- Owner feedback, build 16 (docs/OWNER_FEEDBACK.md #1, #10). Additive over 014/022/027/029/034.
--
-- 1. Imports waiting on credits resume by themselves (#1). An account's imports that stopped with
--    `insufficient_credits` (paper `needs_credits`) restart once its spendable balance covers them, oldest
--    first, skipping any the balance cannot cover. The trigger is state, not an event: a sweep before each
--    claim (worker_pipeline_resume_credits, at most every few seconds) looks for accounts whose balance now
--    covers a waiting import, so every way a balance grows is covered (purchase, restore, refund reversal,
--    owner grant, tester credits, a plan period that starts, a hold released). A balance increase also
--    wakes the worker at once (trigger on credit_buckets). A restart is the reader's Retry as a worker
--    checkpoint (027's pipeline_auto_retry_import: new state_seq, intent revision unchanged), so funding
--    is unchanged: the paper resumes at its stage and worker_pipeline_fund reserves credits exactly once.
--    Cost estimate = what funding will require: least(pages, max_ocr_pages) x ocr_credits_per_page at
--    ocr_fund, 1 credit for a private download's admission (016). Suspended and closed accounts are
--    never resumed (funding would refuse them, which would loop).
--
--    Lock order (SPENDING_CONTROLS.md): unlocked snapshot -> accounts in id order (NO KEY UPDATE; grants
--    and purchases take them FOR UPDATE, so a balance cannot change under the sweep) -> pipeline_policy
--    throttle row -> library locks per import (027's order). No budget, bucket, purchase gate or paper
--    row is locked. The balance trigger only reads imports and queues a pg_net wakeup (a leaf insert).
--
-- 2. Waiting for a busy source is shown as waiting (#10). A paper deferred because its source is
--    throttling us (arXiv 429/503, unreachable) at metadata or download reports step `waiting`,
--    `delayed: true` and `reason: "source_busy"` instead of an estimate the app counts towards 99 %, and
--    worker_pipeline_project_progress lets the worker tell readers right after deferring (unfenced: it
--    only re-projects from current state, under the same 5 s throttle, news rule and progress rate as
--    worker_pipeline_progress).
begin;
set local lock_timeout='15s';

alter table app_private.pipeline_policy add column credit_resume_swept_at timestamptz not null default '-infinity';
create index import_requests_waiting_credits on app_private.import_requests(account_id,created_at,id)
 where phase='failed' and retryable and desired_present and error_code='insufficient_credits';

-- Credits funding needs before this paper can move on from needs_credits (null: not waiting on credits).
create function app_private.pipeline_credit_need(p app_private.pipeline_papers,pol app_private.pipeline_policy) returns bigint
language sql stable set search_path='' as $$
 select case when p.stage<>'needs_credits' then null
  when p.resume_stage='ocr_fund' then greatest(1,least(coalesce(p.page_count,pol.max_ocr_pages),pol.max_ocr_pages)::bigint*pol.ocr_credits_per_page)
  when p.resume_stage='download' then 1 end
$$;

-- Spendable credits (as reservations count them) less what this account's already restarted, not yet
-- funded imports will need: their papers still wait to be claimed (needs_credits) or are about to fund
-- (ocr_fund). Conservative for a shared paper several accounts restarted (each counts it).
create function app_private.account_credit_headroom(a uuid) returns bigint language sql stable security definer set search_path='' as $$
 select coalesce((select sum(balance-reserved) filter(where revoked_at is null and starts_at<=now() and (expires_at is null or expires_at>now()))
   from app_private.credit_buckets where account_id=a),0)
  -coalesce((select sum(x.need) from (
   select distinct pp.id,case when pp.stage='needs_credits' then app_private.pipeline_credit_need(pp,pol)
    else greatest(1,least(coalesce(pp.page_count,pol.max_ocr_pages),pol.max_ocr_pages)::bigint*pol.ocr_credits_per_page) end need
   from app_private.import_requests i
   join app_private.pipeline_imports pi on (pi.account_id,pi.import_id)=(i.account_id,i.id)
   join app_private.pipeline_papers pp on pp.id=pi.paper_id
   cross join app_private.pipeline_policy pol
   where i.account_id=a and i.desired_present and i.phase in ('accepted','resolving','acquiring')
    and pp.stage in ('needs_credits','ocr_fund')) x),0)
$$;

-- An account's imports waiting on credits, oldest first, with what each needs.
create function app_private.credit_waiting_imports(a uuid) returns table(import_id uuid,paper_id uuid,need bigint)
language sql stable security definer set search_path='' as $$
 select i.id,pp.id,app_private.pipeline_credit_need(pp,pol)
 from app_private.import_requests i
 join app_private.pipeline_imports pi on (pi.account_id,pi.import_id)=(i.account_id,i.id)
 join app_private.pipeline_papers pp on pp.id=pi.paper_id
 cross join app_private.pipeline_policy pol
 where i.account_id=a and i.phase='failed' and i.retryable and i.desired_present and i.error_code='insufficient_credits'
  and pp.stage='needs_credits' and app_private.pipeline_credit_need(pp,pol) is not null
 order by i.created_at,i.id
 limit 100
$$;

create function public.worker_pipeline_resume_credits(p_min_interval_seconds integer default 0,p_limit integer default 20) returns jsonb
language plpgsql security definer set search_path='' as $$
declare captured uuid[]; acct uuid; w record; available bigint; outcome text; counted uuid[]; resumed integer:=0; limited integer:=0; skipped integer:=0;
begin
 if p_min_interval_seconds is null or p_min_interval_seconds not between 0 and 3600 or p_limit is null or p_limit not between 1 and 100
 then raise exception 'invalid_resume_request'; end if;
 if not exists(select 1 from app_private.pipeline_policy where singleton and enabled
  and credit_resume_swept_at<=clock_timestamp()-make_interval(secs=>p_min_interval_seconds))
 then return jsonb_build_object('swept',false,'accounts',0,'resumed',0,'limited',0); end if;
 -- Unlocked, bounded snapshot: accounts whose spendable balance covers at least one waiting import.
 select coalesce(array_agg(x.account_id order by x.account_id),'{}') into captured from (
  select i.account_id from app_private.import_requests i
   join app_private.accounts a on a.id=i.account_id and a.closed_at is null and not a.spending_suspended
   join app_private.pipeline_imports pi on (pi.account_id,pi.import_id)=(i.account_id,i.id)
   join app_private.pipeline_papers pp on pp.id=pi.paper_id and pp.stage='needs_credits'
   cross join app_private.pipeline_policy pol
  where i.phase='failed' and i.retryable and i.desired_present and i.error_code='insufficient_credits'
  group by i.account_id
  having min(app_private.pipeline_credit_need(pp,pol))<=app_private.account_credit_headroom(i.account_id)
  order by min(i.created_at),i.account_id limit p_limit
 ) x;
 if cardinality(captured)=0 then return jsonb_build_object('swept',false,'accounts',0,'resumed',0,'limited',0); end if;
 -- Accounts first (closed rows too: a closure that won the race finishes before any import is touched),
 -- then the throttle mutex; only captured accounts are processed under these locks.
 perform 1 from app_private.accounts where id=any(captured) order by id for no key update;
 update app_private.pipeline_policy set credit_resume_swept_at=clock_timestamp()
  where singleton and enabled and credit_resume_swept_at<=clock_timestamp()-make_interval(secs=>p_min_interval_seconds);
 if not found then return jsonb_build_object('swept',false,'accounts',0,'resumed',0,'limited',0); end if;
 foreach acct in array captured loop
  if not exists(select 1 from app_private.accounts where id=acct and closed_at is null and not spending_suspended) then continue; end if;
  -- Stable while the account is locked: grants, purchases and reservations lock it FOR UPDATE.
  available:=app_private.account_credit_headroom(acct);
  counted:='{}';
  for w in select * from app_private.credit_waiting_imports(acct) loop
   -- One paper's funding is reserved once, however many of this account's imports wait on it.
   if w.paper_id=any(counted) then continue; end if;
   if w.need>available then skipped:=skipped+1; continue; end if;
   begin outcome:=app_private.pipeline_auto_retry_import(acct,w.import_id);
   exception when others then outcome:='skipped';
   end;
   if outcome='retried' then
    available:=available-w.need; counted:=counted||w.paper_id; resumed:=resumed+1;
   elsif outcome='limited' then limited:=limited+1; exit;  -- at the active-import limit: a later sweep continues
   end if;
  end loop;
 end loop;
 return jsonb_build_object('swept',true,'accounts',cardinality(captured),'resumed',resumed,'limited',limited,'unaffordable',skipped);
end $$;

-- A balance that grows (grant, purchase, restore, reversal) wakes the worker when the account has imports
-- waiting on credits. Reads only; the wakeup is queued by pg_net and sent after commit (014's kick).
create function app_private.credit_resume_kick() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from app_private.import_requests where account_id=new.account_id and phase='failed' and retryable
  and desired_present and error_code='insufficient_credits') then perform app_private.pipeline_kick(); end if;
 return null;
end $$;
create trigger credit_resume_kick after update of balance,revoked_at on app_private.credit_buckets
 for each row when (new.balance>old.balance or (old.revoked_at is not null and new.revoked_at is null))
 execute function app_private.credit_resume_kick();

-- 029's estimate, plus: a paper backing off because its source is throttling us (or unreachable) waits.
alter function app_private.pipeline_estimate(app_private.pipeline_papers) rename to pipeline_estimate_before_040;
create function app_private.pipeline_estimate(p app_private.pipeline_papers) returns jsonb
language plpgsql security definer set search_path='' as $$
declare d jsonb:=app_private.pipeline_estimate_before_040(p);
begin
 if d is null or p.stage not in ('metadata','download') or p.error_code is null
  or p.error_code not in ('rate_limited','source_unavailable') or coalesce(p.next_attempt_at<=clock_timestamp(),true) then return d; end if;
 return (d-'eta_seconds')||jsonb_build_object('step','waiting','delayed',true,'reason','source_busy');
end $$;

-- Re-projects the progress of a paper's active imports after the worker deferred it, so readers see a
-- wait as it starts. The second half of 029's worker_pipeline_progress (no observation, no fence: it only
-- recomputes from current state), with the same 5 s throttle, news rule, progress rate and lock order.
create function public.worker_pipeline_project_progress(p_paper_id uuid) returns integer
language plpgsql security definer set search_path='' as $$
declare link record; imp app_private.import_requests; acct uuid; due uuid[]:='{}'; ready uuid[]:='{}'; s bigint; changed integer:=0;
begin
 if p_paper_id is null then raise exception 'invalid_progress'; end if;
 for link in select i.account_id,i.id,i.progress_detail,i.progress_at from app_private.pipeline_imports pi
  join app_private.import_requests i on (i.account_id,i.id)=(pi.account_id,pi.import_id)
  where pi.paper_id=p_paper_id and i.desired_present and i.phase in ('accepted','resolving','acquiring')
   and (i.progress_at is null or i.progress_at<=clock_timestamp()-interval '5 seconds') order by i.account_id,i.id loop
  select * into imp from app_private.import_requests where account_id=link.account_id and id=link.id;
  if app_private.import_progress_news(link.progress_detail,link.progress_at,app_private.import_progress_detail(imp,link.progress_detail))
   and not link.account_id=any(due) then due:=due||link.account_id; end if;
 end loop;
 foreach acct in array due loop
  begin
   perform public.worker_consume_request(acct,'library-progress');
   ready:=ready||acct;
  exception when others then null;
  end;
 end loop;
 if cardinality(ready)=0 then return 0; end if;
 perform 1 from app_private.accounts where id=any(ready) and closed_at is null order by id for no key update;
 for link in select pi.account_id,pi.import_id from app_private.pipeline_imports pi where pi.paper_id=p_paper_id and pi.account_id=any(ready)
  order by pi.account_id,pi.import_id loop
  begin
   perform app_private.lock_library_state(link.account_id);
   select * into imp from app_private.import_requests where account_id=link.account_id and id=link.import_id;
   if imp.desired_present and imp.phase in ('accepted','resolving','acquiring')
    and (imp.progress_at is null or imp.progress_at<=clock_timestamp()-interval '5 seconds')
    and app_private.import_progress_news(imp.progress_detail,imp.progress_at,app_private.import_progress_detail(imp,imp.progress_detail)) then
    s:=app_private.library_next_seq(imp.account_id);
    update app_private.import_requests set state_seq=s where account_id=imp.account_id and id=imp.id;
    perform app_private.library_emit(imp.account_id,s,jsonb_build_array(app_private.library_import_entry(imp.account_id,imp.id)));
    changed:=changed+1;
   end if;
  exception when others then null;
  end;
 end loop;
 return changed;
end $$;

revoke all on all functions in schema app_private from public,anon,authenticated,service_role;
revoke all on function public.worker_pipeline_resume_credits(integer,integer),public.worker_pipeline_project_progress(uuid) from public,anon,authenticated;
grant execute on function public.worker_pipeline_resume_credits(integer,integer),public.worker_pipeline_project_progress(uuid) to service_role;
notify pgrst,'reload schema';
commit;
