-- Self-healing downloads (owner, 2026-10-07: a "Download failed" must never just sit in a reader's
-- library). Design: docs/architecture/PIPELINE_RELIABILITY.md "Self-healing downloads". Additive over
-- 014/019/022.
--
-- 1. Automatic retry. A paper that fails at download for a reason that can change (host busy or
--    unreachable, bot check, no PDF at the link, gone, a crash loop) is retried 15 min, 2 h and 12 h
--    later (at most three automatic retries since its last successful download). Refusals that
--    cannot change (sign-in or paywall, too large) are not; every failure keeps the reader's Retry.
--    While a retry is scheduled its readers see `download_retrying` and, in the entry, a top-level
--    `auto_retry_at` (only then: every other entry's JSON is unchanged at every state_seq).
-- 2. Healing. A failed, retryable import whose paper has since moved on (another reader's retry, a
--    later import, an operator) goes back into the pipeline and follows the paper.
-- 3. After a deploy. worker_pipeline_retry_failed(deploy label) retries every failed paper that can
--    resume without charge (metadata, download, render; not too_large) once per label; the pipeline
--    worker's deploy script calls it, since a deploy is when a code bug stops being one.
--
-- A retry moves the import back into the pipeline exactly as the reader's Retry does (phase, new
-- state_seq, error cleared; the pipeline_link_import trigger asks the next claim to resume the
-- paper) but as a worker checkpoint: the intent revision is unchanged, so a reader's Cancel still
-- applies. The worker sweeps before each claim (worker_pipeline_auto_retry, at most every 20 s).
--
-- Lock order: pipeline_policy row (sweep throttle) -> due paper rows (SKIP LOCKED, unclaimed only)
-- -> accounts in id order -> document KEY SHARE -> library policy/state -> pipeline_imports. The
-- customer order (account -> document -> policy) is a suffix; claims skip locked papers.
begin;
set local lock_timeout='15s';

alter table app_private.pipeline_papers
 add column auto_retries integer not null default 0 check(auto_retries between 0 and 1000),
 add column auto_retry_at timestamptz,
 add column deploy_retry text check(deploy_retry ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'),
 add constraint pipeline_auto_retry_failed check(auto_retry_at is null or stage='failed');
create index pipeline_papers_auto_retry on app_private.pipeline_papers(auto_retry_at) where auto_retry_at is not null;
alter table app_private.pipeline_policy add column auto_retry_swept_at timestamptz not null default '-infinity';

alter table app_private.import_requests add column auto_retry_at timestamptz;
alter table app_private.import_requests drop constraint import_requests_error_code_check;
alter table app_private.import_requests add constraint import_requests_error_code_check check(error_code in
 ('metadata_unavailable','download_failed','pdf_invalid','rate_limited','license_unverified','membership_conflict',
  'insufficient_credits','conversion_failed','too_large',
  'download_retrying','source_unavailable','source_blocked','not_pdf','pdf_restricted'));
create index import_requests_retryable on app_private.import_requests(account_id,id) where phase='failed' and retryable and desired_present;

-- Entering 'failed' at download for a reason that can change schedules the next automatic retry;
-- leaving 'failed' cancels it; a download that succeeds starts the next failure's back-off afresh.
create function app_private.pipeline_auto_retry_schedule() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.stage='failed' then
  new.auto_retry_at:=case when new.resume_stage='download' and new.auto_retries<3
   and new.error_code in ('download_failed','source_unavailable','source_blocked','not_pdf','rate_limited')
   then clock_timestamp()+(array[interval '15 minutes',interval '2 hours',interval '12 hours'])[new.auto_retries+1] end;
 else
  new.auto_retry_at:=null;
  if old.stage='download' and new.stage not in ('failed','needs_credits') then new.auto_retries:=0; end if;
 end if;
 return new;
end $$;
create trigger pipeline_auto_retry_schedule before update of stage on app_private.pipeline_papers
 for each row when (old.stage is distinct from new.stage) execute function app_private.pipeline_auto_retry_schedule();

-- Failed, retryable, wanted imports of the given papers, and (p_heal) of papers that are no longer
-- failed. Open accounts only; bounded.
create function app_private.pipeline_retry_candidates(p_papers uuid[],p_heal boolean)
returns table(account_id uuid,import_id uuid,paper_id uuid,listed boolean) language sql stable security definer set search_path='' as $$
 select i.account_id,i.id,pi.paper_id,pi.paper_id=any(p_papers)
 from app_private.import_requests i
 join app_private.pipeline_imports pi on (pi.account_id,pi.import_id)=(i.account_id,i.id)
 join app_private.pipeline_papers pp on pp.id=pi.paper_id
 join app_private.accounts a on a.id=i.account_id and a.closed_at is null
 where i.phase='failed' and i.retryable and i.desired_present
  and (pp.id=any(p_papers) or (p_heal and pp.stage not in ('failed','needs_credits')))
 order by i.account_id,i.id
 limit 200
$$;

-- One import back into the pipeline, as the reader's Retry (010) does, but as a worker checkpoint:
-- new state_seq, intent revision unchanged. 'retried', 'limited' (the account or environment is at
-- its active-import limit; tried again later) or 'skipped' (no longer failed and retryable).
create function app_private.pipeline_auto_retry_import(a uuid,p_import uuid) returns text
language plpgsql security definer set search_path='' as $$
declare i app_private.import_requests; p app_private.library_policy; s bigint;
begin
 perform app_private.lock_library_account(a);
 select * into i from app_private.import_requests where account_id=a and id=p_import;
 if not found then return 'skipped'; end if;
 if i.document_id is not null then perform 1 from app_private.documents where id=i.document_id for key share; end if;
 perform app_private.lock_library_state(a);
 select * into strict i from app_private.import_requests where account_id=a and id=p_import;
 if i.phase<>'failed' or not i.retryable or not i.desired_present then return 'skipped'; end if;
 select * into strict p from app_private.library_policy;
 if (select count(*) from app_private.import_requests where account_id=a and desired_present and phase in ('accepted','resolving','acquiring'))+1>p.account_active_imports
 or (select count(*) from app_private.import_requests where desired_present and phase in ('accepted','resolving','acquiring'))+1>p.environment_active_imports
 then return 'limited'; end if;
 s:=app_private.library_next_seq(a);
 update app_private.import_requests set phase=case when metadata_id is null then 'accepted' else 'acquiring' end,
  error_code=null,retryable=false,auto_retry_at=null,state_seq=s where account_id=a and id=i.id;
 perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_import_entry(a,i.id)));
 return 'retried';
end $$;

-- Retries the candidates' imports, accounts locked in id order first. Returns, per listed paper,
-- 'retried' (at least one import moved), 'limited' or 'none', and how many imports were healed.
create function app_private.pipeline_retry_papers(p_papers uuid[],p_heal boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare link record; outcome text; outcomes jsonb:='{}'; healed integer:=0; key text;
begin
 perform 1 from app_private.accounts where id in (select c.account_id from app_private.pipeline_retry_candidates(p_papers,p_heal) c)
  and closed_at is null order by id for no key update;
 for link in select * from app_private.pipeline_retry_candidates(p_papers,p_heal) loop
  begin outcome:=app_private.pipeline_auto_retry_import(link.account_id,link.import_id);
  exception when others then outcome:='skipped';
  end;
  if link.listed then
   key:=link.paper_id::text;
   outcomes:=outcomes||jsonb_build_object(key,case when outcome='retried' or outcomes->>key='retried' then 'retried'
    when outcome='limited' or outcomes->>key='limited' then 'limited' else 'none' end);
  elsif outcome='retried' then healed:=healed+1;
  end if;
 end loop;
 return jsonb_build_object('papers',outcomes,'healed',healed);
end $$;

-- The worker's sweep before each claim (p_min_interval_seconds throttles concurrent workers).
-- Due papers are locked (claims skip them) while their imports move; a paper whose readers are at
-- their active-import limit waits 15 min more; one nobody waits for drops its schedule.
create function public.worker_pipeline_auto_retry(p_min_interval_seconds integer default 0,p_limit integer default 20) returns jsonb
language plpgsql security definer set search_path='' as $$
declare due uuid[]; result jsonb; outcome text; paper uuid; retried integer:=0; postponed integer:=0;
begin
 if p_min_interval_seconds is null or p_min_interval_seconds not between 0 and 3600 or p_limit is null or p_limit not between 1 and 100
 then raise exception 'invalid_auto_retry_request'; end if;
 update app_private.pipeline_policy set auto_retry_swept_at=clock_timestamp()
  where singleton and enabled and auto_retry_swept_at<=clock_timestamp()-make_interval(secs=>p_min_interval_seconds);
 if not found then return jsonb_build_object('swept',false,'retried',0,'healed',0,'postponed',0); end if;
 select coalesce(array_agg(x.id order by x.id),'{}') into due from (select pp.id from app_private.pipeline_papers pp
  where pp.auto_retry_at<=clock_timestamp() and pp.stage='failed' and (pp.lease_until is null or pp.lease_until<=clock_timestamp())
  order by pp.auto_retry_at,pp.id limit p_limit for no key update skip locked) x;
 result:=app_private.pipeline_retry_papers(due,true);
 foreach paper in array due loop
  outcome:=coalesce(result->'papers'->>paper::text,'none');
  update app_private.pipeline_papers set auto_retry_at=case when outcome='limited' then clock_timestamp()+interval '15 minutes' end,
   auto_retries=auto_retries+case when outcome='retried' then 1 else 0 end where id=paper;
  if outcome='retried' then retried:=retried+1; elsif outcome='limited' then postponed:=postponed+1; end if;
 end loop;
 return jsonb_build_object('swept',true,'retried',retried,'healed',(result->>'healed')::integer,'postponed',postponed);
end $$;

-- After a pipeline worker deploy: every failed paper that can resume without charge is retried
-- once per deploy label (a sign-in or bot refusal may have been our bug); automatic retry counts
-- are unchanged. Also heals imports whose paper has moved on.
create function public.worker_pipeline_retry_failed(p_deploy text,p_limit integer default 200) returns jsonb
language plpgsql security definer set search_path='' as $$
declare papers uuid[]; result jsonb;
begin
 if p_deploy is null or p_deploy !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$' or p_limit is null or p_limit not between 1 and 1000
 then raise exception 'invalid_retry_request'; end if;
 if not (select enabled from app_private.pipeline_policy) then return jsonb_build_object('enabled',false,'papers',0,'retried',0,'healed',0); end if;
 select coalesce(array_agg(x.id order by x.id),'{}') into papers from (select pp.id from app_private.pipeline_papers pp
  where pp.stage='failed' and pp.resume_stage in ('metadata','download','render') and pp.error_code is distinct from 'too_large'
   and pp.deploy_retry is distinct from p_deploy and (pp.lease_until is null or pp.lease_until<=clock_timestamp())
  order by pp.updated_at,pp.id limit p_limit for no key update skip locked) x;
 result:=app_private.pipeline_retry_papers(papers,true);
 update app_private.pipeline_papers set deploy_retry=p_deploy where id=any(papers);
 return jsonb_build_object('enabled',true,'papers',cardinality(papers),
  'retried',(select count(*) from jsonb_each_text(result->'papers') e where e.value='retried'),'healed',(result->>'healed')::integer);
end $$;

-- 019's projection, plus: a scheduled automatic retry reads `download_retrying` (with its time),
-- and the download causes readers are told apart.
create or replace function public.worker_pipeline_sync_imports(p_paper_id uuid,p_claim_id uuid,p_generation bigint) returns integer
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; link record; i app_private.import_requests; s bigint; changed integer:=0; target text; err text; retry boolean;
 acct uuid; ready uuid[]:='{}';
begin
 select * into p from app_private.pipeline_papers where id=p_paper_id;
 if not found or p.claim_id is distinct from p_claim_id or p.generation is distinct from p_generation or p.lease_until<=clock_timestamp()
 then raise exception 'stale_pipeline_claim'; end if;
 for acct in select distinct pi.account_id from app_private.pipeline_imports pi where pi.paper_id=p.id and pi.synced_revision<p.state_revision
  and pi.next_sync_at<=clock_timestamp() order by pi.account_id loop
  begin
   perform public.worker_consume_request(acct,'library-write');
   ready:=ready||acct;
  exception when others then
   update app_private.pipeline_imports set sync_failures=sync_failures+1,
    next_sync_at=clock_timestamp()+make_interval(secs=>least(3600,15*power(2,least(sync_failures,8))::integer))
    where paper_id=p.id and account_id=acct;
  end;
 end loop;
 perform 1 from app_private.accounts where id=any(ready) and closed_at is null order by id for no key update;
 for link in select pi.* from app_private.pipeline_imports pi where pi.paper_id=p.id and pi.synced_revision<p.state_revision
  and pi.account_id=any(ready) order by pi.account_id,pi.import_id loop
  begin
   select * into i from app_private.import_requests where account_id=link.account_id and id=link.import_id;
   if i.desired_present and i.phase in ('accepted','resolving','acquiring') then
    if p.stage='done' then
     perform public.worker_resolve_import(i.account_id,i.id,i.state_seq,i.intent_revision,p.approval_id,p.artifact_id);
    else
     target:=case when p.stage='metadata' then 'resolving'
      when p.stage in ('private_split','download','ocr_fund','ocr_submit','ocr_wait','ocr_uncertain','render') then 'acquiring'
      when p.stage='source_only' then 'source_only' else 'failed' end;
     err:=case when p.stage='source_only' then 'license_unverified' when p.stage='needs_credits' then 'insufficient_credits'
      when p.stage='failed' then case when p.auto_retry_at is not null then 'download_retrying'
       when p.error_code in ('metadata_unavailable','download_failed','pdf_invalid','rate_limited','too_large','conversion_failed',
        'source_unavailable','source_blocked','not_pdf','pdf_restricted') then p.error_code
       when p.resume_stage='metadata' then 'metadata_unavailable' when p.resume_stage='download' then 'download_failed' else 'conversion_failed' end end;
     retry:=p.stage='needs_credits' or (p.stage='failed' and p.resume_stage is not null);
     perform app_private.lock_library_account(i.account_id); perform app_private.lock_library_state(i.account_id);
     select * into strict i from app_private.import_requests where account_id=link.account_id and id=link.import_id;
     if i.desired_present and i.phase in ('accepted','resolving','acquiring') then
      s:=app_private.library_next_seq(i.account_id);
      update app_private.import_requests set phase=target,metadata_id=coalesce(metadata_id,p.metadata_id),state_seq=s,
       error_code=err,retryable=coalesce(retry,false),progress=coalesce(app_private.pipeline_progress(p.stage),progress),
       auto_retry_at=case when target='failed' then p.auto_retry_at end
       where account_id=i.account_id and id=i.id;
      perform app_private.library_emit(i.account_id,s,jsonb_build_array(app_private.library_import_entry(i.account_id,i.id)));
     end if;
    end if;
    changed:=changed+1;
   end if;
   update app_private.pipeline_imports set synced_revision=p.state_revision,sync_failures=0 where account_id=link.account_id and import_id=link.import_id;
  exception when others then
   update app_private.pipeline_imports set sync_failures=sync_failures+1,
    next_sync_at=clock_timestamp()+make_interval(secs=>least(3600,15*power(2,least(sync_failures,8))::integer))
    where account_id=link.account_id and import_id=link.import_id;
  end;
 end loop;
 return changed;
end $$;

-- 019's import entry, plus `auto_retry_at` while a failed import waits for its automatic retry
-- (only then, so every other entry is byte-for-byte what 019 produced; older builds ignore it).
create or replace function app_private.library_import_entry(a uuid,p_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('kind','import','id',i.id,'created_seq',i.created_seq,'state_seq',i.state_seq,'intent_revision',i.intent_revision,
  'visible',i.desired_present and i.phase<>'ready','phase',i.phase,'source',case when i.source_id like 'openalex:%' then 'web' else 'arxiv' end,'source_id',i.source_id,
  'requested_revision',i.requested_revision,'source_revision',cm.source_revision,'metadata_id',cm.id,'version_id',cm.version_id,
  'metadata',cm.metadata,'metadata_recorded_at',cm.recorded_at,
  'source_url',case when i.source_id like 'openalex:%' then 'https://openalex.org/works/'||substr(i.source_id,10)
   else 'https://arxiv.org/abs/'||i.source_id||coalesce('v'||coalesce(cm.source_revision,i.requested_revision),'') end,
  'document_id',i.document_id,'library_item_id',i.library_item_id,
  'error_code',i.error_code,'retryable',i.retryable,
  'progress',case when i.phase in ('accepted','resolving','acquiring') then i.progress end)
  ||case when i.phase='failed' and i.auto_retry_at is not null then jsonb_build_object('auto_retry_at',i.auto_retry_at) else '{}'::jsonb end
 from app_private.import_requests i left join app_private.catalog_metadata cm on cm.id=i.metadata_id
 where i.account_id=a and i.id=p_id
$$;

revoke all on function app_private.pipeline_auto_retry_schedule(),app_private.pipeline_retry_candidates(uuid[],boolean),
 app_private.pipeline_auto_retry_import(uuid,uuid),app_private.pipeline_retry_papers(uuid[],boolean) from public,anon,authenticated,service_role;
revoke all on function public.worker_pipeline_auto_retry(integer,integer),public.worker_pipeline_retry_failed(text,integer) from public,anon,authenticated;
grant execute on function public.worker_pipeline_auto_retry(integer,integer),public.worker_pipeline_retry_failed(text,integer) to service_role;
notify pgrst,'reload schema';
commit;
