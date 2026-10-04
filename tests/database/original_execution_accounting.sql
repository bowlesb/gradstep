-- Included inside test_original_execution.sql's transaction after enablement.
-- All historical rows below are newly INSERTed, explicitly time-shifted SQL
-- fixtures. No issued attempt is edited/backdated, no immutable trigger is
-- disabled, and no evidence is deleted. These are accounting specimens, not
-- evidence of a real historical process, socket, object service or admission.
savepoint original_accounting;

-- Build the finite accepted predecessor chain at insertion, using the current
-- fixture's immutable catalog/policy pins. The target stage remains issued.
-- Real observer RPCs supply every resource receipt, including late predecessor
-- receipts. The synthetic accepted prefix is not sent through a positive result
-- API with a fabricated fresh deadline. Nothing in this helper is production.
create function test.original_accounting_history(src text,target text) returns jsonb
language plpgsql as $$
declare f jsonb:=test.original_lookup(src); l app_private.acquisition_jobs;
 a app_private.executor_authority; policy app_private.executor_policies;
 j uuid:=gen_random_uuid(); rid uuid:=gen_random_uuid(); reserve_op uuid:=gen_random_uuid();
 -- Always more than 48 hours old, including the first instant of a new month;
 -- the 24-hour retry age and reservation must have expired on every run date.
 started timestamptz:=(date_trunc('month',clock_timestamp() at time zone 'UTC') at time zone 'UTC')-interval '2 days 1 hour';
 charged_month date; charged_day date; digest bytea; reserved jsonb; args jsonb; b jsonb; d jsonb;
 e jsonb; result jsonb; stage_kind text; claim uuid; attempt uuid; next_generation bigint:=1;
 candidate bytea; amount bigint; ceiling bigint; budget_kind text; resource text;
begin
 perform test.assert(target in ('original_download','original_upload','original_readback'),'historical transfer kind');
 select * into strict l from app_private.acquisition_jobs where id=(f->>'lookup_job_id')::uuid;
 select * into strict a from app_private.executor_authority;
 select * into strict policy from app_private.executor_policies where id=a.original_policy_id;
 perform app_private.acquisition_admit(28,false);
 digest:=sha256(convert_to(jsonb_build_array('original-v1',l.id)::text,'UTF8'));
 insert into app_private.acquisition_jobs(id,kind,source_id,requested_revision,input_sha256,metadata_id,version_id,source_revision,
  atom_published_at,atom_updated_at,eligibility,license_uri,evidence,stage,slots_held,execution_contract,created_at,
  original_policy_id,original_deployment_id,original_host_id,original_boot_id,generation,next_attempt_at)
 values(j,'original',l.source_id,l.source_revision,digest,l.metadata_id,l.version_id,l.source_revision,
  l.atom_published_at,l.atom_updated_at,l.eligibility,l.license_uri,l.evidence,'download',28,'original-v1',started,
  policy.id,a.original_deployment_id,a.admitted_host_id,a.admitted_boot_id,1,started);
 insert into app_private.acquisition_commands(id,request_sha256,job_id,created_at) values(j,digest,j,started);
 digest:=sha256(convert_to(jsonb_build_array('original-reserve-v1',j,reserve_op,rid)::text,'UTF8'));
 reserved:=jsonb_build_object('kind','original_reserve_v1','reservation_id',rid);
 insert into app_private.acquisition_steps(job_id,operation_id,request_sha256,kind,generation,stage,outcome,result,result_sha256,created_at,completed_at)
 values(j,reserve_op,digest,'original_reserve_v1',1,'reserve','complete',reserved,sha256(convert_to(reserved::text,'UTF8')),started,started);
 insert into app_private.paper_asset_reservations(id,job_id,operation_id,request_sha256,generation,path,max_bytes,held_bytes,
  verification_profile_id,expires_at,safe_after,created_at)
 values(rid,j,reserve_op,digest,1,'originals/'||rid||'/original.pdf',5242880,5242880,
  (policy.definition->>'verification_profile_id')::uuid,started+interval '24 hours',started,started);
 f:=f||jsonb_build_object('original_job_id',j,'reservation_id',rid);
 for stage_kind in select unnest(array['original_download','original_upload','original_readback']) loop
  next_generation:=next_generation+1; started:=started+interval '1 second';
  charged_month:=date_trunc('month',started at time zone 'UTC')::date;
  charged_day:=(started at time zone 'UTC')::date;
  args:=test.original_claim_args(f,stage_kind); b:=args->'binding'; claim:=(args->>'claim_id')::uuid; attempt:=gen_random_uuid();
  d:=app_private.original_next_request(j); ceiling:=(d->>'byte_ceiling')::bigint;
  budget_kind:=case stage_kind when 'original_download' then 'source_bytes' when 'original_upload' then 'object_upload_bytes' else 'worker_bytes' end;
  resource:=case stage_kind when 'original_download' then 'arxiv_connection' when 'original_upload' then 'object_write' else 'object_read' end;
  digest:=sha256(convert_to(jsonb_build_array('original-stage-v1',j,claim,'staging',stage_kind,args->>'expected_request_sha256',b)::text,'UTF8'));
  e:=jsonb_build_object('id',attempt,'job_id',j,'claim_id',claim,'generation',next_generation,'kind',stage_kind,
   'binding',b,'binding_sha256',encode(sha256(convert_to(b::text,'UTF8')),'hex'),'request_sha256',args->>'expected_request_sha256',
   'reservation_id',rid,'candidate_sha256',encode(candidate,'hex'),'candidate_bytes',amount);
  result:=case when stage_kind<>target then test.original_result(e) end;
  insert into app_private.acquisition_steps(job_id,operation_id,request_sha256,kind,generation,stage,outcome,result,result_sha256,
   network_token,network_granted_at,network_byte_ceiling,network_period,created_at,completed_at)
  values(j,claim,digest,'original_stage_v1',next_generation,substr(stage_kind,10),case when result is null then 'issued' else 'complete' end,
   result,case when result is not null then sha256(convert_to(result::text,'UTF8')) end,
   case when stage_kind='original_download' then attempt end,case when stage_kind='original_download' then started end,
   case when stage_kind='original_download' then ceiling end,case when stage_kind='original_download' then charged_month end,
   started,case when result is not null then started end);
  insert into app_private.execution_attempts(id,job_id,operation_id,generation,kind,request_sha256,epoch,policy_id,project_ref,environment,
   binding,binding_sha256,host_id,boot_id,process_id,process_start_id,child_id,scope_id,useful_deadline,report_deadline,byte_ceiling,
   charge_period,created_at,reservation_id,predecessor_operation_id,predecessor_result_sha256,original_request,original_request_sha256,
   candidate_sha256,candidate_bytes,input_spool_sha256,charge_kind,request_day)
  values(attempt,j,claim,next_generation,stage_kind,digest,a.epoch,policy.id,a.project_ref,a.environment,b,sha256(convert_to(b::text,'UTF8')),
   a.admitted_host_id,a.admitted_boot_id,(b->>'process_id')::bigint,b->>'process_start_id',(b->>'child_id')::uuid,claim,
   started+interval '120 seconds',started+interval '120 seconds',ceiling,charged_month,started,rid,
   (d->>'predecessor_operation_id')::uuid,decode(d->>'predecessor_result_sha256','hex'),d,decode(args->>'expected_request_sha256','hex'),
   candidate,amount,decode(d->>'input_spool_sha256','hex'),budget_kind,case when stage_kind='original_download' then charged_day end);
  insert into app_private.acquisition_transfer_windows(period,scope,kind,charged) values(charged_month,'environment',budget_kind,ceiling)
   on conflict(period,scope,kind) do update set charged=app_private.acquisition_transfer_windows.charged+excluded.charged;
  if stage_kind='original_download' then
   perform test.assert((select token is null from app_private.arxiv_network_gate),'historical source fixture never replaces a held gate');
   update app_private.arxiv_network_gate set token=attempt,job_id=j,operation_id=claim,generation=generation+1,
    granted_at=started,hard_deadline=null where singleton;
   insert into app_private.acquisition_transfer_windows(period,scope,kind,charged) values(charged_day,'environment','source_requests',1)
    on conflict(period,scope,kind) do update set charged=app_private.acquisition_transfer_windows.charged+1;
  end if;
  update app_private.acquisition_jobs set generation=next_generation,
   status='leased',claim_id=claim,lease_until=started+interval '120 seconds',download_attempts=1 where id=j;
  update app_private.paper_asset_reservations set generation=next_generation,
   state=case stage_kind when 'original_upload' then 'uploading' when 'original_readback' then 'pending_verification' else 'reserved' end,
   safe_after=started+interval '120 seconds' where id=rid;
  e:=app_private.execution_entry(attempt);
  if stage_kind=target then
   perform app_private.original_envelope(j);
   return f||jsonb_build_object('execution',e);
  end if;
  perform test.original_close(e,'executor');
  perform test.original_close(e,resource);
  if stage_kind='original_download' then
   candidate:=decode(result#>>'{spool_descriptor,sha256}','hex'); amount:=(result#>>'{spool_descriptor,bytes}')::bigint;
   update app_private.paper_asset_reservations set candidate_sha256=candidate,candidate_bytes=amount where id=rid;
  end if;
  update app_private.acquisition_jobs set stage=case stage_kind when 'original_download' then 'upload' else 'readback' end,
   status='queued',claim_id=null,lease_until=null,next_attempt_at=started where id=j;
 end loop;
 raise exception 'historical_fixture_incomplete';
end $$;

savepoint old_download;
do $$
declare f jsonb; e jsonb; r jsonb; fresh jsonb; receipt uuid:=gen_random_uuid();
 old_month date; old_day date; current_month date:=date_trunc('month',clock_timestamp() at time zone 'UTC')::date;
 old_charge bigint; current_charge bigint; requests jsonb; snapshot jsonb; rev bigint;
begin
 -- A non-UTC session must not select the request day or monthly charge window.
 perform set_config('TimeZone','Pacific/Kiritimati',true);
 f:=test.original_accounting_history('2403.63001','original_download'); e:=f->'execution';
 old_month:=(e->>'charge_period')::date; old_day:=(e->>'request_day')::date;
 perform test.assert(old_month<>current_month and old_day<>old_month
  and old_day=((e->>'created_at')::timestamptz at time zone 'UTC')::date
  and old_month=date_trunc('month',(e->>'created_at')::timestamptz at time zone 'UTC')::date,
  'historical original retains distinct UTC request day and byte month');
 select charged into old_charge from app_private.acquisition_transfer_windows where period=old_month and scope='environment' and kind='source_bytes';
 select charged into current_charge from app_private.acquisition_transfer_windows where period=current_month and scope='environment' and kind='source_bytes';
 select jsonb_agg(to_jsonb(w) order by period,scope) into requests from app_private.acquisition_transfer_windows w where kind='source_requests';
 perform test.original_close(e,'executor');
 perform test.original_call('science_reader_original_executor',format('select public.worker_expire_original_stage_v1(%L,%L,%s,%L)',
  e->>'job_id',e->>'claim_id',e->>'generation',e->>'id'));
 select revision into rev from app_private.executor_authority;
 perform test.original_call('science_reader_executor_admitter',format('select public.worker_retire_metadata_executor(%s)',rev));
 perform test.assert(app_private.execution_pending((e->>'id')::uuid,'arxiv_connection')
  and (select charged=old_charge from app_private.acquisition_transfer_windows where period=old_month and scope='environment' and kind='source_bytes'),
  'logical expiry and authority retirement do not release the old source liability');
 r:=test.original_close(e,'arxiv_connection',true,receipt);
 perform test.assert((select charged=old_charge-(5242880-1000) from app_private.acquisition_transfer_windows where period=old_month and scope='environment' and kind='source_bytes')
  and (select charged=current_charge from app_private.acquisition_transfer_windows where period=current_month and scope='environment' and kind='source_bytes'),
  'late complete original body refunds only its captured old month');
 perform test.assert(requests=(select jsonb_agg(to_jsonb(w) order by period,scope) from app_private.acquisition_transfer_windows w where kind='source_requests'),
  'late original body never refunds historical or current daily requests');
 snapshot:=test.original_snapshot();
 perform test.original_close(e,'arxiv_connection',true,receipt);
 r:=test.original_close(e,'arxiv_connection',true,gen_random_uuid());
 perform test.assert(r->>'receipt_id'=receipt::text and snapshot=test.original_snapshot(),'late original receipt aliases return first ID without charge or backoff drift');
 perform test.original_enable();
 fresh:=test.original_job('2403.63002'); r:=test.original_grant(test.original_claim_args(fresh,'original_download'));
 perform test.assert(r->'granted'='true'::jsonb,'fresh original source grant after settled explicit activation'); e:=r->'execution';
 perform test.assert((e->>'request_day')::date=((e->>'created_at')::timestamptz at time zone 'UTC')::date
  and (e->>'charge_period')::date=date_trunc('month',(e->>'created_at')::timestamptz at time zone 'UTC')::date,
  'actual original grant uses UTC day and month under non-UTC session');
end $$;
rollback to old_download;

savepoint old_upload;
do $$
declare f jsonb; old jsonb; e jsonb; args jsonb; r jsonb; current_execution jsonb; snapshot jsonb;
 old_month date; this_month date:=date_trunc('month',clock_timestamp() at time zone 'UTC')::date;
 old_charge bigint; current_charge bigint; amount bigint; cap bigint; rev bigint; before_job jsonb; requests jsonb;
begin
 f:=test.original_job('2403.63003'); perform test.original_complete(f,'original_download');
 args:=test.original_claim_args(f,'original_upload');
 old:=test.original_accounting_history('2403.63004','original_upload'); e:=old->'execution';
 old_month:=(e->>'charge_period')::date; amount:=(e->>'byte_ceiling')::bigint;
 perform test.assert(old_month<>this_month and e->'request_day'='null'::jsonb,'historical upload is monthly-only');
 perform test.original_close(e,'executor');
 perform test.original_call('science_reader_original_executor',format('select public.worker_expire_original_stage_v1(%L,%L,%s,%L)',
  e->>'job_id',e->>'claim_id',e->>'generation',e->>'id'));
 perform test.assert((select status='blocked' from app_private.acquisition_jobs where id=(e->>'job_id')::uuid)
  and app_private.execution_pending((e->>'id')::uuid,'object_write')
  and (select held_bytes=5242880 from app_private.paper_asset_reservations where id=(old->>'reservation_id')::uuid),
  'expired old upload retains exact write hold and maximum storage reservation');
 select charged into old_charge from app_private.acquisition_transfer_windows where period=old_month and scope='environment' and kind='object_upload_bytes';
 select coalesce((select charged from app_private.acquisition_transfer_windows where period=this_month and scope='environment' and kind='object_upload_bytes'),0) into current_charge;
 cap:=current_charge+amount+1000;
 update app_private.acquisition_policy set source_download_bytes_month=cap-1;
 snapshot:=test.original_snapshot();
 perform test.reject(format('select test.original_grant(%L)',args),'original_transfer_limit');
 perform test.assert(snapshot=test.original_snapshot(),'old-month upload carry refuses one-byte-short new allowance without mutation');
 update app_private.acquisition_policy set source_download_bytes_month=cap;
 r:=test.original_grant(args); perform test.assert(r->'granted'='true'::jsonb,'old upload carry is counted exactly once at exact cap');
 current_execution:=r->'execution';
 perform test.original_close(current_execution,'executor'); perform test.original_close(current_execution,'object_write');
 perform test.original_call('science_reader_original_executor',test.original_finish_statement(current_execution));
 select jsonb_agg(to_jsonb(w) order by period,scope) into requests from app_private.acquisition_transfer_windows w where kind='source_requests';
 select to_jsonb(j) into before_job from app_private.acquisition_jobs j where id=(e->>'job_id')::uuid;
 select revision into rev from app_private.executor_authority;
 perform test.original_call('science_reader_executor_admitter',format('select public.worker_retire_metadata_executor(%s)',rev));
 perform test.assert(app_private.execution_pending((e->>'id')::uuid,'object_write')
  and (select charged=old_charge from app_private.acquisition_transfer_windows where period=old_month and scope='environment' and kind='object_upload_bytes'),
  'retirement cannot erase old-month upload carry');
 perform test.original_close(e,'object_write');
 perform test.assert((select charged=old_charge from app_private.acquisition_transfer_windows where period=old_month and scope='environment' and kind='object_upload_bytes')
  and (select charged=current_charge+1000 from app_private.acquisition_transfer_windows where period=this_month and scope='environment' and kind='object_upload_bytes'),
  'late exact upload acknowledgement refunds neither the old charge nor new month');
 perform test.assert(before_job=(select to_jsonb(j) from app_private.acquisition_jobs j where id=(e->>'job_id')::uuid)
  and (select held_bytes=5242880 from app_private.paper_asset_reservations where id=(old->>'reservation_id')::uuid),
  'late upload acknowledgement grants no result authority and releases no stored-byte reservation');
 perform test.assert(requests=(select jsonb_agg(to_jsonb(w) order by period,scope) from app_private.acquisition_transfer_windows w where kind='source_requests'),
  'upload settlement never creates or refunds a source request');
 perform test.original_reject_result(e,test.original_result(e),'operation_id_conflict');
end $$;
rollback to old_upload;

savepoint old_read;
do $$
declare f jsonb; old jsonb; e jsonb; args jsonb; r jsonb; fresh_e jsonb; snapshot jsonb;
 old_month date; this_month date:=date_trunc('month',clock_timestamp() at time zone 'UTC')::date;
 old_charge bigint; current_charge bigint; cap bigint; rev bigint; requests jsonb; old_job jsonb; receipt uuid:=gen_random_uuid();
begin
 f:=test.original_job('2403.63005'); perform test.original_complete(f,'original_download'); perform test.original_complete(f,'original_upload');
 args:=test.original_claim_args(f,'original_readback');
 old:=test.original_accounting_history('2403.63006','original_readback'); e:=old->'execution'; old_month:=(e->>'charge_period')::date;
 perform test.assert(old_month<>this_month and e->'request_day'='null'::jsonb,'historical object read is monthly-only');
 perform test.original_close(e,'executor');
 perform test.original_call('science_reader_original_executor',format('select public.worker_expire_original_stage_v1(%L,%L,%s,%L)',
  e->>'job_id',e->>'claim_id',e->>'generation',e->>'id'));
 select to_jsonb(j) into old_job from app_private.acquisition_jobs j where id=(e->>'job_id')::uuid;
 perform test.assert(old_job->>'status'='failed' and app_private.execution_pending((e->>'id')::uuid,'object_read'),
  'expired old read leaves its byte liability independently of terminal job state');
 select charged into old_charge from app_private.acquisition_transfer_windows where period=old_month and scope='environment' and kind='worker_bytes';
 select coalesce((select charged from app_private.acquisition_transfer_windows where period=this_month and scope='environment' and kind='worker_bytes'),0) into current_charge;
 cap:=current_charge+2*5242880;
 update app_private.acquisition_policy set worker_read_bytes_month=cap-1;
 snapshot:=test.original_snapshot();
 perform test.reject(format('select test.original_grant(%L)',args),'original_transfer_limit');
 perform test.assert(snapshot=test.original_snapshot(),'old read carry refuses one-byte-short allowance without consuming an attempt');
 update app_private.acquisition_policy set worker_read_bytes_month=cap;
 r:=test.original_grant(args); perform test.assert(r->'granted'='true'::jsonb,'old read carry is counted once at exact two-ceiling cap'); fresh_e:=r->'execution';
 perform test.original_close(fresh_e,'executor'); perform test.original_close(fresh_e,'object_read',false);
 perform test.original_call('science_reader_original_executor',format('select public.worker_fail_original_stage_v1(%L,%L,%s,%L,''download_failed'',true)',
  fresh_e->>'job_id',fresh_e->>'claim_id',fresh_e->>'generation',fresh_e->>'id'));
 perform test.assert((select charged=current_charge+5242880 from app_private.acquisition_transfer_windows where period=this_month and scope='environment' and kind='worker_bytes'),
  'unknown current body preserves its complete current-month ceiling');
 select jsonb_agg(to_jsonb(w) order by period,scope) into requests from app_private.acquisition_transfer_windows w where kind='source_requests';
 select revision into rev from app_private.executor_authority;
 perform test.original_call('science_reader_executor_admitter',format('select public.worker_retire_metadata_executor(%s)',rev));
 perform test.assert(app_private.execution_pending((e->>'id')::uuid,'object_read')
  and (select charged=old_charge from app_private.acquisition_transfer_windows where period=old_month and scope='environment' and kind='worker_bytes'),
  'authority retirement preserves old read hold and its full charge');
 r:=test.original_close(e,'object_read',true,receipt);
 perform test.assert((select charged=old_charge-(5242880-1000) from app_private.acquisition_transfer_windows where period=old_month and scope='environment' and kind='worker_bytes')
  and (select charged=current_charge+5242880 from app_private.acquisition_transfer_windows where period=this_month and scope='environment' and kind='worker_bytes'),
  'late complete stored read refunds the old period, never the current charge');
 perform test.assert(old_job=(select to_jsonb(j) from app_private.acquisition_jobs j where id=(e->>'job_id')::uuid)
  and (select held_bytes=5242880 from app_private.paper_asset_reservations where id=(old->>'reservation_id')::uuid)
  and requests=(select jsonb_agg(to_jsonb(w) order by period,scope) from app_private.acquisition_transfer_windows w where kind='source_requests'),
  'late read proof does not publish, shrink retained object bytes or alter daily requests');
 snapshot:=test.original_snapshot(); r:=test.original_close(e,'object_read',true,gen_random_uuid());
 perform test.assert(r->>'receipt_id'=receipt::text and snapshot=test.original_snapshot(),'replayed old read receipt has no second refund');
 perform test.original_enable();
 -- Mutable scheduling time only; immutable attempts/periods remain untouched.
 update app_private.acquisition_jobs set next_attempt_at='-infinity' where id=(f->>'original_job_id')::uuid;
 r:=test.original_grant(test.original_claim_args(f,'original_readback'));
 perform test.assert(r->'granted'='true'::jsonb
  and (select charged=cap from app_private.acquisition_transfer_windows where period=this_month and scope='environment' and kind='worker_bytes'),
  'settled old read no longer carries forward; current unknown ceiling plus one retry exactly fills cap');
end $$;
rollback to old_read;

-- Drop the test-only historical constructor and every case's data. The caller
-- continues with its enabled fixture and unchanged production/helper schema.
rollback to original_accounting;
