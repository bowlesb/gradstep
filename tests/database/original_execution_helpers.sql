-- Disposable local SQL fixtures only. These synthetic claims and receipts do
-- not attest to a real process, file, Storage service, parser or admitted host.
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
create or replace function test.original_call(actor text,statement text) returns jsonb language plpgsql as $$
declare previous text:=current_setting('role'); result jsonb; begin
 perform set_config('role',actor,true);
 begin execute statement into result;
 exception when others then perform set_config('role',previous,true); raise; end;
 perform set_config('role',previous,true); return result;
end $$;
create sequence test.original_process_sequence start 20000 minvalue 1 maxvalue 2147483647;

create function test.original_meta_binding(claim uuid default gen_random_uuid()) returns jsonb language plpgsql as $$
declare pid bigint:=nextval('test.original_process_sequence'); result jsonb; begin
 select jsonb_build_object('version',2,'project_ref',a.project_ref,'environment',a.environment,'epoch',a.epoch,'policy_id',p.id,
  'runner_sha256',encode(p.runner_sha256,'hex'),'transport_sha256',encode(p.transport_sha256,'hex'),'observer_sha256',encode(p.observer_sha256,'hex'),
  'deployment_id',a.admitted_deployment_id,'host_id',a.admitted_host_id,'boot_id',a.admitted_boot_id,
  'process_id',pid,'process_start_id','123456','child_id',gen_random_uuid(),
  'scope',jsonb_build_object('kind','linux-systemd-cgroup-v1','scope_id',claim,'invocation_id',repeat('1',32),
   'cgroup_device','0','cgroup_inode',pid::text,'capture_sha256',repeat('1',64))) into result
 from app_private.executor_authority a join app_private.executor_policies p on p.id=a.active_policy_id;
 return result;
end $$;
create function test.original_meta_close(e jsonb,resource text,known boolean default true,receipt uuid default gen_random_uuid()) returns jsonb language plpgsql as $$
declare facts jsonb; begin
 facts:=jsonb_build_object('binding_sha256',e->>'binding_sha256','disposition',case when known then 'exited' else 'killed' end);
 if resource='arxiv_connection' then facts:=facts||jsonb_build_object('framing',case when known then 'content_length' else 'unknown' end,'peer_eof',false,
  'actual_bytes',case when known then 100 end,'body_sha256',case when known then repeat('f',64) end,'status_code',case when known then 200 end,'retry_after_seconds',0); end if;
 return test.original_call('science_reader_execution_observer',format('select public.worker_record_metadata_quiescence(%L,%L,%L,''owned_child_joined'',%L)',
  e->>'id',receipt,resource,facts));
end $$;

create function test.original_lookup(src text,eligible boolean default true) returns jsonb language plpgsql as $$
declare a uuid:=gen_random_uuid(); i uuid:=gen_random_uuid(); j uuid; c uuid; r jsonb; e jsonb; body jsonb; current_stage text;
begin
 insert into auth.users values(a);
 perform set_config('request.jwt.claim.sub',a::text,true);
 r:=public.v2_begin_import(i,src,0,1);
 j:=(test.original_call('science_reader_metadata_executor',format('select public.worker_prepare_acquisition(%L,%L,1)',gen_random_uuid(),src))->'job'->>'id')::uuid;
 perform test.original_call('science_reader_metadata_executor',format('select public.worker_link_import_acquisition(%L,%L,1,%s,%L)',a,i,r->'entry'->>'state_seq',j));
 for current_stage in select unnest(array['atom','license']) loop
  if (select status='complete' from app_private.acquisition_jobs where id=j) then exit; end if;
  perform test.assert((select stage=current_stage from app_private.acquisition_jobs where id=j),'fixture metadata stage order');
  c:=gen_random_uuid();
  update app_private.arxiv_network_gate set next_allowed_at='-infinity';
  r:=test.original_call('science_reader_metadata_executor',format('select public.worker_claim_metadata_stage_v2(%L,%L,''staging'',%L)',j,c,test.original_meta_binding(c)));
  perform test.assert(r->'granted'='true'::jsonb,'fixture metadata grant'); e:=r->'execution';
  perform test.original_meta_close(e,'executor');
  perform test.original_meta_close(e,'arxiv_connection');
  if current_stage='atom' then
   body:=jsonb_build_object('revision',1,'metadata',jsonb_build_object('title','Synthetic original execution','authors',jsonb_build_array('Fixture Author'),
    'categories',jsonb_build_array('cs.LG'),'published_at','2024-03-01','updated_at','2024-03-02'),
    'atom_published_at','2024-03-01T09:01:02.000Z','atom_updated_at','2024-03-02T10:02:03.000Z');
  elsif eligible then
   body:=jsonb_build_object('eligible',true,'license_uri','https://creativecommons.org/licenses/by/4.0/',
    'evidence',jsonb_build_object('source_id',src,'source_revision',1,'source_url','https://arxiv.org/abs/'||src||'v1',
     'license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_format','arXivRaw','evidence_sha256',repeat('f',64),
     'observed_at',to_char(clock_timestamp() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
     'latest_version_at','2024-03-02T10:02:03.000Z'));
  else body:='{"eligible":false,"reason":"license_not_supported"}';
  end if;
  perform test.original_call('science_reader_metadata_executor',format('select public.worker_finish_metadata_stage_v2(%L,%L,%s,%L,decode(repeat(''f'',64),''hex''),%L)',
   j,c,e->>'generation',e->>'id',body));
 end loop;
 perform test.original_call('science_reader_metadata_executor',format('select public.worker_project_import_acquisition(%L,%L,1)',a,i));
 update app_private.arxiv_network_gate set next_allowed_at='-infinity';
 return jsonb_build_object('account_id',a,'import_id',i,'lookup_job_id',j);
end $$;

create function test.original_job(src text) returns jsonb language plpgsql as $$
declare fixture jsonb:=test.original_lookup(src); j uuid; r uuid:=gen_random_uuid(); state jsonb;
begin
 state:=test.original_call('science_reader_original_executor',format('select public.worker_prepare_original_v1(%L,%L)',gen_random_uuid(),fixture->>'lookup_job_id'));
 j:=(state->'job'->>'id')::uuid;
 perform test.assert(j is not null,'fixture prepared original ID');
 state:=test.original_call('science_reader_original_executor',format('select public.worker_import_state(%L,%L)',fixture->>'account_id',fixture->>'import_id'));
 perform test.original_call('science_reader_original_executor',format('select public.worker_link_import_acquisition(%L,%L,1,%s,%L,%L)',
  fixture->>'account_id',fixture->>'import_id',state->'entry'->>'state_seq',fixture->>'lookup_job_id',j));
 perform test.original_call('science_reader_original_executor',format('select public.worker_reserve_original_v1(%L,%L,%L)',j,gen_random_uuid(),r));
 return fixture||jsonb_build_object('original_job_id',j,'reservation_id',r);
end $$;

create function test.original_enable(seconds integer default 120) returns jsonb language plpgsql as $$
declare d jsonb; profile uuid; metadata_policy uuid; original_policy uuid; authority app_private.executor_authority;
begin
 perform test.assert(seconds between 1 and 120,'fixture policy duration');
 select * into strict authority from app_private.executor_authority;
 if authority.enabled then
  perform test.original_call('science_reader_executor_admitter',format('select public.worker_retire_metadata_executor(%s)',authority.revision));
 end if;
 d:=jsonb_build_object('version',1,'kind','original-loopback-verifier-v1','local_fixture_only',true,'evidence_scope','synthetic-sql-fixture',
  'parser_profile_sha256','c8478d6e1b1f7a8631132789a471a7f525123f40d2e893890254fb1660b54962',
  'build_sha256','39980de20b9cd8717d10318e8f0c0a8869bf184c1292fe31987fe34c6e707610',
  'max_bytes',5242880,'max_pages',50,'wasm_memory_bytes',67108864,'host_memory_bytes',268435456,'cpu_ms',2000,'wall_ms',5000,
  'measurement','owned-process-rss-upper-envelope-v1','host_policy_sha256',repeat('8',64));
 select id into profile from app_private.paper_verification_profiles where definition=d order by id limit 1;
 if profile is null then
  profile:=gen_random_uuid();
  perform test.original_call('science_reader_executor_admitter',format('select public.worker_install_original_verification_profile_v1(%L,%L)',profile,d::text));
 end if;
 d:=jsonb_build_object('version',1,'kind','metadata-linux-scope-v1','connection_model','direct-owned-socket-v1','max_executors',1,
  'runner_sha256',repeat('a',64),'transport_sha256',repeat('b',64),'observer_sha256',repeat('c',64),'admission_sha256',repeat('d',64),
  'max_useful_seconds',120,'max_report_seconds',120);
 select id into metadata_policy from app_private.executor_policies where definition=d order by id limit 1;
 if metadata_policy is null then
  metadata_policy:=gen_random_uuid();
  perform test.original_call('science_reader_executor_admitter',format('select public.worker_install_metadata_executor_policy(%L,%L)',metadata_policy,d::text));
 end if;
 d:=jsonb_build_object('version',1,'kind','original-loopback-scope-v1','local_fixture_only',true,'connection_model','direct-owned-socket-v1','max_executors',1,
  'runner_sha256',repeat('1',64),'transport_sha256',repeat('2',64),'observer_sha256',repeat('3',64),'admission_sha256',repeat('4',64),
  'max_useful_seconds',seconds,'max_report_seconds',seconds,'storage_policy_sha256',repeat('5',64),'spool_policy_sha256',repeat('6',64),
  'verification_profile_id',profile,'verifier_host_policy_sha256',repeat('8',64),
  'stage_recipes',jsonb_build_object('download',repeat('1',64),'upload',repeat('2',64),'readback',repeat('3',64),'verify',repeat('4',64)),
  'storage_model','loopback-object-fixture-v1');
 select id into original_policy from app_private.executor_policies where definition=d order by id limit 1;
 if original_policy is null then
  original_policy:=gen_random_uuid();
  perform test.original_call('science_reader_executor_admitter',format('select public.worker_install_original_executor_policy_v1(%L,%L)',original_policy,d::text));
 end if;
 return test.original_call('science_reader_executor_admitter',format('select public.worker_activate_original_executor_v1(%s,''abcdefghijklmnopqrst'',%L,%L,
  ''c1300000-0000-4000-8000-000000000001'',''c1300000-0000-4000-8000-000000000002'',''metadata-original-sql-fixture'',''original-sql-fixture'',decode(repeat(''e'',64),''hex''))',
  (select revision from app_private.executor_authority),metadata_policy,original_policy));
end $$;

create function test.original_claim_args(fixture jsonb,stage text,claim uuid default gen_random_uuid()) returns jsonb language plpgsql as $$
declare state jsonb; pid bigint:=nextval('test.original_process_sequence'); b jsonb;
begin
 state:=test.original_call(case when stage='original_verify' then 'science_reader_pdf_verifier' else 'science_reader_original_executor' end,
  format('select public.worker_original_job_state(%L)',fixture->>'original_job_id'));
 perform test.assert(state->'next_request'->>'kind'=stage and state->>'request_sha256' is not null,'fixture next request kind/hash');
 select jsonb_build_object('version',3,'project_ref',a.project_ref,'environment',a.environment,'epoch',a.epoch,'policy_id',p.id,
  'runner_sha256',encode(p.runner_sha256,'hex'),'transport_sha256',encode(p.transport_sha256,'hex'),'observer_sha256',encode(p.observer_sha256,'hex'),
  'deployment_id',a.original_deployment_id,'host_id',a.admitted_host_id,'boot_id',a.admitted_boot_id,
  'process_id',pid,'process_start_id','123456','child_id',gen_random_uuid(),'request_sha256',state->>'request_sha256',
  'scope',jsonb_build_object('kind','linux-systemd-cgroup-v1','scope_id',claim,'invocation_id',repeat('1',32),
   'cgroup_device','0','cgroup_inode',pid::text,'capture_sha256',repeat('1',64))) into b
 from app_private.executor_authority a join app_private.executor_policies p on p.id=a.original_policy_id;
 return jsonb_build_object('job_id',fixture->>'original_job_id','claim_id',claim,'stage',stage,
  'expected_request_sha256',state->>'request_sha256','binding',b);
end $$;

create function test.original_grant(args jsonb) returns jsonb language plpgsql as $$
begin
 return test.original_call(case when args->>'stage'='original_verify' then 'science_reader_pdf_verifier' else 'science_reader_original_executor' end,
  format('select public.worker_claim_original_stage_v1(%L,%L,''staging'',%L,decode(%L,''hex''),%L)',
   args->>'job_id',args->>'claim_id',args->>'stage',args->>'expected_request_sha256',args->'binding'));
end $$;

create function test.original_result(e jsonb) returns jsonb language plpgsql as $$
declare raw text; d jsonb; purpose text; bytes bigint; hash text; profile app_private.paper_verification_profiles;
begin
 if e->>'kind' in ('original_download','original_readback') then
  purpose:=case e->>'kind' when 'original_download' then 'source_download' else 'stored_readback' end;
  bytes:=coalesce((e->>'candidate_bytes')::bigint,1000);
  hash:=coalesce(e->>'candidate_sha256',encode(sha256(convert_to(e->>'reservation_id','UTF8')),'hex'));
  -- Independent fixture serialization of the component's closed ASCII schema.
  -- Do not compute the expected digest with the production SQL encoder.
  raw:=format('{"attempt_id":"%s","binding_sha256":"%s","bytes":%s,"capture_sha256":"%s","claim_id":"%s","format":"original-spool-v1","guardian":{"device":"0","inode":"2"},"producer":{"device":"0","inode":"1"},"purpose":"%s","request_sha256":"%s","reservation_id":"%s","sha256":"%s"}',
   e->>'id',e->>'binding_sha256',bytes,e#>>'{binding,scope,capture_sha256}',e->>'claim_id',purpose,e->>'request_sha256',e->>'reservation_id',hash)||chr(10);
  d:=raw::jsonb;
  return jsonb_build_object('kind',e->>'kind'||'_v1','spool_descriptor',d,'spool_descriptor_sha256',encode(sha256(convert_to(raw,'UTF8')),'hex'));
 elsif e->>'kind'='original_upload' then
  return jsonb_build_object('kind','original_upload_v1','upload_ack_sha256',repeat('9',64));
 elsif e->>'kind'='original_verify' then
  select * into strict profile from app_private.paper_verification_profiles where id=(e#>>'{request,verification_profile_id}')::uuid;
  return jsonb_build_object('kind','original_verification_v1','outcome','verified','profile_id',profile.id,
   'build_sha256',encode(profile.build_sha256,'hex'),'parser_profile_sha256',profile.definition->>'parser_profile_sha256',
   'sha256',e->>'candidate_sha256','byte_count',(e->>'candidate_bytes')::bigint,'page_count',3,
   'metrics',jsonb_build_object('cpu_ms',100,'wall_ms',200,'peak_host_bytes',1048576,'wasm_bytes',1048576,'warnings',0,'repaired',false),
   'host_evidence',jsonb_build_object('kind','synthetic-sql-fixture','host_policy_sha256',profile.definition->>'host_policy_sha256',
    'measurement','owned-process-rss-upper-envelope-v1','evidence_sha256',repeat('7',64)));
 else raise exception 'unknown_fixture_original_stage';
 end if;
end $$;

create function test.original_close(e jsonb,resource text,known boolean default true,receipt uuid default gen_random_uuid()) returns jsonb language plpgsql as $$
declare facts jsonb; kind text:='owned_scope_retired_v1'; policy app_private.executor_policies;
begin
 facts:=jsonb_build_object('binding_sha256',e->>'binding_sha256','scope_id',e#>>'{binding,scope,scope_id}',
  'capture_sha256',e#>>'{binding,scope,capture_sha256}','fence_sha256',repeat('2',64),'observation_sha256',repeat('3',64));
 if resource in ('arxiv_connection','object_read') then
  facts:=facts||jsonb_build_object('framing',case when known then 'content_length' else 'unknown' end,'peer_eof',false,
   'actual_bytes',case when known then coalesce((e->>'candidate_bytes')::bigint,1000) end,
   'body_sha256',case when known then coalesce(e->>'candidate_sha256',encode(sha256(convert_to(e->>'reservation_id','UTF8')),'hex')) end,
   'status_code',case when known then 200 end,'retry_after_seconds',0);
  if known then kind:='original_transfer_complete_v1'; end if;
 elsif resource='object_write' then
  perform test.assert(known,'an unknown upload cannot be settled by the fixture');
  select * into strict policy from app_private.executor_policies where id=(e->>'policy_id')::uuid;
  kind:='storage_upload_ack_v1';
  facts:=facts||jsonb_build_object('bucket',e#>>'{request,bucket}','path',e#>>'{request,path}',
   'sha256',e->>'candidate_sha256','byte_count',(e->>'candidate_bytes')::bigint,
   'storage_policy_sha256',policy.definition->>'storage_policy_sha256','ack_sha256',repeat('9',64),
   'status_code',201,'response_complete',true);
 end if;
 return test.original_call('science_reader_execution_observer',format('select public.worker_record_original_quiescence(%L,%L,%L,%L,%L)',
  e->>'id',receipt,resource,kind,facts));
end $$;

create function test.original_complete(fixture jsonb,stage text) returns jsonb language plpgsql as $$
declare args jsonb; r jsonb; e jsonb; resource text;
begin
 update app_private.arxiv_network_gate set next_allowed_at='-infinity';
 args:=test.original_claim_args(fixture,stage); r:=test.original_grant(args);
 perform test.assert(r->'granted'='true'::jsonb,'fixture original stage granted'); e:=r->'execution';
 perform test.original_close(e,'executor');
 for resource in select jsonb_array_elements_text(e->'pending_resources') loop
  if resource<>'executor' then perform test.original_close(e,resource); end if;
 end loop;
 if stage='original_verify' then
  perform test.original_call('science_reader_pdf_verifier',format('select public.worker_finish_original_verification_v1(%L,%L,%s,%L,%s,%L)',
   e->>'job_id',e->>'claim_id',e->>'generation',e->>'id',e->>'verification_generation',test.original_result(e)));
 else
  perform test.original_call('science_reader_original_executor',format('select public.worker_finish_original_stage_v1(%L,%L,%s,%L,%L)',
   e->>'job_id',e->>'claim_id',e->>'generation',e->>'id',test.original_result(e)));
 end if;
 return e;
end $$;

create function test.original_finish_statement(e jsonb,result jsonb default null) returns text language sql as $$
 select case when e->>'kind'='original_verify' then
  format('select public.worker_finish_original_verification_v1(%L,%L,%s,%L,%s,%L)',
   e->>'job_id',e->>'claim_id',e->>'generation',e->>'id',e->>'verification_generation',coalesce(result,test.original_result(e)))
 else format('select public.worker_finish_original_stage_v1(%L,%L,%s,%L,%L)',
  e->>'job_id',e->>'claim_id',e->>'generation',e->>'id',coalesce(result,test.original_result(e))) end
$$;
create function test.original_reject_result(e jsonb,result jsonb,expected text) returns void language plpgsql as $$
begin
 perform test.reject(format('select test.original_call(%L,%L)',
  case when e->>'kind'='original_verify' then 'science_reader_pdf_verifier' else 'science_reader_original_executor' end,
  test.original_finish_statement(e,result)),expected);
end $$;
create function test.original_snapshot() returns jsonb language plpgsql as $$
declare t text; rows jsonb; snapshot jsonb:='{}'; begin
 for t in select tablename from pg_tables where schemaname='app_private' order by tablename loop
  execute format('select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text),''[]''::jsonb) from app_private.%I t',t) into rows;
  snapshot:=snapshot||jsonb_build_object(t,rows);
 end loop;
 return snapshot;
end $$;

grant usage on schema test to anon,authenticated,service_role,science_reader_pdf_verifier,science_reader_original_executor,
 science_reader_metadata_executor,science_reader_execution_observer,science_reader_executor_admitter;
grant execute on all functions in schema test to anon,authenticated,service_role,science_reader_pdf_verifier,science_reader_original_executor,
 science_reader_metadata_executor,science_reader_execution_observer,science_reader_executor_admitter;
