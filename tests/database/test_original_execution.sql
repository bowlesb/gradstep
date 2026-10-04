-- SQL authority/accounting tests with synthetic process and service facts.
-- No original PDF, live Storage request, parser measurement or host admission.
\ir original_execution_helpers.sql

begin;
select test.assert((select not enabled and recovery_required and not original_admitted
 and original_policy_id is null and original_deployment_id is null from app_private.executor_authority),
 '013 starts disabled without an original policy or deployment');
select test.assert((select not metadata_enabled and not original_enabled and not verification_enabled
 and active_verification_profile is null from app_private.acquisition_policy),'013 enables no worker');
select test.assert(not exists(select 1 from app_private.executor_policies),'013 installs no policy');
select test.assert(not exists(select 1 from pg_tables where schemaname='app_private' and not rowsecurity),'013 private relations have RLS');
select test.assert((select not rolcanlogin and not rolinherit and not rolsuper and not rolcreatedb
 and not rolcreaterole and not rolreplication and not rolbypassrls from pg_roles
 where rolname='science_reader_original_executor'),'original executor is a narrow NOLOGIN capability');

-- The actual SQL caller role is checked even after an accidental EXECUTE grant.
do $$ declare actor text; f record; begin
 foreach actor in array array['anon','authenticated','service_role','science_reader_metadata_executor',
  'science_reader_execution_observer','science_reader_executor_admitter'] loop
  perform set_config('role',actor,true);
  perform test.reject('select public.worker_claim_original_stage_v1(gen_random_uuid(),gen_random_uuid(),''staging'',''original_download'',decode(repeat(''a'',64),''hex''),''{}'')','permission denied');
  perform test.reject('select public.worker_prepare_original_v1(gen_random_uuid(),gen_random_uuid())','permission denied');
  perform set_config('role','none',true);
 end loop;
 foreach actor in array array['anon','authenticated','service_role','science_reader_metadata_executor',
  'science_reader_original_executor','science_reader_pdf_verifier','science_reader_executor_admitter'] loop
  perform set_config('role',actor,true);
  perform test.reject('select public.worker_record_original_quiescence(gen_random_uuid(),gen_random_uuid(),''executor'',''owned_scope_retired_v1'',''{}'')','permission denied');
  perform set_config('role','none',true);
 end loop;
 foreach actor in array array['science_reader_original_executor','science_reader_pdf_verifier','science_reader_metadata_executor',
  'science_reader_execution_observer','science_reader_executor_admitter'] loop
  perform set_config('role',actor,true);
  perform test.reject('select * from app_private.execution_attempts','permission denied');
  perform test.reject('select * from app_private.paper_asset_reservations','permission denied');
  perform set_config('role','none',true);
 end loop;
 foreach actor in array array['anon','authenticated','service_role','science_reader_original_executor','science_reader_pdf_verifier',
  'science_reader_metadata_executor','science_reader_execution_observer','science_reader_executor_admitter'] loop
  for f in select oid::regprocedure as sig from pg_proc where pronamespace='public'::regnamespace and proname in (
   'worker_claim_arxiv_stage','worker_finish_arxiv_request','worker_finish_lookup','worker_fail_acquisition','worker_claim_acquisition',
   'worker_prepare_original','worker_reserve_original','worker_record_original_upload','worker_claim_original_verification','worker_record_original_verification',
   'worker_verification_input_unavailable','worker_record_original_integrity_failure','worker_publish_original','worker_bind_lookup_original',
   'worker_set_original_availability','worker_claim_original_orphans','worker_confirm_original_deleted','worker_authorize_original_read',
   'worker_record_arxiv_metadata','worker_approve_arxiv_asset') loop
   perform test.assert(not has_function_privilege(actor,f.sig,'EXECUTE'),'legacy original/execution remains denied to '||actor||':'||f.sig);
  end loop;
 end loop;
end $$;

grant execute on function public.worker_record_original_quiescence(uuid,uuid,text,text,jsonb) to science_reader_original_executor;
set local role science_reader_original_executor;
select test.reject('select public.worker_record_original_quiescence(gen_random_uuid(),gen_random_uuid(),''executor'',''owned_scope_retired_v1'',''{}'')','executor_authority_required');
reset role;
revoke execute on function public.worker_record_original_quiescence(uuid,uuid,text,text,jsonb) from science_reader_original_executor;

-- Fixtures below exercise the public capability routes. Direct test-owner
-- writes are restricted to controlled time/capacity/race setup, never successful
-- grant/result/receipt manufacture by table insertion on the ordinary path.
select test.original_enable();

savepoint happy_path;
do $$ declare f jsonb:=test.original_job('2404.71001'); e jsonb; r jsonb; old jsonb; stage text; operation uuid:=gen_random_uuid(); state jsonb;
begin
 perform test.assert((select slots_held=28 and execution_contract='original-v1' from app_private.acquisition_jobs
  where id=(f->>'original_job_id')::uuid),'original prepays its complete 28-slot envelope');
 foreach stage in array array['original_download','original_upload','original_readback','original_verify'] loop
  e:=test.original_complete(f,stage);
  perform test.assert(not app_private.execution_unsettled((e->>'id')::uuid),'every successful stage has all required closures');
  old:=(select to_jsonb(j) from app_private.acquisition_jobs j where id=(f->>'original_job_id')::uuid);
  if stage='original_verify' then
   r:=test.original_call('science_reader_pdf_verifier',format('select public.worker_finish_original_verification_v1(%L,%L,%s,%L,%s,%L)',
    e->>'job_id',e->>'claim_id',e->>'generation',e->>'id',e->>'verification_generation',test.original_result(e)));
   perform test.assert(r->'replayed'='true'::jsonb,'verifier result acknowledgement replay');
  else
   perform test.original_call('science_reader_original_executor',format('select public.worker_finish_original_stage_v1(%L,%L,%s,%L,%L)',
    e->>'job_id',e->>'claim_id',e->>'generation',e->>'id',test.original_result(e)));
  end if;
  perform test.assert((select to_jsonb(j)=old from app_private.acquisition_jobs j where id=(f->>'original_job_id')::uuid),'result replay does not advance state');
 end loop;
 state:=test.original_call('science_reader_original_executor',format('select public.worker_original_job_state(%L)',f->>'original_job_id'));
 perform test.assert(state->'job'->>'stage'='publish','verification admits publication');
 r:=test.original_call('science_reader_original_executor',format('select public.worker_publish_original_v1(%L,%L,%L,%L)',
  f->>'original_job_id',operation,f->>'reservation_id',state->'reservation'->>'verification_result_id'));
 perform test.assert(r->>'status'='complete','original published');
 old:=r;
 r:=test.original_call('science_reader_original_executor',format('select public.worker_publish_original_v1(%L,%L,%L,%L)',
  f->>'original_job_id',operation,f->>'reservation_id',state->'reservation'->>'verification_result_id'));
 perform test.assert(r=old,'publication exact acknowledgement replay');
 perform test.original_call('science_reader_original_executor',format('select public.worker_bind_lookup_original_v1(%L,%L)',f->>'lookup_job_id',f->>'original_job_id'));
 state:=test.original_call('science_reader_metadata_executor',format('select public.worker_project_import_acquisition(%L,%L,1)',f->>'account_id',f->>'import_id'));
 perform test.assert(state->'entry'->>'phase'='ready' and state->'entry'->>'library_item_id' is not null,'account import resolves into library');
 perform test.assert(app_private.library_item_entry((f->>'account_id')::uuid,(state->'entry'->>'library_item_id')::uuid)->>'readiness'='pdf_ready',
  'library entry exposes a verified PDF');
 perform test.assert((select count(*)=4 from app_private.execution_attempts where job_id=(f->>'original_job_id')::uuid),'four distinct stage grants');
 perform test.assert((select count(*)=7 from app_private.execution_quiescence q join app_private.execution_attempts e on e.id=q.attempt_id
  where e.job_id=(f->>'original_job_id')::uuid),'seven stage-specific resource closures');
 perform test.assert((select count(*)=1 from app_private.paper_verification_results where reservation_id=(f->>'reservation_id')::uuid),'one immutable verifier result');
 perform test.assert((select p.state='published' and held_bytes=candidate_bytes from app_private.paper_asset_reservations p where id=(f->>'reservation_id')::uuid),'published storage replaces active reservation capacity');
 perform app_private.original_envelope((f->>'original_job_id')::uuid);
end $$;
rollback to happy_path;

savepoint closed_policies;
do $$ declare p app_private.executor_policies; v app_private.paper_verification_profiles; d jsonb; n integer; r jsonb; bad jsonb;
begin
 select * into strict p from app_private.executor_policies where kind='original-loopback-scope-v1';
 select * into strict v from app_private.paper_verification_profiles;
 r:=test.original_call('science_reader_executor_admitter',format('select public.worker_install_original_executor_policy_v1(%L,%L)',p.id,p.canonical_policy));
 perform test.assert(r->'replayed'='true'::jsonb,'policy canonical replay');
 r:=test.original_call('science_reader_executor_admitter',format('select public.worker_install_original_verification_profile_v1(%L,%L)',v.id,v.canonical_profile));
 perform test.assert(r->'replayed'='true'::jsonb,'profile canonical replay');
 for bad in select unnest(array[
  p.definition||'{"local_fixture_only":false}', p.definition||'{"version":null}',
  p.definition||'{"storage_model":"hosted-storage"}', p.definition||'{"max_executors":2}'
 ]) loop
  perform test.reject(format('select test.original_call(''science_reader_executor_admitter'',%L)',
   format('select public.worker_install_original_executor_policy_v1(%L,%L)',gen_random_uuid(),bad::text)),'invalid_original_policy');
 end loop;
 perform test.reject(format('select test.original_call(''science_reader_executor_admitter'',%L)',
  format('select public.worker_install_original_executor_policy_v1(%L,%L)',gen_random_uuid(),(p.definition||'{"extra":true}')::text)),'invalid_original_record');
 for bad in select unnest(array[
  v.definition||'{"local_fixture_only":false}',v.definition||'{"evidence_scope":"measured-production-host"}',
  v.definition||jsonb_build_object('build_sha256',repeat('0',64))
 ]) loop
  perform test.reject(format('select test.original_call(''science_reader_executor_admitter'',%L)',
   format('select public.worker_install_original_verification_profile_v1(%L,%L)',gen_random_uuid(),bad::text)),'invalid_original_profile');
 end loop;
 perform test.reject(format('select test.original_call(''science_reader_executor_admitter'',%L)',
  format('select public.worker_install_original_executor_policy_v1(%L,%L)',p.id,(p.definition||jsonb_build_object('runner_sha256',repeat('7',64)))::text)),'operation_id_conflict');
 for n in 1..6 loop
  d:=p.definition||jsonb_build_object('runner_sha256',encode(sha256(convert_to('policy'||n,'UTF8')),'hex'));
  perform test.original_call('science_reader_executor_admitter',format('select public.worker_install_original_executor_policy_v1(%L,%L)',gen_random_uuid(),d::text));
 end loop;
 perform test.assert((select count(*)=8 from app_private.executor_policies),'metadata and original share the fixed policy pool');
 perform test.reject(format('select test.original_call(''science_reader_executor_admitter'',%L)',
  format('select public.worker_install_original_executor_policy_v1(%L,%L)',gen_random_uuid(),(p.definition||jsonb_build_object('runner_sha256',repeat('9',64)))::text)),'executor_policy_capacity');
end $$;
rollback to closed_policies;

savepoint full_envelope;
do $$ declare f jsonb:=test.original_job('2404.71002'); e jsonb; args jsonb; r jsonb; n integer; stage text; total bigint;
 j uuid:=(f->>'original_job_id')::uuid; rid uuid:=(f->>'reservation_id')::uuid;
begin
 total:=(select (32+(select count(*) from app_private.acquisition_source_slots)+(select count(*)+sum(slots_held) from app_private.acquisition_jobs)
  +(select count(*) from app_private.acquisition_commands)+2*(select count(*) from app_private.paper_verification_profiles))*8192);
 update app_private.acquisition_policy set control_bytes=total;
 perform test.reject(format('select test.original_call(''science_reader_original_executor'',%L)',
  format('select public.worker_prepare_original_v1(%L,%L)',gen_random_uuid(),f->>'lookup_job_id')),'acquisition_control_capacity');
 for n in 1..6 loop
  stage:=case n when 1 then 'original_download' when 2 then 'original_download' when 3 then 'original_upload'
   when 4 then 'original_readback' when 5 then 'original_readback' else 'original_verify' end;
  update app_private.acquisition_jobs set next_attempt_at='-infinity' where id=j;
  update app_private.arxiv_network_gate set next_allowed_at='-infinity';
  if n in (1,4) then
   args:=test.original_claim_args(f,stage); r:=test.original_grant(args); e:=r->'execution';
   perform test.assert(r->'granted'='true'::jsonb,'failure attempt admitted within prepaid envelope');
   perform test.original_close(e,'executor');
   perform test.original_close(e,case n when 1 then 'arxiv_connection' else 'object_read' end,false);
   perform test.original_call('science_reader_original_executor',format('select public.worker_fail_original_stage_v1(%L,%L,%s,%L,''download_failed'',true)',
    j,e->>'claim_id',e->>'generation',e->>'id'));
  else e:=test.original_complete(f,stage); end if;
 end loop;
 r:=test.original_call('science_reader_original_executor',format('select public.worker_publish_original_v1(%L,%L,%L,%L)',
  j,gen_random_uuid(),rid,(select verification_result_id from app_private.paper_asset_reservations where id=rid)));
 perform test.assert(r->>'status'='complete','maximum six attempts publish at a full control pool');
 perform test.assert((select count(*)=8 from app_private.acquisition_steps where job_id=j)
  and (select count(*)=6 from app_private.execution_attempts where job_id=j)
  and (select count(*)=11 from app_private.execution_quiescence q join app_private.execution_attempts e on e.id=q.attempt_id where e.job_id=j)
  and (select count(*)=1 from app_private.paper_asset_reservations where job_id=j)
  and (select count(*)=1 from app_private.paper_verification_results where reservation_id=rid),
  'maximum chain fits 28 slots including one retained integrity allowance');
 perform test.assert((select slots_held=28 and download_attempts=2 and status='complete' and error_code is null and not retryable
  from app_private.acquisition_jobs where id=j),'terminal original retains prepaid headroom and clears retry error');
 perform test.assert((select sum(charged)=5242880+1000+200 from app_private.acquisition_transfer_windows where kind='source_bytes'),
  'unknown first download keeps full charge; complete retry and two metadata bodies charge actual bytes');
 perform test.assert((select sum(charged)=5242880+1000 from app_private.acquisition_transfer_windows where kind='worker_bytes'),
  'unknown first stored read retains ceiling; complete second read refunds excess');
 perform test.assert((select sum(charged)=1000 from app_private.acquisition_transfer_windows where kind='object_upload_bytes'),'one bounded upload charge');
 perform test.assert((select sum(charged)=4 from app_private.acquisition_transfer_windows where kind='source_requests'),'two metadata and two PDF source requests');
 perform test.reject(format('update app_private.acquisition_jobs set slots_held=27 where id=%L',j),'original_execution_envelope');
 perform app_private.original_envelope(j);
end $$;
rollback to full_envelope;

savepoint bounded_identity;
do $$ declare f jsonb:=test.original_job('2404.71003'); args jsonb; bad jsonb; e jsonb; result jsonb; d jsonb; k text; old jsonb; row jsonb;
 j uuid:=(f->>'original_job_id')::uuid; receipt uuid:=gen_random_uuid(); r jsonb;
begin
 args:=test.original_claim_args(f,'original_download'); old:=test.original_snapshot();
 foreach k in array array['original_download','original_upload','original_readback'] loop
  perform test.reject(format('select test.original_call(''science_reader_pdf_verifier'',%L)',
   format('select public.worker_claim_original_stage_v1(%L,%L,''staging'',%L,decode(%L,''hex''),%L)',
    args->>'job_id',args->>'claim_id',k,args->>'expected_request_sha256',args->'binding')),'executor_authority_required');
 end loop;
 for bad in select unnest(array[
  jsonb_set(args,'{binding,version}','2'),jsonb_set(args,'{binding,epoch}',to_jsonb(gen_random_uuid()::text)),
  jsonb_set(args,'{binding,scope,scope_id}',to_jsonb(gen_random_uuid()::text)),
  jsonb_set(args,'{binding,deployment_id}','"another-deployment"'),
  jsonb_set(args,'{binding,runner_sha256}',to_jsonb(repeat('0',64)))
 ]) loop perform test.reject(format('select test.original_grant(%L)',bad),'invalid_executor_binding'); end loop;
 bad:=jsonb_set(jsonb_set(args,'{expected_request_sha256}',to_jsonb(repeat('0',64))),'{binding,request_sha256}',to_jsonb(repeat('0',64)));
 perform test.reject(format('select test.original_grant(%L)',bad),'original_request_changed');
 perform test.assert(test.original_snapshot()=old,'invalid requests and process identities leave every private row unchanged');
 r:=test.original_grant(args); e:=r->'execution';
 perform test.assert(r->'granted'='true'::jsonb,'valid original stage gets one grant'); old:=test.original_snapshot();
 r:=test.original_grant(args);
 perform test.assert(r->'granted'='false'::jsonb and r->'replayed'='true'::jsonb and r->'execution'->>'id'=e->>'id','lost grant reply returns status without repeating work');
 perform test.assert(test.original_snapshot()=old,'grant replay does not charge or allocate');
 perform test.reject(format('select app_private.execution_pending(%L,''nonsense'')',e->>'id'),'invalid_execution_resource');
 perform test.reject('select app_private.execution_unsettled(gen_random_uuid())','execution_unavailable');
 perform test.assert(not app_private.execution_pending((e->>'id')::uuid,'object_write'),'known but nonrequired resource is never pending');
 select to_jsonb(x) into row from app_private.execution_attempts x where id=(e->>'id')::uuid;
 -- Exercise actual CHECKs, including the old digest/deadline invariants, with
 -- inserted malformed copies. No immutable execution record is edited.
 perform test.reject(format('insert into app_private.execution_attempts select (jsonb_populate_record(null::app_private.execution_attempts,%L)).*',
  row||jsonb_build_object('id',gen_random_uuid(),'binding_sha256','\x'||repeat('0',64))),'execution_binding_digest_check');
 bad:=row||jsonb_build_object('id',gen_random_uuid(),'binding',jsonb_set(row->'binding','{version}','2'),
  'binding_sha256','\x'||encode(sha256(convert_to(jsonb_set(row->'binding','{version}','2')::text,'UTF8')),'hex'));
 perform test.reject(format('insert into app_private.execution_attempts select (jsonb_populate_record(null::app_private.execution_attempts,%L)).*',bad),'execution_kind_binding');
 perform test.reject(format('insert into app_private.execution_attempts select (jsonb_populate_record(null::app_private.execution_attempts,%L)).*',
  row||jsonb_build_object('id',gen_random_uuid(),'useful_deadline',row->'created_at')),'execution_attempts_check2');
 foreach k in array array['charge_kind','request_day','reservation_id','original_request_sha256','predecessor_result_sha256'] loop
  perform test.reject(format('insert into app_private.execution_attempts select (jsonb_populate_record(null::app_private.execution_attempts,%L)).*',
   row||jsonb_build_object('id',gen_random_uuid(),k,null)),'execution_original_columns');
 end loop;
 perform test.reject(format('update app_private.acquisition_jobs set original_deployment_id=null where id=%L',j),'immutable_original_policy_pin');
 perform test.reject(format('select test.original_call(''science_reader_metadata_executor'',%L)',
  format('select public.worker_fail_metadata_stage_v2(%L,%L,%s,%L,''download_failed'',true)',j,e->>'claim_id',e->>'generation',e->>'id')),'metadata_execution_contract_required');
 perform test.reject(format('select test.original_call(''science_reader_metadata_executor'',%L)',
  format('select public.worker_metadata_execution_state(%L,%L)',j,e->>'claim_id')),'metadata_execution_contract_required');
 perform test.reject(format('select test.original_call(''science_reader_execution_observer'',%L)',
  format('select public.worker_record_metadata_quiescence(%L,%L,''executor'',''owned_child_joined'',''{}'')',e->>'id',gen_random_uuid())),'metadata_execution_contract_required');
 result:=test.original_result(e);
 perform test.original_reject_result(e,result,'execution_retirement_required');
 perform test.reject(format('select test.original_close(%L,''arxiv_connection'')',e),'executor_retirement_required');
 perform test.original_close(e,'executor');
 perform test.original_reject_result(e,result,'execution_retirement_required');
 perform test.original_close(e,'arxiv_connection',true,receipt);
 old:=test.original_snapshot();
 r:=test.original_close(e,'arxiv_connection',true,gen_random_uuid());
 perform test.assert(r->>'receipt_id'=receipt::text and r->'replayed'='true'::jsonb and test.original_snapshot()=old,
  'equivalent receipt names resolve to one canonical record and refund');
 perform test.reject(format('select test.original_close(%L,''executor'',true,%L)',e,receipt),'operation_id_conflict');
 foreach k in array array['reservation_id','claim_id','attempt_id'] loop
  d:=jsonb_set(result->'spool_descriptor',array[k],to_jsonb(gen_random_uuid()::text));
  bad:=result||jsonb_build_object('spool_descriptor',d,'spool_descriptor_sha256',encode(sha256(convert_to(app_private.original_compact_json(d)||chr(10),'UTF8')),'hex'));
  perform test.original_reject_result(e,bad,'invalid_original_spool');
 end loop;
 foreach k in array array['request_sha256','binding_sha256','capture_sha256'] loop
  d:=jsonb_set(result->'spool_descriptor',array[k],to_jsonb(repeat('0',64)));
  bad:=result||jsonb_build_object('spool_descriptor',d,'spool_descriptor_sha256',encode(sha256(convert_to(app_private.original_compact_json(d)||chr(10),'UTF8')),'hex'));
  perform test.original_reject_result(e,bad,'invalid_original_spool');
 end loop;
 perform test.original_reject_result(e,result||jsonb_build_object('spool_descriptor_sha256',repeat('0',64)),'invalid_original_spool');
 perform test.original_reject_result(e,result||'{"extra":true}','invalid_original_record');
 d:=jsonb_set(result->'spool_descriptor','{bytes}','5242881');
 bad:=result||jsonb_build_object('spool_descriptor',d,'spool_descriptor_sha256',encode(sha256(convert_to(app_private.original_compact_json(d)||chr(10),'UTF8')),'hex'));
 perform test.original_reject_result(e,bad,'invalid_original_integer');
 d:=jsonb_set(result->'spool_descriptor','{guardian}',result#>'{spool_descriptor,producer}');
 bad:=result||jsonb_build_object('spool_descriptor',d,'spool_descriptor_sha256',encode(sha256(convert_to(app_private.original_compact_json(d)||chr(10),'UTF8')),'hex'));
 perform test.original_reject_result(e,bad,'invalid_original_spool');
 perform test.assert(test.original_snapshot()=old,'all malformed results leave receipts, charges and lifecycle untouched');
 perform test.original_call('science_reader_original_executor',test.original_finish_statement(e));
 -- Guard the legacy metadata replay branches after a positive original result,
 -- when returning an existing step or receipt would otherwise look harmless.
 perform test.reject(format('select test.original_call(''science_reader_metadata_executor'',%L)',
  format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,e->>'claim_id',e->'binding')),'metadata_execution_contract_required');
 perform test.reject(format('select test.original_call(''science_reader_metadata_executor'',%L)',
  format('select public.worker_fail_metadata_stage_v2(%L,%L,%s,%L,''download_failed'',true)',j,e->>'claim_id',e->>'generation',e->>'id')),'metadata_execution_contract_required');
 perform test.reject(format('select test.original_call(''science_reader_metadata_executor'',%L)',
  format('select public.worker_finish_metadata_stage_v2(%L,%L,%s,%L,decode(repeat(''f'',64),''hex''),%L)',j,e->>'claim_id',e->>'generation',e->>'id',result)),'metadata_execution_contract_required');
 perform test.reject(format('select test.original_call(''science_reader_metadata_executor'',%L)',
  format('select public.worker_metadata_execution_state(%L,%L)',j,e->>'claim_id')),'metadata_execution_contract_required');
 perform test.reject(format('select test.original_call(''science_reader_execution_observer'',%L)',
  format('select public.worker_record_metadata_quiescence(%L,%L,''arxiv_connection'',''owned_child_joined'',''{}'')',e->>'id',receipt)),'metadata_execution_contract_required');
 perform test.reject(format('update app_private.paper_asset_reservations set candidate_sha256=decode(repeat(''0'',64),''hex'') where id=%L',f->>'reservation_id'),'immutable_original_identity');
 perform test.original_reject_result(e,result||'{"extra":true}','operation_id_conflict');
end $$;
rollback to bounded_identity;

savepoint verified_profile;
do $$ declare f jsonb:=test.original_job('2404.71004'); e jsonb; args jsonb; result jsonb; bad jsonb; old jsonb; k text; stage text;
begin
 foreach stage in array array['original_download','original_upload','original_readback'] loop perform test.original_complete(f,stage); end loop;
 args:=test.original_claim_args(f,'original_verify');
 perform test.reject(format('select test.original_call(''science_reader_original_executor'',%L)',
  format('select public.worker_claim_original_stage_v1(%L,%L,''staging'',''original_verify'',decode(%L,''hex''),%L)',
   args->>'job_id',args->>'claim_id',args->>'expected_request_sha256',args->'binding')),'executor_authority_required');
 e:=test.original_grant(args)->'execution';
 result:=test.original_result(e);
 perform test.original_reject_result(e,result,'execution_retirement_required');
 perform test.original_close(e,'executor'); old:=test.original_snapshot();
 foreach k in array array['sha256','build_sha256','parser_profile_sha256'] loop
  perform test.original_reject_result(e,jsonb_set(result,array[k],to_jsonb(repeat('0',64))),'invalid_verification_binding');
 end loop;
 perform test.original_reject_result(e,jsonb_set(result,'{profile_id}',to_jsonb(gen_random_uuid()::text)),'invalid_verification_binding');
 perform test.original_reject_result(e,jsonb_set(result,'{byte_count}','1001'),'invalid_verification_binding');
 perform test.original_reject_result(e,jsonb_set(result,'{page_count}','51'),'invalid_original_integer');
 for bad in select unnest(array[
  jsonb_set(result,'{metrics,cpu_ms}','2001'),jsonb_set(result,'{metrics,wall_ms}','5001'),
  jsonb_set(result,'{metrics,peak_host_bytes}','268435457'),jsonb_set(result,'{metrics,wasm_bytes}','67108865'),
  jsonb_set(result,'{metrics,warnings}','1'),jsonb_set(result,'{metrics,repaired}','true')
 ]) loop perform test.original_reject_result(e,bad,'verification_profile_limit'); end loop;
 perform test.original_reject_result(e,jsonb_set(result,'{host_evidence,kind}','"production-measurement"'),'invalid_original_host_evidence');
 perform test.original_reject_result(e,jsonb_set(result,'{host_evidence,host_policy_sha256}',to_jsonb(repeat('0',64))),'invalid_original_host_evidence');
 perform test.original_reject_result(e,jsonb_set(result,'{verification_generation}','2'),'invalid_original_record');
 perform test.original_reject_result(jsonb_set(e,'{verification_generation}',to_jsonb((e->>'verification_generation')::bigint+1)),result,'stale_execution_attempt');
 perform test.assert(test.original_snapshot()=old,'rejected verifier outputs create no approval or result and change no retained state');
 result:=jsonb_set(jsonb_set(result,'{outcome}','"malformed"'),'{page_count}','null');
 perform test.original_call('science_reader_pdf_verifier',test.original_finish_statement(e,result));
 perform test.assert((select state='quarantined' from app_private.paper_asset_reservations where id=(f->>'reservation_id')::uuid)
  and (select status='failed' and error_code='verification_failed' from app_private.acquisition_jobs where id=(f->>'original_job_id')::uuid),
  'negative parser outcome quarantines the exact candidate');
 perform test.reject(format('select test.original_call(''science_reader_original_executor'',%L)',
  format('select public.worker_publish_original_v1(%L,%L,%L,%L)',f->>'original_job_id',gen_random_uuid(),f->>'reservation_id',
   (select verification_result_id from app_private.paper_asset_reservations where id=(f->>'reservation_id')::uuid))),'original_verification_required');
end $$;
rollback to verified_profile;

savepoint stored_integrity;
do $$ declare f jsonb:=test.original_job('2404.71005'); e jsonb; changed jsonb; result jsonb; state jsonb; old jsonb;
begin
 perform test.original_complete(f,'original_download'); perform test.original_complete(f,'original_upload');
 e:=test.original_grant(test.original_claim_args(f,'original_readback'))->'execution';
 -- The synthetic transport really reports DIFFERENT complete stored bytes.
 -- Change only the caller's observation, never the server's pinned candidate.
 changed:=e||jsonb_build_object('candidate_sha256',repeat('0',64));
 perform test.original_close(e,'executor'); perform test.original_close(changed,'object_read');
 perform test.original_reject_result(e,test.original_result(changed),'original_integrity_mismatch');
 old:=test.original_snapshot();
 result:=jsonb_build_object('kind','original_integrity_v1','outcome','binding_mismatch','complete_input',true,
  'observed_sha256',repeat('0',64),'observed_bytes',(e->>'candidate_bytes')::bigint);
 perform test.reject(format('select test.original_call(''science_reader_original_executor'',%L)',
  format('select public.worker_record_original_integrity_v1(%L,%L,%s,%L,%L)',e->>'job_id',e->>'claim_id',e->>'generation',e->>'id',
   jsonb_set(result,'{observed_sha256}',e->'candidate_sha256'))),'invalid_integrity_result');
 perform test.assert(test.original_snapshot()=old,'integrity claim must match observed stored-body proof');
 perform test.original_call('science_reader_original_executor',format('select public.worker_record_original_integrity_v1(%L,%L,%s,%L,%L)',
  e->>'job_id',e->>'claim_id',e->>'generation',e->>'id',result));
 old:=test.original_snapshot();
 perform test.original_call('science_reader_original_executor',format('select public.worker_record_original_integrity_v1(%L,%L,%s,%L,%L)',
  e->>'job_id',e->>'claim_id',e->>'generation',e->>'id',result));
 perform test.assert(test.original_snapshot()=old,'integrity acknowledgement replay is immutable');
 state:=test.original_call('science_reader_original_executor',format('select public.worker_original_job_state(%L)',f->>'original_job_id'));
 perform test.assert(state->'job'->>'status'='failed' and state->'next_request'='null'::jsonb
  and (select r.state='quarantined' and held_bytes=max_bytes from app_private.paper_asset_reservations r where id=(f->>'reservation_id')::uuid)
  and not exists(select 1 from app_private.paper_verification_results where reservation_id=(f->>'reservation_id')::uuid)
  and not exists(select 1 from app_private.catalog_asset_approvals),
  'stored-byte mismatch retains full storage hold and never reaches parser or shared publication');
end $$;
rollback to stored_integrity;

savepoint durable_policy_pin;
do $$ declare f jsonb:=test.original_job('2404.71006'); before_state jsonb; args jsonb; negative jsonb;
begin
 args:=test.original_claim_args(f,'original_download');
 before_state:=test.original_call('science_reader_original_executor',format('select public.worker_original_job_state(%L)',f->>'original_job_id'));
 perform test.original_enable(119);
 perform test.reject(format('select test.original_grant(%L)',test.original_claim_args(f,'original_download')),'original_policy_pin_mismatch');
 perform test.assert(test.original_call('science_reader_original_executor',format('select public.worker_original_job_state(%L)',f->>'original_job_id'))=before_state,
  'policy rotation cannot silently adopt a reserved original into a new policy');
 negative:=test.original_lookup('2404.71007',false);
 perform test.reject(format('select test.original_call(''science_reader_original_executor'',%L)',
  format('select public.worker_prepare_original_v1(%L,%L)',gen_random_uuid(),negative->>'lookup_job_id')),'acquisition_eligibility_required');
 perform test.reject(format('select test.original_call(''science_reader_original_executor'',%L)',
  format('select public.worker_original_job_state(%L)',negative->>'lookup_job_id')),'original_execution_contract_required');
end $$;
rollback to durable_policy_pin;

\ir original_execution_accounting.sql

rollback;
