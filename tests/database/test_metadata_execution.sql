-- Real PostgreSQL contract tests. Synthetic role attestations only: no network,
-- process supervisor, provider, Storage, credential or admission is exercised.
create schema if not exists test;
create or replace function test.assert(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'ASSERTION FAILED: %',label; end if; end $$;
create or replace function test.reject(statement text,expected text) returns void language plpgsql as $$
declare rejected boolean:=false; begin
 begin execute statement; exception when others then
  if position(expected in sqlerrm)=0 then raise exception 'Unexpected rejection: % (wanted %)',sqlerrm,expected; end if;
  rejected:=true;
 end;
 if not rejected then raise exception 'Expected rejection: %',expected; end if;
end $$;
create function test.executor_call(actor text,statement text) returns jsonb language plpgsql as $$
declare previous text:=current_setting('role'); result jsonb; begin
 perform set_config('role',actor,true);
 begin execute statement into result;
 exception when others then perform set_config('role',previous,true); raise; end;
 perform set_config('role',previous,true); return result;
end $$;
create function test.executor_binding() returns jsonb language sql as $$
 select jsonb_build_object('version',1,'project_ref',a.project_ref,'environment',a.environment,'epoch',a.epoch,'policy_id',p.id,
  'runner_sha256',encode(p.runner_sha256,'hex'),'transport_sha256',encode(p.transport_sha256,'hex'),'observer_sha256',encode(p.observer_sha256,'hex'),
  'deployment_id','local-synthetic-fixture','host_id','c1200000-0000-0000-0000-000000000001','boot_id','c1200000-0000-0000-0000-000000000002',
  'process_id',100+(select count(*) from app_private.execution_attempts),'process_start_id','123456','child_id',gen_random_uuid())
 from app_private.executor_authority a join app_private.executor_policies p on p.id=a.active_policy_id
$$;
create function test.executor_enable() returns void language plpgsql as $$
declare policy uuid:=gen_random_uuid(); d jsonb; begin
 d:=jsonb_build_object('version',1,'kind','metadata-owned-child-v1','connection_model','direct-owned-socket-v1','max_executors',1,
  'runner_sha256',repeat('a',64),'transport_sha256',repeat('b',64),'observer_sha256',repeat('c',64),'admission_sha256',repeat('d',64),
  'max_useful_seconds',120,'max_report_seconds',120);
 perform test.executor_call('science_reader_executor_admitter',format('select public.worker_install_metadata_executor_policy(%L,%L)',policy,d::text));
 perform test.executor_call('science_reader_executor_admitter',format('select public.worker_activate_metadata_executor(%s,%L,%L,decode(%L,''hex''))',
  (select revision from app_private.executor_authority),'abcdefghijklmnopqrst',policy,repeat('e',64)));
end $$;
create function test.executor_job(src text) returns uuid language plpgsql as $$
declare a uuid:=gen_random_uuid(); i uuid:=gen_random_uuid(); j uuid:=gen_random_uuid(); r jsonb; begin
 insert into auth.users values(a);
 perform set_config('request.jwt.claim.sub',a::text,true);
 r:=public.v2_begin_import(i,src,0,1);
 perform test.executor_call('science_reader_metadata_executor',format('select public.worker_prepare_acquisition(%L,%L,1)',j,src));
 perform test.executor_call('science_reader_metadata_executor',format('select public.worker_link_import_acquisition(%L,%L,1,%s,%L)',a,i,r->'entry'->>'state_seq',j));
 return j;
end $$;
create function test.executor_close(e jsonb,resource text,known boolean default true,receipt uuid default gen_random_uuid(),frame text default 'content_length') returns jsonb language plpgsql as $$
declare facts jsonb; begin
 facts:=jsonb_build_object('binding_sha256',e->>'binding_sha256','disposition',case when known then 'exited' else 'killed' end);
 if resource='arxiv_connection' then facts:=facts||jsonb_build_object('framing',case when known then frame else 'unknown' end,'peer_eof',false,
  'actual_bytes',case when known then 100 end,'body_sha256',case when known then repeat('f',64) end,'status_code',case when known then 200 end,'retry_after_seconds',0); end if;
 return test.executor_call('science_reader_execution_observer',format('select public.worker_record_metadata_quiescence(%L,%L,%L,%L,%L)',
  e->>'id',receipt,resource,'owned_child_joined',facts));
end $$;
grant usage on schema test to anon,authenticated,service_role,science_reader_pdf_verifier,science_reader_metadata_executor,science_reader_execution_observer,science_reader_executor_admitter;
grant execute on all functions in schema test to anon,authenticated,service_role,science_reader_pdf_verifier,science_reader_metadata_executor,science_reader_execution_observer,science_reader_executor_admitter;

begin;
select test.assert((select not enabled and recovery_required and active_policy_id is null from app_private.executor_authority),'012 starts disabled and unreconciled');
select test.assert(not exists(select 1 from app_private.executor_policies),'012 installs no admitted policy');
select test.assert(not exists(select 1 from pg_tables where schemaname='app_private' and not rowsecurity),'all new relations have RLS');
-- Exercise role dispatch, not just an ACL catalog snapshot.
do $$ declare actor text; name text; f record; begin
 foreach actor in array array['anon','authenticated','service_role','science_reader_pdf_verifier'] loop
  perform set_config('role',actor,true);
  perform test.reject('select public.worker_claim_metadata_stage_v2(gen_random_uuid(),gen_random_uuid(),''staging'',''{}'')','permission denied');
  perform test.reject('select public.worker_record_metadata_quiescence(gen_random_uuid(),gen_random_uuid(),''executor'',''owned_child_joined'',''{}'')','permission denied');
  perform test.reject('select public.worker_activate_metadata_executor(1,''abcdefghijklmnopqrst'',gen_random_uuid(),decode(repeat(''a'',64),''hex''))','permission denied');
  perform set_config('role','none',true);
 end loop;
 foreach actor in array array['science_reader_metadata_executor','science_reader_execution_observer','science_reader_executor_admitter'] loop
  perform set_config('role',actor,true);
  perform test.reject('select * from app_private.execution_attempts','permission denied');
  if actor<>'science_reader_metadata_executor' then perform test.reject('select public.worker_claim_metadata_stage_v2(gen_random_uuid(),gen_random_uuid(),''staging'',''{}'')','permission denied'); end if;
  if actor<>'science_reader_execution_observer' then perform test.reject('select public.worker_record_metadata_quiescence(gen_random_uuid(),gen_random_uuid(),''executor'',''owned_child_joined'',''{}'')','permission denied'); end if;
  if actor<>'science_reader_executor_admitter' then perform test.reject('select public.worker_activate_metadata_executor(1,''abcdefghijklmnopqrst'',gen_random_uuid(),decode(repeat(''a'',64),''hex''))','permission denied'); end if;
  perform set_config('role','none',true);
 end loop;
 foreach actor in array array['service_role','science_reader_pdf_verifier','science_reader_metadata_executor','science_reader_execution_observer','science_reader_executor_admitter'] loop
  for f in select oid::regprocedure as sig from pg_proc where pronamespace='public'::regnamespace and proname in (
   'worker_claim_arxiv_stage','worker_finish_arxiv_request','worker_finish_lookup','worker_fail_acquisition','worker_claim_acquisition',
   'worker_prepare_original','worker_reserve_original','worker_record_original_upload','worker_claim_original_verification','worker_record_original_verification',
   'worker_verification_input_unavailable','worker_record_original_integrity_failure','worker_publish_original','worker_bind_lookup_original',
   'worker_set_original_availability','worker_claim_original_orphans','worker_confirm_original_deleted','worker_authorize_original_read',
   'worker_record_arxiv_metadata','worker_approve_arxiv_asset') loop
   perform test.assert(not has_function_privilege(actor,f.sig,'EXECUTE'),'legacy execution/result is denied to '||actor||':'||f.sig);
  end loop;
 end loop;
end $$;
-- An accidental EXECUTE grant still cannot make interchangeable credentials
-- claim evidence authority; SECURITY DEFINER current_user is never the check.
grant execute on function public.worker_record_metadata_quiescence(uuid,uuid,text,text,jsonb) to science_reader_metadata_executor;
set local role science_reader_metadata_executor;
select test.reject('select public.worker_record_metadata_quiescence(gen_random_uuid(),gen_random_uuid(),''executor'',''owned_child_joined'',''{}'')','executor_authority_required');
reset role;
revoke execute on function public.worker_record_metadata_quiescence(uuid,uuid,text,text,jsonb) from science_reader_metadata_executor;
-- Accidentally flipping every old switch cannot restore a legacy permit.
update app_private.acquisition_policy set metadata_enabled=true,original_enabled=true,verification_enabled=true;
update app_private.paper_read_policy set enabled=true;
set local role service_role;
select test.reject('select public.worker_claim_arxiv_stage(gen_random_uuid(),gen_random_uuid(),''staging'')','permission denied');
select test.reject('select public.worker_authorize_original_read(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),current_date,0,10)','permission denied');
reset role;
update app_private.acquisition_policy set metadata_enabled=false,original_enabled=false,verification_enabled=false;
update app_private.paper_read_policy set enabled=false;
select test.executor_enable();
-- The fixed policy pool has a hard row/shape bound and exact install replay.
do $$ declare p app_private.executor_policies; id uuid; body jsonb; n integer; r jsonb; begin
 select * into strict p from app_private.executor_policies;
 r:=test.executor_call('science_reader_executor_admitter',format('select public.worker_install_metadata_executor_policy(%L,%L)',p.id,p.canonical_policy));
 perform test.assert((r->>'replayed')::boolean,'policy exact lost-ack replay');
 perform test.reject(format('select test.executor_call(''science_reader_executor_admitter'',%L)',format('select public.worker_install_metadata_executor_policy(%L,%L)',p.id,(p.definition||'{"max_executors":2}')::text)),'invalid_executor_policy');
 for n in 2..8 loop
  body:=p.definition||jsonb_build_object('admission_sha256',encode(sha256(convert_to('synthetic-policy-'||n,'UTF8')),'hex'));
  perform test.executor_call('science_reader_executor_admitter',format('select public.worker_install_metadata_executor_policy(%L,%L)',gen_random_uuid(),body::text));
 end loop;
 body:=p.definition||jsonb_build_object('admission_sha256',repeat('9',64));
 perform test.reject(format('select test.executor_call(''science_reader_executor_admitter'',%L)',format('select public.worker_install_metadata_executor_policy(%L,%L)',gen_random_uuid(),body::text)),'executor_policy_capacity');
 perform test.assert((select count(*) from app_private.executor_policies)=8,'profile pool cannot borrow job/receipt capacity');
end $$;

-- All six legal source attempts fit exactly; results use their original step.
do $$ declare j uuid:=test.executor_job('2403.50001'); c uuid; b jsonb; r jsonb; e jsonb; n integer; body jsonb; total bigint; before_state jsonb; actual_state jsonb; late uuid; owner uuid; imp uuid; begin
 for n in 1..6 loop
  c:=gen_random_uuid(); b:=test.executor_binding();
  update app_private.arxiv_network_gate set next_allowed_at='-infinity';
  update app_private.acquisition_jobs set next_attempt_at='-infinity' where id=j;
  r:=test.executor_call('science_reader_metadata_executor',format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,c,b)); e:=r->'execution';
  perform test.assert((r->>'granted')::boolean,'attempt '||n||' granted within24');
  perform test.assert(not (test.executor_call('science_reader_metadata_executor',format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,c,b))->>'granted')::boolean,'exact lost-ack grant replay never fetches');
  perform test.reject(format('select test.executor_call(''science_reader_metadata_executor'',%L)',format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,c,b||'{"deployment_id":"changed"}')),'operation_id_conflict');
  if n=1 then
   before_state:=(select jsonb_build_array((select jsonb_agg(to_jsonb(x)) from app_private.acquisition_steps x),
    (select jsonb_agg(to_jsonb(x)) from app_private.execution_attempts x),(select jsonb_agg(to_jsonb(x)) from app_private.acquisition_transfer_windows x),
    (select to_jsonb(x) from app_private.acquisition_jobs x where id=j)));
   for total in 1..100 loop
    r:=test.executor_call('science_reader_metadata_executor',format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,gen_random_uuid(),test.executor_binding()));
    perform test.assert(r->>'action'='wait' and r->'next_allowed_at'='null'::jsonb,'unknown hold has no safe clock');
   end loop;
   actual_state:=(select jsonb_build_array((select jsonb_agg(to_jsonb(x)) from app_private.acquisition_steps x),
    (select jsonb_agg(to_jsonb(x)) from app_private.execution_attempts x),(select jsonb_agg(to_jsonb(x)) from app_private.acquisition_transfer_windows x),
    (select to_jsonb(x) from app_private.acquisition_jobs x where id=j)));
   perform test.assert(before_state=actual_state,'100 busy waits allocate nothing');
  end if;
  if n=6 then
   -- Make the pool exactly full after grant. Both terminal receipts still fit.
   total:=(select (32+(select count(*) from app_private.acquisition_source_slots)+(select count(*)+sum(slots_held) from app_private.acquisition_jobs)
    +(select count(*) from app_private.acquisition_commands)+2*(select count(*) from app_private.paper_verification_profiles))*8192);
   update app_private.acquisition_policy set control_bytes=total;
   perform test.reject(format('select public.worker_prepare_acquisition(gen_random_uuid(),%L,1)','2403.50002'),'acquisition_control_capacity');
  end if;
  late:=gen_random_uuid(); perform test.executor_close(e,'arxiv_connection',true,late);
  perform test.assert((test.executor_close(e,'arxiv_connection',true,late)->>'replayed')::boolean,'identical closure is immutable replay');
  perform test.assert(test.executor_close(e,'arxiv_connection',true,gen_random_uuid())->>'receipt_id'=late::text,'redundant proof returns canonical receipt without alias row');
  perform test.reject(format('select test.executor_close(%L,''executor'',true,%L)',e,late),'operation_id_conflict');
  perform test.reject(format('select test.executor_close(%L,''arxiv_connection'',false,%L)',e,late),'operation_id_conflict');
  if n not in (3,6) then
   perform test.executor_call('science_reader_metadata_executor',format('select public.worker_fail_metadata_stage_v2(%L,%L,%s,%L,''metadata_unavailable'',true)',j,c,n,e->>'id'));
  else
   body:=case when n=3 then '{"revision":1,"metadata":{"title":"Metadata fixture","authors":["Author"],"categories":["cs.LG"],"published_at":"2024-03-01","updated_at":"2024-03-02"},"atom_published_at":"2024-03-01T00:00:00Z","atom_updated_at":"2024-03-02T00:00:00Z"}'::jsonb
    else '{"eligible":false,"reason":"license_not_supported"}'::jsonb end;
   perform test.executor_call('science_reader_metadata_executor',format('select public.worker_finish_metadata_stage_v2(%L,%L,%s,%L,decode(repeat(''f'',64),''hex''),%L)',j,c,n,e->>'id',body));
  end if;
  -- Publishing a result did not settle the executor.
  perform test.assert(app_private.execution_pending((e->>'id')::uuid,'executor'),'logical outcome preserves independent CPU hold');
  perform test.executor_close(e,'executor');
 end loop;
 perform test.assert((select slots_held=24 and atom_attempts=3 and license_attempts=3 and status='complete' and error_code is null and not retryable from app_private.acquisition_jobs where id=j),'six attempts complete without shrinking reservation or stale retry error');
 perform test.assert(app_private.execution_entry((e->>'id')::uuid)->'pending_resources'='[]'::jsonb,'closed pending resources are a stable empty array');
 perform test.assert((select count(*) from app_private.acquisition_steps where job_id=j)=6 and (select count(*) from app_private.execution_attempts where job_id=j)=6
  and (select count(*) from app_private.execution_quiescence q join app_private.execution_attempts e on e.id=q.attempt_id where e.job_id=j)=12,'exact24 records including final late receipts');
 perform test.assert((select sum(charged) from app_private.acquisition_transfer_windows where kind='source_bytes')=600,'only proven body bytes refunded');
 select account_id,import_id into owner,imp from app_private.acquisition_interests where lookup_job_id=j;
 r:=test.executor_call('science_reader_metadata_executor',format('select public.worker_project_import_acquisition(%L,%L,1)',owner,imp));
 perform test.assert(r->'entry'->>'phase'='source_only' and r->'entry'->>'document_id' is null,'metadata projection stays source-only without fake document');
 perform test.assert((select last_seq from app_private.library_sync_state where account_id=owner)>1,'metadata projection uses durable library cursor');
 update app_private.acquisition_policy set control_bytes=33554432;
end $$;
-- Expired work, quarantine and account cancellation never imply retirement.
do $$ declare j uuid:=test.executor_job('2403.50003'); c uuid:=gen_random_uuid(); b jsonb; r jsonb; e jsonb;
 receipt uuid:=gen_random_uuid(); revision bigint; policy uuid; old_epoch uuid; charge bigint; owner uuid; imp uuid; begin
 update app_private.acquisition_policy set stage_lease_seconds=1;
 update app_private.arxiv_network_gate set next_allowed_at='-infinity';
 b:=test.executor_binding();
 r:=test.executor_call('science_reader_metadata_executor',format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,c,b)); e:=r->'execution';
 perform test.assert((r->>'granted')::boolean,'uncertain test grant');
 perform pg_sleep(1.05);
 update app_private.acquisition_jobs set hard_deadline=clock_timestamp()-interval '1 year',next_attempt_at='-infinity' where id=j;
 r:=test.executor_call('science_reader_metadata_executor',format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,gen_random_uuid(),test.executor_binding()));
 perform test.assert(r->>'reason'='unsettled_execution' and r->'next_allowed_at'='null'::jsonb,'expired clocks do not release capacity');
 select account_id,import_id into owner,imp from app_private.acquisition_interests where lookup_job_id=j;
 perform set_config('request.jwt.claim.sub',owner::text,true);
 perform public.v2_cancel_import(gen_random_uuid(),imp,1);
 update app_private.acquisition_jobs set status='failed',claim_id=null,lease_until=null,error_code='metadata_unavailable' where id=j;
 perform test.assert(jsonb_array_length(test.executor_call('science_reader_execution_observer','select public.worker_scan_unsettled_metadata_executions()'))=1,'terminal/no-interest work remains discoverable');
 perform test.executor_close(e,'executor',false);
 r:=test.executor_call('science_reader_metadata_executor',format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,gen_random_uuid(),test.executor_binding()));
 perform test.assert(r->>'action'='terminal','terminal job cannot obtain work after CPU closure');
 perform test.assert(app_private.execution_pending((e->>'id')::uuid,'arxiv_connection'),'CPU closure leaves source occupied');
 select a.revision,a.active_policy_id,a.epoch into revision,policy,old_epoch from app_private.executor_authority a;
 -- Same mutation performed by restore-local quarantine; the separate operations
 -- restore suite invokes the actual hook against this schema, not just columns.
 update app_private.executor_authority a set enabled=false,recovery_required=true,revision=a.revision+1;
 perform test.reject(format('select test.executor_call(''science_reader_executor_admitter'',%L)',
  format('select public.worker_activate_metadata_executor(%s,''abcdefghijklmnopqrst'',%L,decode(repeat(''e'',64),''hex''))',revision,policy)),'stale_executor_authority');
 perform test.reject(format('select test.executor_call(''science_reader_executor_admitter'',%L)',
  format('select public.worker_activate_metadata_executor(%s,''abcdefghijklmnopqrst'',%L,decode(repeat(''e'',64),''hex''))',revision+1,policy)),'executor_recovery_required');
 perform test.reject(format('select test.executor_close(%L,''arxiv_connection'',true,gen_random_uuid(),''close_delimited'')',e),'invalid_execution_evidence');
 select sum(charged) into charge from app_private.acquisition_transfer_windows where kind='source_bytes';
 perform test.executor_close(e,'arxiv_connection',false,receipt);
 perform test.assert((select sum(charged) from app_private.acquisition_transfer_windows where kind='source_bytes')=charge,'unknown-byte closure never refunds');
 perform test.assert((select network_actual_bytes is null and network_closed_at is not null from app_private.acquisition_steps where job_id=j and operation_id=c),'unknown closure is represented honestly');
 perform test.executor_call('science_reader_executor_admitter',format('select public.worker_activate_metadata_executor(%s,''abcdefghijklmnopqrst'',%L,decode(repeat(''e'',64),''hex''))',revision+1,policy));
 perform test.assert((select epoch<>old_epoch from app_private.executor_authority),'new activation uses fresh epoch');
 perform test.assert((test.executor_close(e,'arxiv_connection',false,receipt)->>'replayed')::boolean,'old epoch exact receipt replay stays status-only');
 perform test.reject(format('select test.executor_call(''science_reader_metadata_executor'',%L)',
  format('select public.worker_finish_metadata_stage_v2(%L,%L,1,%L,decode(repeat(''f'',64),''hex''),''{}'')',j,c,e->>'id')),'stale_execution_attempt');
 perform test.assert(jsonb_array_length(test.executor_call('science_reader_execution_observer','select public.worker_scan_unsettled_metadata_executions()'))=0,'closed attempts disappear from unresolved scan only after both receipts');
 update app_private.acquisition_policy set stage_lease_seconds=120;
end $$;

-- A bounded header-derived Retry-After survives an incomplete/aborted body.
do $$ declare j uuid:=test.executor_job('2403.50006'); c uuid:=gen_random_uuid(); e jsonb; charge bigint; facts jsonb; begin
 update app_private.arxiv_network_gate set next_allowed_at='-infinity';
 e:=test.executor_call('science_reader_metadata_executor',format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,c,test.executor_binding()))->'execution';
 select sum(charged) into charge from app_private.acquisition_transfer_windows where kind='source_bytes';
 facts:=jsonb_build_object('binding_sha256',e->>'binding_sha256','disposition','killed','framing','unknown','peer_eof',false,
  'actual_bytes',null,'body_sha256',null,'status_code',429,'retry_after_seconds',600);
 perform test.executor_call('science_reader_execution_observer',format('select public.worker_record_metadata_quiescence(%L,gen_random_uuid(),''arxiv_connection'',''owned_child_joined'',%L)',e->>'id',facts));
 perform test.assert((select sum(charged) from app_private.acquisition_transfer_windows where kind='source_bytes')=charge,'429 incomplete body retains worst-case charge');
 perform test.assert((select next_allowed_at>=clock_timestamp()+interval '599 seconds' from app_private.arxiv_network_gate),'429 incomplete body retains full Retry-After');
 perform test.executor_close(e,'executor',false);
end $$;

-- A reuse proof is bound to the exact observed license response, not merely to
-- any well-shaped SHA. Both HTTP length and chunk framing work without peer EOF.
do $$ declare j uuid:=test.executor_job('2403.50005'); c uuid; r jsonb; e jsonb; body jsonb; n integer; a uuid; i uuid; begin
 for n in 1..2 loop
  update app_private.arxiv_network_gate set next_allowed_at='-infinity'; c:=gen_random_uuid();
  r:=test.executor_call('science_reader_metadata_executor',format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,c,test.executor_binding())); e:=r->'execution';
  perform test.executor_close(e,'arxiv_connection',true,gen_random_uuid(),case when n=1 then 'content_length' else 'chunked' end);
  if n=1 then
   body:='{"revision":1,"metadata":{"title":"Eligible fixture","authors":["Author"],"categories":["cs.LG"],"updated_at":"2024-03-02"},"atom_updated_at":"2024-03-02T00:00:00Z"}';
  else
   body:=jsonb_build_object('eligible',true,'license_uri','https://creativecommons.org/licenses/by/4.0/',
    'evidence',jsonb_build_object('source_id','2403.50005','source_revision',1,'source_url','https://arxiv.org/abs/2403.50005v1',
     'license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_format','arXivRaw','evidence_sha256',repeat('a',64),
     'observed_at','2026-10-03T01:00:00Z','latest_version_at','2024-03-02T00:00:00Z'));
   perform test.reject(format('select test.executor_call(''science_reader_metadata_executor'',%L)',
    format('select public.worker_finish_metadata_stage_v2(%L,%L,%s,%L,decode(repeat(''f'',64),''hex''),%L)',j,c,n,e->>'id',body)),'reuse_evidence_mismatch');
   body:=jsonb_set(body,'{evidence,evidence_sha256}',to_jsonb(repeat('f',64)));
  end if;
  perform test.executor_call('science_reader_metadata_executor',format('select public.worker_finish_metadata_stage_v2(%L,%L,%s,%L,decode(repeat(''f'',64),''hex''),%L)',j,c,n,e->>'id',body));
  perform test.executor_close(e,'executor');
 end loop;
 select account_id,import_id into a,i from app_private.acquisition_interests where lookup_job_id=j;
 r:=test.executor_call('science_reader_metadata_executor',format('select public.worker_project_import_acquisition(%L,%L,1)',a,i));
 perform test.assert(r->'entry'->>'phase'='acquiring' and r->'entry'->>'document_id' is null,'eligible metadata remains pending without acquisition');
 perform test.assert(not exists(select 1 from app_private.paper_asset_reservations),'metadata success has no original side effect');
end $$;

-- Incomplete original model identities cannot impersonate the explicit v2 model.
do $$ declare j uuid:=test.executor_job('2403.50004'); legacy uuid:=gen_random_uuid(); slot uuid; p uuid; c uuid:=gen_random_uuid(); b jsonb; rev bigint; begin
 select source_slot_id into slot from app_private.acquisition_jobs where id=j;
 insert into app_private.acquisition_jobs(id,kind,source_slot_id,slot_generation,source_id,requested_revision,input_sha256,stage,slots_held)
 values(legacy,'lookup',slot,99,'2403.50004',1,sha256('legacy-24'::bytea),'atom',24);
 b:=test.executor_binding();
 perform test.reject(format('select test.executor_call(''science_reader_metadata_executor'',%L)',
  format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',legacy,c,b)),'metadata_execution_contract_required');
 perform test.reject(format('update app_private.acquisition_jobs set execution_contract=''metadata-v2'' where id=%L',legacy),'immutable_execution_contract');
 perform test.reject(format('update app_private.acquisition_jobs set slots_held=6 where id=%L',j),'metadata_execution_envelope');
 -- Even a closed 011 socket does not prove the old executor stopped.
 insert into app_private.acquisition_steps(job_id,operation_id,request_sha256,kind,generation,stage,network_token,network_closed_at)
 values(legacy,c,sha256('old-grant'::bytea),'arxiv_stage',1,'atom',gen_random_uuid(),clock_timestamp());
 select revision,active_policy_id into rev,p from app_private.executor_authority;
 perform test.executor_call('science_reader_executor_admitter',format('select public.worker_retire_metadata_executor(%s)',rev));
 perform test.reject(format('select test.executor_call(''science_reader_executor_admitter'',%L)',
  format('select public.worker_activate_metadata_executor(%s,''abcdefghijklmnopqrst'',%L,decode(repeat(''e'',64),''hex''))',rev+1,p)),'executor_recovery_required');
 perform test.assert(test.executor_call('science_reader_executor_admitter','select public.worker_metadata_authority_state()')->'legacy_unsettled'='true'::jsonb,'unmigrated execution reason is exposed');
end $$;
rollback;

-- Linux-scope contract tests are isolated from the unchanged v1 schedules above.
-- The synthetic observer supplies evidence; these tests do not attest a host,
-- start a scope, provision a credential or authorize outbound work.
begin;
create function test.linux_binding(claim uuid) returns jsonb language sql as $$
 select test.executor_binding()||jsonb_build_object('version',2,'host_id',a.admitted_host_id,
  'boot_id',a.admitted_boot_id,'deployment_id',a.admitted_deployment_id,
  'scope',jsonb_build_object('kind','linux-systemd-cgroup-v1','scope_id',claim,'invocation_id',repeat('1',32),
   'cgroup_device','0','cgroup_inode','1234','capture_sha256',repeat('1',64)))
 from app_private.executor_authority a
$$;
create function test.linux_facts(e jsonb,resource text) returns jsonb language sql as $$
 select jsonb_build_object('binding_sha256',e->>'binding_sha256','scope_id',e#>>'{binding,scope,scope_id}',
  'capture_sha256',e#>>'{binding,scope,capture_sha256}','fence_sha256',repeat('2',64),'observation_sha256',repeat('3',64))
 ||case when resource='arxiv_connection' then jsonb_build_object('framing','unknown','peer_eof',false,
  'actual_bytes',null,'body_sha256',null,'status_code',null,'retry_after_seconds',0) else '{}'::jsonb end
$$;
create function test.linux_close(e jsonb,resource text,receipt uuid default gen_random_uuid(),changes jsonb default '{}') returns jsonb language plpgsql as $$
begin
 return test.executor_call('science_reader_execution_observer',format('select public.worker_record_metadata_quiescence(%L,%L,%L,''owned_scope_retired_v1'',%L)',
  e->>'id',receipt,resource,test.linux_facts(e,resource)||changes));
end $$;
create function test.linux_activate(policy uuid,revision bigint) returns jsonb language plpgsql as $$
begin
 return test.executor_call('science_reader_executor_admitter',format('select public.worker_activate_metadata_executor_v2(%s,''abcdefghijklmnopqrst'',%L,
  ''c1200000-0000-0000-0000-000000000001'',''c1200000-0000-0000-0000-000000000002'',%L,decode(repeat(''e'',64),''hex''))',revision,policy,repeat('d',128)));
end $$;

-- The separate activation surface has both ACL and runtime capability checks.
do $$ declare actor text; begin
 foreach actor in array array['anon','authenticated','service_role','science_reader_pdf_verifier','science_reader_metadata_executor','science_reader_execution_observer'] loop
  perform test.reject(format('select test.executor_call(%L,%L)',actor,
   'select public.worker_activate_metadata_executor_v2(1,''abcdefghijklmnopqrst'',gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),''fixture'',decode(repeat(''a'',64),''hex''))'),'permission denied');
 end loop;
end $$;
grant execute on function public.worker_activate_metadata_executor_v2(bigint,text,uuid,uuid,uuid,text,bytea) to science_reader_metadata_executor;
select test.reject('select test.executor_call(''science_reader_metadata_executor'',''select public.worker_activate_metadata_executor_v2(1, null, null, null, null, null, null)'')','executor_authority_required');
revoke execute on function public.worker_activate_metadata_executor_v2(bigint,text,uuid,uuid,uuid,text,bytea) from science_reader_metadata_executor;
select test.executor_enable();
do $$ declare old_policy uuid; policy uuid:=gen_random_uuid(); definition jsonb; rev bigint; r jsonb; old_epoch uuid; begin
 select active_policy_id,revision,epoch into old_policy,rev,old_epoch from app_private.executor_authority;
 perform test.executor_call('science_reader_executor_admitter',format('select public.worker_retire_metadata_executor(%s)',rev));
 rev:=rev+1;
 select p.definition||'{"kind":"metadata-linux-scope-v1"}'::jsonb into definition from app_private.executor_policies p where p.id=old_policy;
 perform test.executor_call('science_reader_executor_admitter',format('select public.worker_install_metadata_executor_policy(%L,%L)',policy,definition::text));
 perform test.reject(format('select test.linux_activate(%L,%s)',old_policy,rev),'invalid_executor_activation');
 perform test.reject(format('select test.executor_call(''science_reader_executor_admitter'',%L)',
  format('select public.worker_activate_metadata_executor(%s,''abcdefghijklmnopqrst'',%L,decode(repeat(''e'',64),''hex''))',rev,policy)),'invalid_executor_activation');
 perform test.reject(format('select test.executor_call(''science_reader_executor_admitter'',%L)',
  format('select public.worker_activate_metadata_executor_v2(%s,''abcdefghijklmnopqrst'',%L,null,gen_random_uuid(),''fixture'',decode(repeat(''e'',64),''hex''))',rev,policy)),'invalid_executor_activation');
 perform test.reject(format('select test.executor_call(''science_reader_executor_admitter'',%L)',
  format('select public.worker_activate_metadata_executor_v2(%s,''abcdefghijklmnopqrst'',%L,gen_random_uuid(),gen_random_uuid(),''bad/deployment'',decode(repeat(''e'',64),''hex''))',rev,policy)),'invalid_executor_activation');
 r:=test.linux_activate(policy,rev);
 perform test.assert(r->'enabled'='true'::jsonb and r->'recovery_required'='false'::jsonb
  and r->>'admitted_host_id'='c1200000-0000-0000-0000-000000000001'
  and r->>'admitted_boot_id'='c1200000-0000-0000-0000-000000000002'
  and r->>'admitted_deployment_id'=repeat('d',128) and (r->>'epoch')::uuid<>old_epoch,'Linux activation pins exact authority with fresh epoch');
 perform test.reject(format('select test.linux_activate(%L,%s)',policy,rev),'stale_executor_authority');
end $$;

-- Reject shape/identity drift before consuming a stage, control record or charge.
do $$ declare j uuid:=test.executor_job('2403.51001'); c uuid:=gen_random_uuid(); b jsonb; bad jsonb; r jsonb; e jsonb; facts jsonb;
 receipt uuid:=gen_random_uuid(); other uuid; binding_bytes integer; generation_before bigint; charge bigint; requests bigint; begin
 b:=test.linux_binding(c);
 select generation into generation_before from app_private.acquisition_jobs where id=j;
 for bad in select value from jsonb_array_elements(jsonb_build_array(
  b-'scope',b||'{"extra":1}',b||'{"version":1}',b||'{"scope":null}',
  b||jsonb_build_object('host_id',gen_random_uuid()),b||jsonb_build_object('boot_id',gen_random_uuid()),b||'{"deployment_id":"other"}',
  jsonb_set(b,'{scope,scope_id}',to_jsonb(gen_random_uuid()::text)),
  jsonb_set(b,'{scope}',b->'scope'||'{"extra":1}'),jsonb_set(b,'{scope}',(b->'scope')-'capture_sha256'),
  jsonb_set(b,'{scope,kind}','"other"'),jsonb_set(b,'{scope,cgroup_device}','0'),
  jsonb_set(b,'{scope,cgroup_device}','"00"'),jsonb_set(b,'{scope,cgroup_device}','"-1"'),
  jsonb_set(b,'{scope,cgroup_device}','"18446744073709551616"'),jsonb_set(b,'{scope,cgroup_inode}','"0"'),
  jsonb_set(b,'{scope,cgroup_inode}','"18446744073709551616"'),jsonb_set(b,'{scope,cgroup_inode}','null'),
  jsonb_set(b,'{scope,invocation_id}',to_jsonb(repeat('A',32))),jsonb_set(b,'{scope,capture_sha256}',to_jsonb(repeat('A',64))))) loop
  perform test.reject(format('select test.executor_call(''science_reader_metadata_executor'',%L)',
   format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,c,bad)),'invalid_executor_binding');
 end loop;
 perform test.assert(not exists(select 1 from app_private.execution_attempts) and not exists(select 1 from app_private.acquisition_steps)
  and not exists(select 1 from app_private.acquisition_transfer_windows)
  and (select generation=generation_before from app_private.acquisition_jobs where id=j),'invalid Linux binding allocates nothing');
 b:=jsonb_set(jsonb_set(b,'{scope,cgroup_device}','"18446744073709551615"'),'{scope,cgroup_inode}','"18446744073709551615"')
  ||jsonb_build_object('process_id',2147483647,'process_start_id',repeat('9',20));
 binding_bytes:=octet_length(b::text);
 r:=test.executor_call('science_reader_metadata_executor',format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,c,b)); e:=r->'execution';
 perform test.assert(r->'granted'='true'::jsonb and binding_bytes<=2048
  and (select scope_id=c from app_private.execution_attempts where id=(e->>'id')::uuid),'maximum canonical scope values are representable');
 r:=test.executor_call('science_reader_metadata_executor',format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,c,b));
 perform test.assert(r->'granted'='false'::jsonb and r->>'action'='reconcile','Linux lost grant acknowledgement never regrants');
 perform test.reject(format('select test.executor_call(''science_reader_metadata_executor'',%L)',
  format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,c,jsonb_set(b,'{scope,capture_sha256}',to_jsonb(repeat('4',64))))),'operation_id_conflict');
 perform test.reject(format('select test.linux_close(%L,''arxiv_connection'')',e),'executor_retirement_required');
 perform test.reject(format('select test.executor_close(%L,''arxiv_connection'')',e),'executor_retirement_required');
 facts:=test.linux_facts(e,'executor');
 for bad in select value from jsonb_array_elements(jsonb_build_array(facts||'{"disposition":"exited"}',facts-'fence_sha256',
  facts||'{"extra":true}',facts||'{"observation_sha256":null}',facts||jsonb_build_object('fence_sha256',repeat('A',64)))) loop
  perform test.reject(format('select test.executor_call(''science_reader_execution_observer'',%L)',
   format('select public.worker_record_metadata_quiescence(%L,gen_random_uuid(),''executor'',''owned_scope_retired_v1'',%L)',e->>'id',bad)),'invalid_execution_evidence');
 end loop;
 perform test.reject(format('select test.linux_close(%L,''executor'',gen_random_uuid(),%L)',e,jsonb_build_object('scope_id',gen_random_uuid())),'execution_evidence_binding');
 perform test.reject(format('select test.linux_close(%L,''executor'',gen_random_uuid(),%L)',e,jsonb_build_object('capture_sha256',repeat('4',64))),'execution_evidence_binding');
 perform test.linux_close(e,'executor',receipt);
 r:=test.linux_close(e,'executor',receipt);
 perform test.assert(r->'replayed'='true'::jsonb and r->>'receipt_id'=receipt::text,'scope receipt same-ID replay');
 r:=test.linux_close(e,'executor');
 perform test.assert(r->'replayed'='true'::jsonb and r->>'receipt_id'=receipt::text,'same proof new ID returns canonical receipt without alias');
 perform test.reject(format('select test.linux_close(%L,''executor'',gen_random_uuid(),%L)',e,jsonb_build_object('observation_sha256',repeat('4',64))),'operation_id_conflict');
 perform test.reject(format('select test.executor_close(%L,''executor'')',e),'operation_id_conflict');
 perform test.reject(format('select test.linux_close(%L,''arxiv_connection'',%L)',e,receipt),'operation_id_conflict');
 facts:=test.linux_facts(e,'arxiv_connection');
 for bad in select value from jsonb_array_elements(jsonb_build_array(facts-'actual_bytes',facts||'{"disposition":"killed"}',
  facts||'{"actual_bytes":0}',facts||jsonb_build_object('body_sha256',repeat('f',64)),facts||'{"framing":"content_length"}',
  facts||'{"peer_eof":true}',facts||'{"status_code":600}',facts||'{"status_code":"429"}',facts||'{"retry_after_seconds":86401}')) loop
  perform test.reject(format('select test.executor_call(''science_reader_execution_observer'',%L)',
   format('select public.worker_record_metadata_quiescence(%L,gen_random_uuid(),''arxiv_connection'',''owned_scope_retired_v1'',%L)',e->>'id',bad)),'invalid_execution_evidence');
 end loop;
 select charged into charge from app_private.acquisition_transfer_windows where kind='source_bytes';
 select charged into requests from app_private.acquisition_transfer_windows where kind='source_requests';
 receipt:=gen_random_uuid(); r:=test.linux_close(e,'arxiv_connection',receipt,'{"status_code":429,"retry_after_seconds":600}');
 perform test.assert(r->'execution'->'pending_resources'='[]'::jsonb and (select count(*) from app_private.execution_quiescence)=2,'exactly two prepaid resource records');
 perform test.assert((select charged=charge and charged=1048576 from app_private.acquisition_transfer_windows where kind='source_bytes')
  and (select charged=requests and charged=1 from app_private.acquisition_transfer_windows where kind='source_requests'),'scope retirement including no-GO retains full body and request charges');
 perform test.assert((select next_allowed_at>clock_timestamp()+interval '590 seconds' and token is null from app_private.arxiv_network_gate),'scope retirement preserves supported Retry-After');
 r:=test.linux_close(e,'arxiv_connection',receipt,'{"status_code":429,"retry_after_seconds":600}');
 perform test.assert(r->'replayed'='true'::jsonb and (select charged=charge from app_private.acquisition_transfer_windows where kind='source_bytes'),'receipt retry cannot refund');
 perform test.reject(format('select test.executor_call(''science_reader_metadata_executor'',%L)',
  format('select public.worker_finish_metadata_stage_v2(%L,%L,1,%L,decode(repeat(''f'',64),''hex''),''{}'')',j,c,e->>'id')),'stale_execution_attempt');
 -- Another job cannot reuse this retired scope, even with a fresh child/PID.
 other:=test.executor_job('2403.51002'); update app_private.arxiv_network_gate set next_allowed_at='-infinity';
 perform test.reject(format('select test.executor_call(''science_reader_metadata_executor'',%L)',
  format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',other,c,test.linux_binding(c))),'executor_binding_already_used');
 r:=test.executor_call('science_reader_metadata_executor',format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,c,b));
 perform test.assert(r->'granted'='false'::jsonb and r->'execution'->'pending_resources'='[]'::jsonb,'settled grant replay remains status-only');
end $$;

-- Current v2 joined-child evidence still permits ordinary validated metadata.
do $$ declare j uuid:=test.executor_job('2403.51003'); c uuid; e jsonb; r jsonb; body jsonb; n integer; a uuid; i uuid; before_bytes bigint; before_requests bigint; begin
 select sum(charged) into before_bytes from app_private.acquisition_transfer_windows where kind='source_bytes';
 select sum(charged) into before_requests from app_private.acquisition_transfer_windows where kind='source_requests';
 for n in 1..2 loop
  c:=gen_random_uuid(); update app_private.arxiv_network_gate set next_allowed_at='-infinity';
  r:=test.executor_call('science_reader_metadata_executor',format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,c,test.linux_binding(c))); e:=r->'execution';
  perform test.executor_close(e,'executor');
  perform test.executor_close(e,'arxiv_connection',true,gen_random_uuid(),case when n=1 then 'content_length' else 'chunked' end);
  body:=case when n=1 then '{"revision":1,"metadata":{"title":"Linux normal path","authors":["Author"],"categories":["cs.LG"],"updated_at":"2024-03-02"},"atom_updated_at":"2024-03-02T00:00:00Z"}'::jsonb
   else '{"eligible":false,"reason":"license_not_supported"}'::jsonb end;
  perform test.executor_call('science_reader_metadata_executor',format('select public.worker_finish_metadata_stage_v2(%L,%L,%s,%L,decode(repeat(''f'',64),''hex''),%L)',j,c,n,e->>'id',body));
 end loop;
 perform test.assert((select sum(charged)=before_bytes+200 from app_private.acquisition_transfer_windows where kind='source_bytes')
  and (select sum(charged)=before_requests+2 from app_private.acquisition_transfer_windows where kind='source_requests'),'normal v2 framing refunds only proven body bytes, never request count');
 select account_id,import_id into a,i from app_private.acquisition_interests where lookup_job_id=j;
 r:=test.executor_call('science_reader_metadata_executor',format('select public.worker_project_import_acquisition(%L,%L,1)',a,i));
 perform test.assert(r->'entry'->>'phase'='source_only' and r->'entry'->>'document_id' is null,'Linux metadata success preserves source-only projection');
 perform test.assert((select slots_held=24 from app_private.acquisition_jobs where id=j),'Linux completion preserves all late-receipt headroom');
end $$;

-- A retained exact-child wait may settle CPU first while source recovery has
-- only scope evidence. A known 200 header still cannot manufacture a body.
do $$ declare j uuid:=test.executor_job('2403.51008'); c uuid:=gen_random_uuid(); e jsonb; r jsonb;
 charge bigint; requests bigint; cap bigint; total bigint; begin
 update app_private.arxiv_network_gate set next_allowed_at='-infinity';
 r:=test.executor_call('science_reader_metadata_executor',format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,c,test.linux_binding(c))); e:=r->'execution';
 select control_bytes into cap from app_private.acquisition_policy;
 total:=(select (32+(select count(*) from app_private.acquisition_source_slots)+(select count(*)+sum(slots_held) from app_private.acquisition_jobs)
  +(select count(*) from app_private.acquisition_commands)+2*(select count(*) from app_private.paper_verification_profiles))*8192);
 update app_private.acquisition_policy set control_bytes=total;
 select sum(charged) into charge from app_private.acquisition_transfer_windows where kind='source_bytes';
 select sum(charged) into requests from app_private.acquisition_transfer_windows where kind='source_requests';
 perform test.executor_close(e,'executor');
 r:=test.linux_close(e,'arxiv_connection',gen_random_uuid(),'{"status_code":200}');
 perform test.assert(r->'execution'->'pending_resources'='[]'::jsonb
  and (select evidence_kind='owned_child_joined' from app_private.execution_quiescence where attempt_id=(e->>'id')::uuid and resource='executor')
  and (select evidence_kind='owned_scope_retired_v1' from app_private.execution_quiescence where attempt_id=(e->>'id')::uuid and resource='arxiv_connection'),'mixed recovery settles exactly the witnessed resources at full capacity');
 perform test.assert((select sum(charged)=charge from app_private.acquisition_transfer_windows where kind='source_bytes')
  and (select sum(charged)=requests from app_private.acquisition_transfer_windows where kind='source_requests'),'mixed proof retains full byte and request charge');
 perform test.reject(format('select test.executor_call(''science_reader_metadata_executor'',%L)',
  format('select public.worker_finish_metadata_stage_v2(%L,%L,1,%L,decode(repeat(''f'',64),''hex''),''{}'')',j,c,e->>'id')),'stale_execution_attempt');
 update app_private.acquisition_policy set control_bytes=cap;
end $$;

-- Full-cap, late/retired/quarantined evidence must settle without reactivation.
do $$ declare j uuid:=test.executor_job('2403.51004'); c uuid:=gen_random_uuid(); e jsonb; r jsonb; a jsonb; rev bigint; policy uuid;
 charge bigint; requests bigint; cap bigint; total bigint; begin
 update app_private.acquisition_policy set stage_lease_seconds=1;
 update app_private.arxiv_network_gate set next_allowed_at='-infinity';
 r:=test.executor_call('science_reader_metadata_executor',format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,c,test.linux_binding(c))); e:=r->'execution';
 perform pg_sleep(1.05);
 a:=test.executor_call('science_reader_executor_admitter','select public.worker_metadata_authority_state()');
 rev:=(a->>'revision')::bigint; policy:=(a->>'policy_id')::uuid;
 perform test.executor_call('science_reader_executor_admitter',format('select public.worker_retire_metadata_executor(%s)',rev));
 -- Restore's quarantine mutation preserves the immutable admission pins and
 -- invalidates every pre-quarantine activation CAS, even if already disabled.
 update app_private.executor_authority set enabled=false,recovery_required=true,revision=revision+1;
 perform test.reject(format('select test.linux_activate(%L,%s)',policy,rev+1),'stale_executor_authority');
 perform test.reject(format('select test.linux_activate(%L,%s)',policy,rev+2),'executor_recovery_required');
 perform test.assert(jsonb_array_length(test.executor_call('science_reader_execution_observer','select public.worker_scan_unsettled_metadata_executions()'))=1,'late Linux holds remain discoverable');
 select control_bytes into cap from app_private.acquisition_policy;
 total:=(select (32+(select count(*) from app_private.acquisition_source_slots)+(select count(*)+sum(slots_held) from app_private.acquisition_jobs)
  +(select count(*) from app_private.acquisition_commands)+2*(select count(*) from app_private.paper_verification_profiles))*8192);
 update app_private.acquisition_policy set control_bytes=total;
 perform test.reject('select public.worker_prepare_acquisition(gen_random_uuid(),''2403.51005'',1)','acquisition_control_capacity');
 select sum(charged) into charge from app_private.acquisition_transfer_windows where kind='source_bytes';
 select sum(charged) into requests from app_private.acquisition_transfer_windows where kind='source_requests';
 perform test.linux_close(e,'executor'); perform test.linux_close(e,'arxiv_connection');
 r:=test.executor_call('science_reader_executor_admitter','select public.worker_metadata_authority_state()');
 perform test.assert(r->'enabled'='false'::jsonb and r->'recovery_required'='true'::jsonb and r->'epoch'=a->'epoch'
  and r->'admitted_host_id'=a->'admitted_host_id' and r->'admitted_boot_id'=a->'admitted_boot_id'
  and r->'admitted_deployment_id'=a->'admitted_deployment_id','scope receipts cannot clear quarantine or rewrite admission identity');
 perform test.assert((select sum(charged)=charge from app_private.acquisition_transfer_windows where kind='source_bytes')
  and (select sum(charged)=requests from app_private.acquisition_transfer_windows where kind='source_requests'),'expired full-pool scope receipts preserve charges');
 perform test.reject(format('select test.executor_call(''science_reader_metadata_executor'',%L)',
  format('select public.worker_finish_metadata_stage_v2(%L,%L,1,%L,decode(repeat(''f'',64),''hex''),''{}'')',j,c,e->>'id')),'stale_execution_attempt');
 update app_private.acquisition_policy set control_bytes=cap,stage_lease_seconds=120;
 r:=test.linux_activate(policy,rev+2);
 perform test.assert(r->'epoch'<>a->'epoch','only explicit settled activation creates a successor epoch');
end $$;

-- Seed a coherent pre-existing historical attempt, without disabling any
-- immutable trigger or altering the server clock. Real observer RPCs must debit
-- only its original month; today is a different charge window in this fixture.
do $$ declare j uuid:=gen_random_uuid(); slot uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); attempt uuid:=gen_random_uuid(); b jsonb; e jsonb; digest bytea; lookup_digest bytea;
 started timestamptz:=(date_trunc('month',clock_timestamp() at time zone 'UTC') at time zone 'UTC')-interval '1 hour';
 old_month date; old_day date; current_month date:=(date_trunc('month',clock_timestamp() at time zone 'UTC'))::date;
 old_charge bigint; current_charge bigint; requests jsonb; receipt uuid:=gen_random_uuid(); begin
 old_month:=(date_trunc('month',started at time zone 'UTC'))::date; old_day:=(started at time zone 'UTC')::date;
 -- No live account interest is needed to settle a predecessor. Construct its
 -- historical immutable job/step at insertion; do not backdate an existing row.
 perform app_private.acquisition_admit(24,true);
 lookup_digest:=sha256(convert_to(jsonb_build_array('lookup','2403.51006',1)::text,'UTF8'));
 insert into app_private.acquisition_source_slots(id,source_id,requested_revision) values(slot,'2403.51006',1);
 insert into app_private.acquisition_jobs(id,kind,source_slot_id,slot_generation,source_id,requested_revision,input_sha256,stage,slots_held,execution_contract,created_at)
 values(j,'lookup',slot,1,'2403.51006',1,lookup_digest,'atom',24,'metadata-v2',started);
 update app_private.acquisition_source_slots set generation=1,active_job_id=j where id=slot;
 insert into app_private.acquisition_commands(id,request_sha256,job_id,created_at) values(j,lookup_digest,j,started);
 b:=test.linux_binding(c); digest:=sha256(convert_to(jsonb_build_array('metadata-stage-v2',j,c,'staging',b)::text,'UTF8'));
 insert into app_private.acquisition_steps(job_id,operation_id,request_sha256,kind,generation,stage,network_token,network_granted_at,network_byte_ceiling,network_period,created_at)
 values(j,c,digest,'metadata_stage_v2',1,'atom',attempt,started,1048576,old_month,started);
 insert into app_private.execution_attempts(id,job_id,operation_id,generation,kind,request_sha256,epoch,policy_id,project_ref,environment,binding,binding_sha256,
  host_id,boot_id,process_id,process_start_id,child_id,scope_id,useful_deadline,report_deadline,byte_ceiling,charge_period,created_at)
 select attempt,j,c,1,'atom',digest,a.epoch,a.active_policy_id,a.project_ref,a.environment,b,sha256(convert_to(b::text,'UTF8')),
  (b->>'host_id')::uuid,(b->>'boot_id')::uuid,(b->>'process_id')::bigint,b->>'process_start_id',(b->>'child_id')::uuid,c,
  started+interval '120 seconds',started+interval '120 seconds',1048576,old_month,started from app_private.executor_authority a;
 update app_private.acquisition_jobs set generation=1,claim_id=c,status='leased',lease_until=started+interval '120 seconds',atom_attempts=1 where id=j;
 update app_private.arxiv_network_gate set token=attempt,job_id=j,operation_id=c,granted_at=started,hard_deadline=null where singleton;
 insert into app_private.acquisition_transfer_windows(period,scope,kind,charged) values(old_month,'environment','source_bytes',1048576),(old_day,'environment','source_requests',1)
 on conflict(period,scope,kind) do update set charged=app_private.acquisition_transfer_windows.charged+excluded.charged;
 select charged into old_charge from app_private.acquisition_transfer_windows where period=old_month and kind='source_bytes';
 select charged into current_charge from app_private.acquisition_transfer_windows where period=current_month and kind='source_bytes';
 select jsonb_agg(to_jsonb(w) order by period) into requests from app_private.acquisition_transfer_windows w where kind='source_requests';
 e:=app_private.execution_entry(attempt);
 perform test.executor_close(e,'executor');
 perform test.executor_close(e,'arxiv_connection',true,receipt);
 perform test.executor_close(e,'arxiv_connection',true,receipt);
 perform test.assert(old_month<>current_month and (select charged=old_charge-(1048576-100) from app_private.acquisition_transfer_windows where period=old_month and kind='source_bytes')
  and (select charged=current_charge from app_private.acquisition_transfer_windows where period=current_month and kind='source_bytes'),'late complete-body refund affects original month exactly once');
 perform test.assert(requests=(select jsonb_agg(to_jsonb(w) order by period) from app_private.acquisition_transfer_windows w where kind='source_requests'),'late retirement never refunds old or current daily request window');
end $$;

-- Explicit legacy activation remains possible only after all Linux holds close;
-- it removes the pins and retains v1 evidence/ordering, without accepting scope.
do $$ declare policy uuid; rev bigint; r jsonb; j uuid; c uuid:=gen_random_uuid(); b jsonb; e jsonb; begin
 select id into strict policy from app_private.executor_policies where kind='metadata-owned-child-v1';
 select revision into rev from app_private.executor_authority;
 perform test.executor_call('science_reader_executor_admitter',format('select public.worker_retire_metadata_executor(%s)',rev));
 r:=test.executor_call('science_reader_executor_admitter',format('select public.worker_activate_metadata_executor(%s,''abcdefghijklmnopqrst'',%L,decode(repeat(''e'',64),''hex''))',rev+1,policy));
 perform test.assert(r->'admitted_host_id'='null'::jsonb and r->'admitted_boot_id'='null'::jsonb and r->'admitted_deployment_id'='null'::jsonb,'legacy activation explicitly clears Linux-only pins');
 j:=test.executor_job('2403.51007'); b:=test.executor_binding(); update app_private.arxiv_network_gate set next_allowed_at='-infinity';
 perform test.reject(format('select test.executor_call(''science_reader_metadata_executor'',%L)',
  format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,c,b||jsonb_build_object('version',2,'scope',test.linux_binding(c)->'scope'))),'invalid_executor_binding');
 r:=test.executor_call('science_reader_metadata_executor',format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,c,b)); e:=r->'execution';
 perform test.reject(format('select test.linux_close(%L,''executor'')',e),'execution_evidence_binding');
 perform test.executor_close(e,'arxiv_connection');
 perform test.assert(app_private.execution_pending((e->>'id')::uuid,'executor'),'v1 source-before-executor behavior is preserved');
 perform test.executor_close(e,'executor');
end $$;
rollback;
