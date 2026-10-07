-- Import progress a reader can follow (owner, 2026-10-07: "ideally, we have an estimate of the total time,
-- and have a percent done, with stages that make more sense to the user"). Design:
-- docs/architecture/IMPORT_PROGRESS.md. Additive over 014/019/022; composes with whatever import entry
-- earlier migrations define (the function is kept under another name and extended, not rewritten).
--
-- Wire: an active import's library entry gains a top-level `progress_detail`, e.g.
--   {"step":"reading_equations","percent":62,"eta_seconds":40,"pages_done":17,"pages":27}
-- step: finding | downloading | reading_equations | preparing | waiting; percent 0-99, never lower than the
-- import's previous value in the same attempt; eta_seconds only when the estimate can be trusted, otherwise
-- `delayed: true`; pages (what is being read), pages_done (provider progress) and bytes (PDF size) once known.
-- Without `pages` the estimate is for a typical paper. The detail is stored on the import and changes only
-- with a new state_seq, so an entry's JSON at a given state_seq never changes. Entries without a stored
-- detail (every item, finished imports, imports created before this migration) keep byte-identical JSON;
-- builds before this ignore the key.
--
-- Estimate: per-stage times from pipeline_events (30-day medians with at least 5 samples, else defaults
-- measured on staging 2026-10-07), OCR and rendering scaled by the paper's pages, and during OCR the
-- provider's own page progress. Profile cached for 15 minutes.
--
-- Updates: every new state_seq of an active import recomputes the detail (stage changes already project
-- with one). Between stages the worker reports what it sees (worker_pipeline_progress); each import is
-- re-projected at most every 5 s, only when the reader would see something new (step, page, size, or an
-- estimate that drifted from the reader's own count-down), and within the per-account 'library-progress'
-- rate, separate from library writes. A skipped projection never fails anything.
begin;
set local lock_timeout='15s';

insert into app_private.api_rate_rules values('library-progress',3600,720,6000) on conflict(route) do nothing;

-- What the worker last saw of a paper's current stage. Separate from the paper row so recording it never
-- locks the paper (projection runs without holding it, like worker_pipeline_sync_imports).
create table app_private.pipeline_observations (
 paper_id uuid primary key references app_private.pipeline_papers(id),
 stage text not null,
 pages_done integer check(pages_done between 0 and 250),
 pages integer check(pages between 1 and 250),
 bytes bigint check(bytes between 1 and 67108864),
 observed_at timestamptz not null,
 check(pages_done is null or pages is null or pages_done<=pages)
);
alter table app_private.pipeline_observations enable row level security;
revoke all on app_private.pipeline_observations from public,anon,authenticated;

-- Measured stage times (see pipeline_measure_timing), refreshed at most every 15 minutes.
create table app_private.pipeline_timing (
 singleton boolean primary key default true check(singleton),
 profile jsonb not null check(jsonb_typeof(profile)='object' and octet_length(profile::text)<=4096),
 computed_at timestamptz not null
);
alter table app_private.pipeline_timing enable row level security;
revoke all on app_private.pipeline_timing from public,anon,authenticated;

alter table app_private.import_requests
 add column progress_detail jsonb check(progress_detail is null or (jsonb_typeof(progress_detail)='object' and octet_length(progress_detail::text)<=512)),
 add column progress_at timestamptz;

-- Defaults, from the staging canary of 2026-10-07 (26 pages: download 5 s, OCR 21 s, render 10 s) and the
-- arXiv pacing (two metadata requests 3 s apart). Milliseconds; OCR and render add a time per page.
create function app_private.pipeline_timing_defaults() returns jsonb language sql immutable set search_path='' as $$
 select '{"metadata":{"ms":5000},"download":{"ms":6000},"ocr_fund":{"ms":1500},"ocr_submit":{"ms":3000},
  "ocr_wait":{"ms":5000,"per_page_ms":800},"render":{"ms":3000,"per_page_ms":300},"done":{"ms":1500},"pages":20}'::jsonb
$$;
insert into app_private.pipeline_timing values(true,app_private.pipeline_timing_defaults(),'-infinity');

-- Stage times of the last 30 days: the median time a paper spent in a stage before moving on (failures
-- excluded); for OCR and rendering, the median time per page beyond the stage's fixed part. A stage with
-- fewer than 5 samples keeps its default. `pages`: the median page count of recent papers.
create function app_private.pipeline_measure_timing() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare d jsonb:=app_private.pipeline_timing_defaults(); result jsonb:=app_private.pipeline_timing_defaults(); r record; cap integer; typical integer;
begin
 select max_ocr_pages into strict cap from app_private.pipeline_policy;
 for r in select e.stage,count(*) n,percentile_cont(0.5) within group (order by e.duration_ms) ms from app_private.pipeline_events e
  where e.kind='stage' and e.at>now()-interval '30 days' and e.next_stage is distinct from 'failed' and e.duration_ms is not null
   and e.stage in ('metadata','download','ocr_fund','ocr_submit') group by e.stage having count(*)>=5 loop
  result:=jsonb_set(result,array[r.stage],jsonb_build_object('ms',least(600000,round(r.ms))::bigint,'n',r.n));
 end loop;
 for r in select e.stage,count(*) n,percentile_cont(0.5) within group (order by
    greatest(0,e.duration_ms-(d->e.stage->>'ms')::bigint)::double precision/least(pp.page_count,cap)) per_page
  from app_private.pipeline_events e join app_private.pipeline_papers pp on pp.id=e.paper_id
  where e.kind='stage' and e.at>now()-interval '30 days' and e.next_stage is distinct from 'failed' and e.duration_ms is not null
   and e.stage in ('ocr_wait','render') and pp.page_count is not null group by e.stage having count(*)>=5 loop
  result:=jsonb_set(result,array[r.stage],jsonb_build_object('ms',(d->r.stage->>'ms')::bigint,
   'per_page_ms',least(20000,greatest(50,round(r.per_page)))::bigint,'n',r.n));
 end loop;
 select round(percentile_cont(0.5) within group (order by page_count))::integer into typical from app_private.pipeline_papers
  where created_at>now()-interval '30 days' and page_count is not null having count(*)>=5;
 return jsonb_set(result,'{pages}',to_jsonb(least(250,greatest(1,coalesce(typical,(d->>'pages')::integer)))));
end $$;

-- The cached profile; one transaction refreshes it when stale, the others use what is there.
create function app_private.pipeline_timing_profile() returns jsonb language plpgsql security definer set search_path='' as $$
declare t app_private.pipeline_timing; fresh jsonb;
begin
 select * into t from app_private.pipeline_timing where singleton;
 if not found then return app_private.pipeline_timing_defaults(); end if;
 if t.computed_at>now()-interval '15 minutes' then return t.profile; end if;
 perform 1 from app_private.pipeline_timing where singleton for update skip locked;
 if not found then return t.profile; end if;
 fresh:=app_private.pipeline_measure_timing();
 update app_private.pipeline_timing set profile=fresh,computed_at=now() where singleton;
 return fresh;
end $$;

-- A paper's progress as a reader sees it: the step, percent of the expected total time done, and the time
-- left. Null when the paper isn't heading anywhere (source only, failed without a resume stage).
create function app_private.pipeline_estimate(p app_private.pipeline_papers) returns jsonb
language plpgsql security definer set search_path='' as $$
declare prof jsonb:=app_private.pipeline_timing_profile(); cap integer; n_pages integer; known boolean;
 stages constant text[]:=array['metadata','download','ocr_fund','ocr_submit','ocr_wait','render','done'];
 cur text; idx integer; e double precision; expected double precision[]:='{}'; total double precision:=0; before double precision:=0;
 after double precision:=0; elapsed double precision:=0; frac double precision; remaining double precision; done_share double precision;
 o app_private.pipeline_observations; delayed boolean:=false; st text; step text; pct integer; seen_pages integer;
begin
 select max_ocr_pages into strict cap from app_private.pipeline_policy;
 cur:=case when p.stage in ('failed','needs_credits') then p.resume_stage when p.stage='private_split' then 'download'
  when p.stage='ocr_uncertain' then 'ocr_wait' when p.stage=any(stages) then p.stage end;
 if cur is null then return null; end if;
 -- A paused or split paper is about to (re)start its stage; otherwise time counts from entering it.
 if p.stage=cur then elapsed:=greatest(0,extract(epoch from clock_timestamp()-p.stage_entered_at)); end if;
 select * into o from app_private.pipeline_observations where paper_id=p.id and stage=p.stage;
 known:=p.page_count is not null or o.pages is not null;
 n_pages:=least(cap,coalesce(o.pages,p.page_count,(prof->>'pages')::integer));
 foreach st in array stages loop
  e:=coalesce((prof->st->>'ms')::double precision,1000)/1000+coalesce((prof->st->>'per_page_ms')::double precision,0)*n_pages/1000;
  expected:=expected||greatest(e,0.5);
  total:=total+greatest(e,0.5);
 end loop;
 idx:=array_position(stages,cur);
 for n in 1..array_length(stages,1) loop
  if n<idx then before:=before+expected[n]; elsif n>idx then after:=after+expected[n]; end if;
 end loop;
 e:=expected[idx];
 frac:=least(0.9,elapsed/e);
 remaining:=greatest(e-elapsed,0.1*e);
 -- During OCR the provider's page count is the better guide, once a quarter of the pages are done.
 if cur='ocr_wait' and o.pages_done is not null and o.pages>0 then
  done_share:=o.pages_done::double precision/o.pages;
  frac:=greatest(frac,0.85*done_share);
  if done_share>=0.25 and elapsed>=5 then remaining:=elapsed*(1-done_share)/done_share+3; end if;
 end if;
 remaining:=greatest(1,remaining);
 -- Backing off after errors or crashes, paused, or far beyond the usual time: no trustworthy estimate.
 delayed:=coalesce(p.failures,0)>0 or coalesce(p.stage_crashes,0)>0 or p.error_code is not distinct from 'service_paused'
  or p.stage='ocr_uncertain' or (p.stage=cur and coalesce(p.next_attempt_at>clock_timestamp()+interval '60 seconds',false)) or elapsed>3*e+60;
 step:=case when p.error_code is not distinct from 'service_paused' then 'waiting' when cur='metadata' then 'finding' when cur='download' then 'downloading'
  when cur in ('ocr_fund','ocr_submit','ocr_wait') then 'reading_equations' else 'preparing' end;
 pct:=least(99,greatest(0,floor(100*(before+frac*e)/total)))::integer;
 seen_pages:=case when known then n_pages end;
 return jsonb_strip_nulls(jsonb_build_object('step',step,'percent',pct,
  'eta_seconds',case when not delayed then ceil(remaining+after)::integer end,'delayed',case when delayed then true end,
  'pages',seen_pages,'pages_done',case when cur='ocr_wait' and o.pages_done is not null and seen_pages is not null then least(o.pages_done,seen_pages) end,
  'bytes',case when cur='download' then o.bytes end));
end $$;

-- An import's detail: its paper's estimate (before the import is linked, the shared paper already under
-- way for its source, else a paper that has just started), never below `p_floor_from`'s percent.
create function app_private.import_progress_detail(i app_private.import_requests,p_floor_from jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; d jsonb;
begin
 select pp.* into p from app_private.pipeline_imports pi join app_private.pipeline_papers pp on pp.id=pi.paper_id
  where (pi.account_id,pi.import_id)=(i.account_id,i.id);
 if not found then
  select * into p from app_private.pipeline_papers where owner_id is null and source_id=i.source_id and requested_revision=coalesce(i.requested_revision,0)
   and stage not in ('private_split','failed','needs_credits','source_only');
  if not found then
   p.id:=null; p.stage:='metadata'; p.stage_entered_at:=clock_timestamp(); p.failures:=0; p.stage_crashes:=0; p.next_attempt_at:=clock_timestamp();
  end if;
 end if;
 d:=app_private.pipeline_estimate(p);
 if d is null then return null; end if;
 if jsonb_typeof(p_floor_from->'percent')='number' and (p_floor_from->>'percent')::integer>(d->>'percent')::integer then
  d:=jsonb_set(d,'{percent}',p_floor_from->'percent');
 end if;
 return d;
end $$;

-- Every new state_seq of an import (and its creation) stamps the detail shown with it: recomputed while the
-- import is active (the floor carries over within an attempt; a retry starts again), cleared otherwise.
create function app_private.import_progress_stamp() returns trigger language plpgsql security definer set search_path='' as $$
declare floor_from jsonb;
begin
 if tg_op='UPDATE' then
  if new.state_seq is not distinct from old.state_seq then return new; end if;
  if old.desired_present and old.phase in ('accepted','resolving','acquiring') and old.intent_revision=new.intent_revision then
   floor_from:=old.progress_detail;
  end if;
 end if;
 if new.desired_present and new.phase in ('accepted','resolving','acquiring') then
  new.progress_detail:=app_private.import_progress_detail(new,floor_from);
  new.progress_at:=clock_timestamp();
 else
  new.progress_detail:=null; new.progress_at:=null;
 end if;
 return new;
end $$;
create trigger import_progress_stamp before insert or update of state_seq on app_private.import_requests
 for each row execute function app_private.import_progress_stamp();

-- Whether a reader would see something new. Clients move the bar and count the time down from when they
-- received a detail (percent + (99 - percent) * min(1, elapsed / eta), eta - elapsed); a new detail is worth
-- sending when a visible fact changed or the estimate drifted from that count-down.
create function app_private.import_progress_news(p_old jsonb,p_old_at timestamptz,p_new jsonb) returns boolean
language plpgsql stable set search_path='' as $$
declare since double precision; old_eta double precision; shown_pct double precision;
begin
 if p_new is null then return false; end if;
 if p_old is null or p_old_at is null then return true; end if;
 if p_new->'step' is distinct from p_old->'step' or p_new->'pages' is distinct from p_old->'pages'
  or p_new->'pages_done' is distinct from p_old->'pages_done' or p_new->'bytes' is distinct from p_old->'bytes'
  or p_new->'delayed' is distinct from p_old->'delayed' or (p_new ? 'eta_seconds')<>(p_old ? 'eta_seconds') then return true; end if;
 since:=greatest(0,extract(epoch from clock_timestamp()-p_old_at));
 shown_pct:=(p_old->>'percent')::double precision;
 old_eta:=(p_old->>'eta_seconds')::double precision;
 if old_eta>0 then
  shown_pct:=shown_pct+(99-shown_pct)*least(1,since/old_eta);
  if abs((p_new->>'eta_seconds')::double precision-greatest(0,old_eta-since))>=greatest(10,0.25*greatest(0,old_eta-since)) then return true; end if;
 end if;
 return abs((p_new->>'percent')::double precision-shown_pct)>=5;
end $$;

-- The worker's view of the current stage (provider pages, PDF size), and a progress projection for each
-- linked active import that is due (5 s since its last detail), has news, and is within its account's
-- progress rate. Fenced like worker_pipeline_sync_imports: the current claim, without locking the paper.
-- Accounts are locked first in id order, then the library state per import (the customer order).
create function public.worker_pipeline_progress(p_paper_id uuid,p_claim_id uuid,p_generation bigint,
 p_pages_done integer default null,p_pages integer default null,p_bytes bigint default null) returns integer
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; link record; imp app_private.import_requests; acct uuid; due uuid[]:='{}'; ready uuid[]:='{}';
 s bigint; changed integer:=0;
begin
 select * into p from app_private.pipeline_papers where id=p_paper_id;
 if not found or p.claim_id is distinct from p_claim_id or p.generation is distinct from p_generation or p.lease_until<=clock_timestamp()
 then raise exception 'stale_pipeline_claim'; end if;
 if p_pages_done not between 0 and 250 or p_pages not between 1 and 250 or p_pages_done>p_pages or p_bytes not between 1 and 67108864
 then raise exception 'invalid_progress'; end if;
 insert into app_private.pipeline_observations as o(paper_id,stage,pages_done,pages,bytes,observed_at)
  values(p.id,p.stage,p_pages_done,p_pages,p_bytes,clock_timestamp())
  on conflict(paper_id) do update set stage=excluded.stage,observed_at=excluded.observed_at,
   pages=case when o.stage=excluded.stage then coalesce(excluded.pages,o.pages) else excluded.pages end,
   pages_done=case when o.stage=excluded.stage then coalesce(excluded.pages_done,o.pages_done) else excluded.pages_done end,
   bytes=case when o.stage=excluded.stage then coalesce(excluded.bytes,o.bytes) else excluded.bytes end;
 for link in select i.account_id,i.id,i.progress_detail,i.progress_at,i.intent_revision from app_private.pipeline_imports pi
  join app_private.import_requests i on (i.account_id,i.id)=(pi.account_id,pi.import_id)
  where pi.paper_id=p.id and i.desired_present and i.phase in ('accepted','resolving','acquiring')
   and (i.progress_at is null or i.progress_at<=clock_timestamp()-interval '5 seconds') order by i.account_id,i.id loop
  select * into imp from app_private.import_requests where account_id=link.account_id and id=link.id;
  if app_private.import_progress_news(link.progress_detail,link.progress_at,app_private.import_progress_detail(imp,link.progress_detail))
   and not link.account_id=any(due) then due:=due||link.account_id; end if;
 end loop;
 foreach acct in array due loop
  begin
   perform public.worker_consume_request(acct,'library-progress');
   ready:=ready||acct;
  exception when others then null;  -- over the progress rate (or closed): this projection is skipped
  end;
 end loop;
 if cardinality(ready)=0 then return 0; end if;
 perform 1 from app_private.accounts where id=any(ready) and closed_at is null order by id for no key update;
 for link in select pi.account_id,pi.import_id from app_private.pipeline_imports pi where pi.paper_id=p.id and pi.account_id=any(ready)
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
  exception when others then null;  -- progress never fails the paper or other imports
  end;
 end loop;
 return changed;
end $$;

-- The import entry, plus `progress_detail` while one is stored (active imports only; see the header).
alter function app_private.library_import_entry(uuid,uuid) rename to library_import_entry_base;
create function app_private.library_import_entry(a uuid,p_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select app_private.library_import_entry_base(a,p_id)||coalesce((select jsonb_build_object('progress_detail',i.progress_detail)
  from app_private.import_requests i where i.account_id=a and i.id=p_id and i.progress_detail is not null
  and i.desired_present and i.phase in ('accepted','resolving','acquiring')),'{}'::jsonb)
$$;

revoke all on all functions in schema app_private from public,anon,authenticated,service_role;
revoke all on function public.worker_pipeline_progress(uuid,uuid,bigint,integer,integer,bigint) from public,anon,authenticated;
grant execute on function public.worker_pipeline_progress(uuid,uuid,bigint,integer,integer,bigint) to service_role;
notify pgrst,'reload schema';
commit;
