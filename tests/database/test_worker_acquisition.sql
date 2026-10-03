-- Local fixture-only acquisition contract. No network, storage or PDF parser
-- executes here: successful attestation fixtures test SQL authority, not qpdf.
begin;
grant usage on schema test to science_reader_pdf_verifier;
grant execute on all functions in schema test to science_reader_pdf_verifier;
select test.assert(not exists(select 1 from pg_tables where schemaname='app_private' and not rowsecurity),'011 private RLS');
select test.assert(not has_function_privilege('service_role','public.worker_claim_original_verification(uuid,uuid)','execute'),'acquisition cannot attest');
select test.assert(not has_function_privilege('service_role','public.worker_begin_arxiv_request(uuid,uuid,bigint,text)','execute'),'split source permit retired');
select test.assert(not has_function_privilege('service_role','public.worker_mark_original_uploading(uuid,uuid,bigint)','execute'),'split upload authority retired');
select test.assert(not has_function_privilege('authenticated','public.worker_original_reservation(uuid)','execute'),'customer cannot fetch storage path');
select test.assert(not has_function_privilege('anon','public.worker_original_reservation(uuid)','execute'),'public cannot fetch storage path');
select test.assert(not has_function_privilege('science_reader_pdf_verifier','public.worker_publish_original(uuid,uuid,bigint,uuid)','execute'),'verifier cannot publish');
select test.assert((select not metadata_enabled and not original_enabled and not verification_enabled and active_verification_profile is null from app_private.acquisition_policy),'outbound and profile disabled by default');
set local role service_role;
select test.reject($q$select public.worker_claim_original_verification(gen_random_uuid(),gen_random_uuid())$q$,'permission denied');
reset role;

-- Fixture helper follows each persisted metadata boundary. Mock closure facts
-- are local test data; the application may never manufacture those in service.
create function test.acq_lookup(src text,a uuid,i uuid,j uuid,eligible boolean) returns jsonb language plpgsql as $$
declare c uuid; v jsonb; token uuid; seq bigint; result jsonb; attempt integer;
begin
 perform set_config('request.jwt.claim.sub',a::text,true);
 result:=public.v2_begin_import(i,src,(select last_seq from app_private.library_sync_state where account_id=a),1);
 perform public.worker_prepare_acquisition(j,src,1);
 perform public.worker_link_import_acquisition(a,i,1,(result->'entry'->>'state_seq')::bigint,j);
 perform test.assert(public.worker_claim_acquisition(j,gen_random_uuid())->>'action'='source_claim_required','ordinary claim cannot allocate source work');
 c:=gen_random_uuid();
 update app_private.arxiv_network_gate set next_allowed_at='-infinity' where singleton;
 v:=public.worker_claim_arxiv_stage(j,c,'staging'); token:=(v->>'token')::uuid;
 perform test.assert((v->>'granted')::boolean,'lookup claim granted');
 perform test.assert((v->>'granted')::boolean,'single gateway request grant');
 perform test.assert(not (public.worker_claim_arxiv_stage(j,c,'staging')->>'granted')::boolean,'gateway permit replay never authorizes fetch');
 perform public.worker_finish_arxiv_request(token,100,0);
 perform test.assert((select next_allowed_at>=clock_timestamp()+interval '2 seconds' from app_private.arxiv_network_gate),'closure plus three-second cooldown');
 perform test.reject(format('select public.worker_finish_arxiv_request(%L,100,1)',token),'operation_id_conflict');
 result:=jsonb_build_object('revision',1,'metadata',jsonb_build_object('title','Synthetic acquisition','authors',jsonb_build_array('Test Author'),
  'categories',jsonb_build_array('cs.LG'),'published_at','2024-03-01','updated_at','2024-03-02'),
  'atom_published_at','2024-03-01T09:01:02.000Z','atom_updated_at','2024-03-02T10:02:03.000Z');
 v:=public.worker_finish_lookup(j,c,1,result);
 perform test.assert(public.worker_finish_lookup(j,c,1,result)=v,'lost lookup acknowledgement replay');
 perform test.assert(public.worker_claim_arxiv_stage(j,c,'staging')->>'action'='reconcile','source grant replay after stage advancement stays non-authorizing');
 perform test.reject(format('select public.worker_claim_arxiv_stage(%L,%L,%L)',j,c,'production'),'operation_id_conflict');
 perform test.reject(format('select public.worker_claim_arxiv_stage(%L,%L,%L,%L)',j,c,'staging',gen_random_uuid()),'operation_id_conflict');
 perform test.assert((public.worker_acquisition_state(j)->'job'->>'atom_updated_at')='2024-03-02T10:02:03.000Z','full Atom timestamp retained');
 perform test.assert((public.worker_acquisition_state(j)->'job'->'metadata'->>'updated_at')='2024-03-02','catalog uses date DTO');
 perform public.worker_project_import_acquisition(a,i,1);
 c:=gen_random_uuid();
 update app_private.arxiv_network_gate set next_allowed_at='-infinity' where singleton;
 v:=public.worker_claim_arxiv_stage(j,c,'staging'); token:=(v->>'token')::uuid;
 perform public.worker_finish_arxiv_request(token,100,0);
 if eligible is null then
  perform public.worker_fail_acquisition(j,c,2,'metadata_unavailable',true);
  for attempt in 3..4 loop
   update app_private.acquisition_jobs set next_attempt_at=clock_timestamp()-interval '1 second' where id=j;
   c:=gen_random_uuid();
   update app_private.arxiv_network_gate set next_allowed_at='-infinity' where singleton;
   v:=public.worker_claim_arxiv_stage(j,c,'staging');
   perform public.worker_finish_arxiv_request((v->>'token')::uuid,100,0);
   perform public.worker_fail_acquisition(j,c,attempt,'metadata_unavailable',true);
  end loop;
  return public.worker_project_import_acquisition(a,i,1);
 end if;
 if eligible then
  result:=jsonb_build_object('eligible',true,'license_uri','https://creativecommons.org/licenses/by/4.0/',
   'evidence',jsonb_build_object('source_id',src,'source_revision',1,'source_url','https://arxiv.org/abs/'||src||'v1',
    'license_uri','https://creativecommons.org/licenses/by/4.0/','evidence_format','arXivRaw','evidence_sha256',repeat('a',64),
    'observed_at','2026-10-03T01:00:00Z','latest_version_at','2024-03-02T10:02:03.000Z'));
 else result:='{"eligible":false,"reason":"license_not_supported"}'; end if;
 perform public.worker_finish_lookup(j,c,2,result);
 return public.worker_project_import_acquisition(a,i,1);
end $$;
create function test.acq_uploaded(src text,a uuid,hash bytea) returns jsonb language plpgsql as $$
declare i uuid:=gen_random_uuid(); l uuid:=gen_random_uuid(); o uuid:=gen_random_uuid(); r uuid:=gen_random_uuid(); c uuid; v jsonb;
begin
 perform test.acq_lookup(src,a,i,l,true);
 v:=public.worker_prepare_original(o,l);
 perform public.worker_link_import_acquisition(a,i,1,(public.worker_import_state(a,i)->'entry'->>'state_seq')::bigint,l,o);
 c:=gen_random_uuid(); v:=public.worker_claim_acquisition(o,c);
 perform public.worker_reserve_original(o,c,1,r);
 c:=gen_random_uuid();
 update app_private.arxiv_network_gate set next_allowed_at='-infinity' where singleton;
 v:=public.worker_claim_arxiv_stage(o,c,'staging',r);
 perform public.worker_finish_arxiv_request((v->>'token')::uuid,1000,0);
 perform public.worker_record_original_upload(r,c,2,hash,1000,false);
 return jsonb_build_object('account',a,'import',i,'lookup',l,'original',o,'reservation',r);
end $$;
-- Fixture identity is deliberately unrelated to the real, unadmitted qpdf build.
insert into app_private.paper_verification_profiles(id,profile_sha256,definition,canonical_profile,build_sha256,max_bytes,max_pages,wasm_memory_bytes,host_memory_bytes,cpu_ms,wall_ms,verifier_identity)
 values('b1100000-0000-0000-0000-000000000001',sha256(convert_to('{"fixture":true}','UTF8')),'{"fixture":true}','{"fixture":true}',decode(repeat('f1',32),'hex'),5242880,50,67108864,268435456,2000,120000,'local-contract-fixture');
insert into auth.users values('b1100000-0000-0000-0000-000000000010'),('b1100000-0000-0000-0000-000000000011');
update app_private.acquisition_policy set metadata_enabled=true where singleton;
select test.acq_lookup('2403.10001','b1100000-0000-0000-0000-000000000010','b1100000-0000-0000-0000-000000000020','b1100000-0000-0000-0000-000000000030',false);
select test.assert((select phase='source_only' and metadata_id is not null from app_private.import_requests where id='b1100000-0000-0000-0000-000000000020'),'source-only complete with original/profile disabled');
select test.assert(not exists(select 1 from app_private.paper_asset_reservations),'source-only never reserves original');
select test.assert(not exists(select 1 from app_private.metered_operations where account_id='b1100000-0000-0000-0000-000000000010'),'metadata has no paid reservation');
update app_private.acquisition_source_slots set fresh_until=clock_timestamp()-interval '1 second';
select test.assert((public.worker_prepare_acquisition('b1100000-0000-0000-0000-000000000030','2403.10001',1)->'job'->>'id')='b1100000-0000-0000-0000-000000000030','prepare replay bound after freshness expiration');
select test.reject($q$select public.worker_prepare_acquisition('b1100000-0000-0000-0000-000000000030','2403.10002',1)$q$,'operation_id_conflict');

update app_private.acquisition_policy set original_enabled=true,verification_enabled=true,active_verification_profile='b1100000-0000-0000-0000-000000000001';
select test.acq_uploaded('2403.10002','b1100000-0000-0000-0000-000000000010',decode(repeat('b1',32),'hex')) as fixture \gset
select :'fixture'::jsonb->>'reservation' as reservation, :'fixture'::jsonb->>'original' as original, :'fixture'::jsonb->>'lookup' as lookup, :'fixture'::jsonb->>'import' as import \gset
select gen_random_uuid() as verifier_claim,gen_random_uuid() as verifier_op \gset
set local role science_reader_pdf_verifier;
select test.assert((public.worker_claim_original_verification(:'reservation',:'verifier_claim')->>'granted')::boolean,'narrow verifier can claim');
select test.reject(format($q$select public.worker_record_original_verification(%L,%L,1,%L,'b1100000-0000-0000-0000-000000000001',decode(repeat('f2',32),'hex'),'verified',decode(repeat('b1',32),'hex'),1000,2,'{"cpu_ms":1,"wall_ms":2,"peak_host_bytes":100000000,"wasm_bytes":67108864,"warnings":0,"repaired":false}')$q$,:'reservation',:'verifier_claim',:'verifier_op'),'stale_verification_claim');
select public.worker_record_original_verification(:'reservation',:'verifier_claim',1,:'verifier_op','b1100000-0000-0000-0000-000000000001',decode(repeat('f1',32),'hex'),'verified',decode(repeat('b1',32),'hex'),1000,2,'{"cpu_ms":1,"wall_ms":2,"peak_host_bytes":100000000,"wasm_bytes":67108864,"warnings":0,"repaired":false}');
select test.assert((public.worker_record_original_verification(:'reservation',:'verifier_claim',1,:'verifier_op','b1100000-0000-0000-0000-000000000001',decode(repeat('f1',32),'hex'),'verified',decode(repeat('b1',32),'hex'),1000,2,'{"cpu_ms":1,"wall_ms":2,"peak_host_bytes":100000000,"wasm_bytes":67108864,"warnings":0,"repaired":false}')->>'replayed')::boolean,'verification receipt replay');
reset role;
select gen_random_uuid() as publish_claim \gset
select public.worker_claim_acquisition(:'original',:'publish_claim');
select public.worker_publish_original(:'original',:'publish_claim',3,:'reservation') as published \gset
select public.worker_publish_original(:'original',:'publish_claim',3,:'reservation');
select public.worker_bind_lookup_original(:'lookup',:'original');
select public.worker_project_import_acquisition('b1100000-0000-0000-0000-000000000010',:'import',1);
select :'published'::jsonb->>'document_id' as document, :'published'::jsonb->>'original_object_id' as object \gset
select id as item,state_seq as prior_seq from app_private.library_items where account_id='b1100000-0000-0000-0000-000000000010' and document_id=:'document' \gset
select test.assert((app_private.library_item_entry('b1100000-0000-0000-0000-000000000010',:'item')->>'readiness')='pdf_ready','verified original capability');
select test.assert(public.worker_project_library_availability('b1100000-0000-0000-0000-000000000010',:'item')->>'state_seq'=:'prior_seq','same projection does not emit another sequence');
select set_config('request.jwt.claim.sub','b1100000-0000-0000-0000-000000000010',true);
set local role authenticated;
select test.assert(not (public.v2_original_descriptor(:'item') ? 'path'),'descriptor hides bucket path');
reset role;
update app_private.paper_read_policy set enabled=true;
select gen_random_uuid() as read_op \gset
select test.assert((public.worker_authorize_original_read('b1100000-0000-0000-0000-000000000010',:'item',:'read_op',(clock_timestamp() at time zone 'UTC')::date,0,99)->>'byte_ceiling')::int=100,'read reserves exact bounded range');
select test.assert(not (public.worker_authorize_original_read('b1100000-0000-0000-0000-000000000010',:'item',:'read_op',(clock_timestamp() at time zone 'UTC')::date,0,99)->>'granted')::boolean,'read replay never grants a second transfer');
select test.reject(format('select public.worker_authorize_original_read(%L,%L,gen_random_uuid(),current_date-2)','b1100000-0000-0000-0000-000000000010',:'item'),'original_read_day_expired');
select test.reject(format('select public.worker_authorize_original_read(%L,%L,gen_random_uuid(),current_date,0,1000)','b1100000-0000-0000-0000-000000000010',:'item'),'invalid_original_range');
select revision as asset_revision from app_private.paper_asset_availability where object_id=:'object' \gset
select public.worker_set_original_availability(gen_random_uuid(),:'object',:asset_revision,'unavailable','missing');
select test.assert((app_private.library_item_entry('b1100000-0000-0000-0000-000000000010',:'item')->>'state_seq')=:'prior_seq','global transition does not mutate unchanged item payload');
select test.assert((app_private.library_item_entry('b1100000-0000-0000-0000-000000000010',:'item')->>'original_availability')='available','stored projection remains consistent at old sequence');
select test.reject(format('select public.v2_original_descriptor(%L)',:'item'),'original_unavailable');
select public.worker_project_library_availability('b1100000-0000-0000-0000-000000000010',:'item');
select test.assert((app_private.library_item_entry('b1100000-0000-0000-0000-000000000010',:'item')->>'state_seq')::bigint>:prior_seq,'availability emits committed item change');
select test.assert((app_private.library_item_entry('b1100000-0000-0000-0000-000000000010',:'item')->>'readiness')='unavailable','unavailable approved original has compatible wire readiness');
select public.v2_set_library_item(gen_random_uuid(),:'document',false,1);
select state_seq as removed_seq from app_private.library_items where id=:'item' \gset
select revision as asset_revision from app_private.paper_asset_availability where object_id=:'object' \gset
select public.worker_set_original_availability(gen_random_uuid(),:'object',:asset_revision,'available',null,decode(repeat('b1',32),'hex'),1000);
select public.worker_project_library_availability('b1100000-0000-0000-0000-000000000010',:'item');
select test.assert((select removed_at is not null and state_seq>:removed_seq and membership_revision=2 from app_private.library_items where id=:'item'),'tombstone availability updates preserve intent and removal');
select test.reject(format('select public.v2_original_descriptor(%L)',:'item'),'original_unavailable');
select gen_random_uuid() as fanout_claim \gset
select public.worker_claim_asset_projection(:'document',:'fanout_claim');
select public.worker_ack_asset_projection(:'document',:'fanout_claim',1,'b1100000-0000-0000-0000-000000000010',:'item');
select test.assert((public.worker_ack_asset_projection(:'document',:'fanout_claim',1)->>'complete')::boolean,'fanout completes after committed tombstone projection');
select test.assert(public.worker_claim_original_orphans()='[]'::jsonb,'published original never orphan collected');

-- Storage-integrity mismatch quarantines, without a positive structural result.
select test.acq_uploaded('2403.10003','b1100000-0000-0000-0000-000000000011',decode(repeat('b2',32),'hex')) as badfixture \gset
select :'badfixture'::jsonb->>'reservation' as badreservation \gset
select gen_random_uuid() as badclaim,gen_random_uuid() as badop \gset
set local role science_reader_pdf_verifier;
select public.worker_claim_original_verification(:'badreservation',:'badclaim');
select test.reject(format($q$select public.worker_record_original_integrity_failure(%L,%L,1,%L,'b1100000-0000-0000-0000-000000000001',decode(repeat('f1',32),'hex'),decode(repeat('b2',32),'hex'),1000,'binding_mismatch',false,null,1000)$q$,:'badreservation',:'badclaim',:'badop'),'invalid_integrity_result');
select public.worker_record_original_integrity_failure(:'badreservation',:'badclaim',1,:'badop','b1100000-0000-0000-0000-000000000001',decode(repeat('f1',32),'hex'),decode(repeat('b2',32),'hex'),1000,'binding_mismatch',true,decode(repeat('b3',32),'hex'),1000);
select test.assert((public.worker_original_verification_state(:'badreservation',:'badop')->'integrity_failure'->>'outcome')='binding_mismatch','truthful integrity evidence survives lost ack');
reset role;
select test.assert((select state='quarantined' and verification_result_id is null from app_private.paper_asset_reservations where id=:'badreservation'),'bad storage never structural success');
select test.assert(public.worker_claim_original_orphans()='[]'::jsonb,'janitor waits beyond possible old writer');
update app_private.paper_asset_reservations set safe_after=clock_timestamp()-interval '1 second' where id=:'badreservation';
select public.worker_claim_original_orphans() as orphans \gset
select :'orphans'::jsonb->0->>'deletion_operation_id' as delete_op \gset
select test.reject(format('select public.worker_confirm_original_deleted(%L,%L,1,false)',:'badreservation',:'delete_op'),'storage_absence_required');
select public.worker_confirm_original_deleted(:'badreservation',:'delete_op',1,true);
select test.assert((select held_bytes=0 and state='deleted' from app_private.paper_asset_reservations where id=:'badreservation'),'capacity released only after storage absence');

-- Cancellation before a source permit prevents new traffic, independent of
-- durable metadata job completion or another previously captured intent.
do $$ declare a uuid:='b1100000-0000-0000-0000-000000000011'; i uuid:=gen_random_uuid(); j uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); r jsonb;
begin
 perform set_config('request.jwt.claim.sub',a::text,true);
 r:=public.v2_begin_import(i,'2403.10004',(select last_seq from app_private.library_sync_state where account_id=a),1);
 perform public.worker_prepare_acquisition(j,'2403.10004',1);
 perform public.worker_link_import_acquisition(a,i,1,(r->'entry'->>'state_seq')::bigint,j);
 perform public.v2_cancel_import(gen_random_uuid(),i,1);
 update app_private.arxiv_network_gate set next_allowed_at='-infinity';
 perform test.assert(public.worker_claim_arxiv_stage(j,c,'staging')->>'action'='no_interest','cancel before permit denies traffic');
 perform public.worker_project_import_acquisition(a,i,1);
 perform test.assert((select retired from app_private.acquisition_interests where account_id=a and import_id=i),'cancel retires only its interest');
end $$;
-- Headroom failure is terminal rather than an endless rollback loop.
do $$ declare a uuid:='b1100000-0000-0000-0000-000000000011'; i uuid:=gen_random_uuid(); j uuid:=gen_random_uuid(); r jsonb;
begin
 perform set_config('request.jwt.claim.sub',a::text,true);
 r:=public.v2_begin_import(i,'2403.10005',(select last_seq from app_private.library_sync_state where account_id=a),1);
 perform public.worker_prepare_acquisition(j,'2403.10005',1);
 perform public.worker_link_import_acquisition(a,i,1,(r->'entry'->>'state_seq')::bigint,j);
 update app_private.acquisition_jobs set slots_held=1 where id=j;
 update app_private.arxiv_network_gate set next_allowed_at='-infinity';
 perform test.assert(public.worker_claim_arxiv_stage(j,gen_random_uuid(),'staging')->>'action'='terminal','control exhaustion commits terminal state');
 perform test.assert((select status='failed' and error_code='capacity_exhausted' from app_private.acquisition_jobs where id=j),'terminal failure persisted');
end $$;

-- Transient read failure stays in verification and never invents a PDF result
-- or blindly downloads again into the already bound no-overwrite object path.
select test.acq_uploaded('2403.10006','b1100000-0000-0000-0000-000000000011',decode(repeat('b6',32),'hex')) as transientfixture \gset
select :'transientfixture'::jsonb->>'reservation' as transientreservation,:'transientfixture'::jsonb->>'original' as transientjob \gset
select gen_random_uuid() as transientclaim \gset
set local role science_reader_pdf_verifier;
select public.worker_claim_original_verification(:'transientreservation',:'transientclaim');
select public.worker_verification_input_unavailable(:'transientreservation',:'transientclaim',1);
reset role;
select test.assert(not exists(select 1 from app_private.paper_verification_results where reservation_id=:'transientreservation'),'transient read has no structural verdict');
select test.assert((select stage='pending_verification' and status='retry_wait' from app_private.acquisition_jobs where id=:'transientjob'),'retry stays at verification boundary');
update app_private.acquisition_jobs set next_attempt_at=clock_timestamp()-interval '1 second' where id=:'transientjob';
select gen_random_uuid() as timeoutclaim,gen_random_uuid() as timeoutop \gset
set local role science_reader_pdf_verifier;
select public.worker_claim_original_verification(:'transientreservation',:'timeoutclaim');
reset role;
update app_private.paper_asset_reservations set verification_execution_deadline=clock_timestamp()-interval '1 second' where id=:'transientreservation';
set local role science_reader_pdf_verifier;
select public.worker_record_original_verification(:'transientreservation',:'timeoutclaim',2,:'timeoutop','b1100000-0000-0000-0000-000000000001',decode(repeat('f1',32),'hex'),'time_limit',decode(repeat('b6',32),'hex'),1000,null,'{}');
select test.assert(public.worker_claim_original_verification(:'transientreservation',gen_random_uuid())->>'action'='terminal','reported hard timeout never automatically reruns same candidate');
reset role;
select test.assert((select status='failed' and not retryable from app_private.acquisition_jobs where id=:'transientjob'),'timeout terminal negative outcome');

-- Expiring a pending candidate retires its unfinished job. A later legitimate
-- import can allocate new work rather than attach forever to a deleted file.
select test.acq_uploaded('2403.10007','b1100000-0000-0000-0000-000000000011',decode(repeat('b7',32),'hex')) as expiredfixture \gset
select :'expiredfixture'::jsonb->>'reservation' as expiredreservation,:'expiredfixture'::jsonb->>'original' as expiredjob,:'expiredfixture'::jsonb->>'lookup' as expiredlookup \gset
update app_private.paper_asset_reservations set expires_at=clock_timestamp()-interval '1 second',safe_after=clock_timestamp()-interval '1 second' where id=:'expiredreservation';
select public.worker_claim_original_orphans();
select test.assert((select status='failed' and retryable from app_private.acquisition_jobs where id=:'expiredjob'),'expired pending candidate terminalizes owning job');
select test.assert(public.worker_prepare_original(gen_random_uuid(),:'expiredlookup')->'job'->>'id'<>:'expiredjob','future interest gets fresh original job');

-- A closed subscriber remains a safe projection recipient. It cannot block
-- later active subscribers or cause the fanout cursor to spin forever.
select set_config('request.jwt.claim.sub','b1100000-0000-0000-0000-000000000011',true);
select public.v2_set_library_item(gen_random_uuid(),:'document',true,0,(:'published'::jsonb->>'approval_id')::uuid);
select id as active_subscriber_item from app_private.library_items where account_id='b1100000-0000-0000-0000-000000000011' and document_id=:'document' \gset
update app_private.accounts set closed_at=clock_timestamp() where id='b1100000-0000-0000-0000-000000000010';
select revision as asset_revision from app_private.paper_asset_availability where object_id=:'object' \gset
select public.worker_set_original_availability(gen_random_uuid(),:'object',:asset_revision,'unavailable','temporarily_unavailable');
select public.worker_project_library_availability('b1100000-0000-0000-0000-000000000010',:'item');
select test.assert((app_private.library_item_entry('b1100000-0000-0000-0000-000000000010',:'item')->>'original_availability')='unavailable','closed-account projection advances');
select gen_random_uuid() as closed_fanout \gset
select public.worker_claim_asset_projection(:'document',:'closed_fanout');
select public.worker_ack_asset_projection(:'document',:'closed_fanout',1,'b1100000-0000-0000-0000-000000000010',:'item');
select public.worker_project_library_availability('b1100000-0000-0000-0000-000000000011',:'active_subscriber_item');
select public.worker_ack_asset_projection(:'document',:'closed_fanout',1,'b1100000-0000-0000-0000-000000000011',:'active_subscriber_item');
select test.assert((public.worker_ack_asset_projection(:'document',:'closed_fanout',1)->>'complete')::boolean,'closed subscriber does not strand later live recipient/outbox');
update app_private.accounts set closed_at=null where id='b1100000-0000-0000-0000-000000000010';

-- Operational availability is revision-CAS, not an unbounded command log.
select gen_random_uuid() as obs_a,gen_random_uuid() as obs_b \gset
select revision as obs_revision from app_private.paper_asset_availability where object_id=:'object' \gset
select public.worker_set_original_availability(:'obs_a',:'object',:obs_revision,'unavailable','temporarily_unavailable');
select revision as obs_revision_b from app_private.paper_asset_availability where object_id=:'object' \gset
select test.assert(:obs_revision_b>:obs_revision,'unchanged observation still advances CAS revision');
select public.worker_set_original_availability(:'obs_b',:'object',:obs_revision_b,'unavailable','temporarily_unavailable');
select test.assert(public.worker_set_original_availability(:'obs_a',:'object',:obs_revision,'unavailable','missing')->>'status'='revision_conflict','old observation cannot mutate after intervening no-op');

-- Background reconciliation keeps twenty percent of each request window for
-- foreground commands. It consumes no request for an unchanged/deferred row.
do $$ declare a uuid:='b1100000-0000-0000-0000-000000000011'; i uuid:=gen_random_uuid(); j uuid:=gen_random_uuid(); r jsonb; w timestamptz;
begin
 perform set_config('request.jwt.claim.sub',a::text,true);
 r:=public.v2_begin_import(i,'2403.10008',(select last_seq from app_private.library_sync_state where account_id=a),1);
 perform public.worker_prepare_acquisition(j,'2403.10008',1);
 perform public.worker_link_import_acquisition(a,i,1,(r->'entry'->>'state_seq')::bigint,j);
 update app_private.api_rate_rules set account_limit=10,environment_limit=20 where route='library-write';
 w:=to_timestamp(floor(extract(epoch from now())/3600)*3600);
 update app_private.api_rate_windows set used=case when scope_id='environment' then 16 else 8 end
  where route='library-write' and window_start=w and scope_id in ('environment',a::text);
 perform test.assert((public.worker_project_import_acquisition(a,i,1)->>'projection_deferred')::boolean,'background defers before foreground headroom');
 perform test.assert(public.v2_cancel_import(gen_random_uuid(),i,1)->'entry'->>'phase'='cancelled','cancellation succeeds at background cutoff');
 update app_private.api_rate_rules set account_limit=1000,environment_limit=10000 where route='library-write';
end $$;

-- Control byte/row bounds fail before making unjournaled jobs or receipts.
do $$ declare before_jobs bigint; before_commands bigint; prior bigint;
begin
 select count(*) into before_jobs from app_private.acquisition_jobs;
 select count(*) into before_commands from app_private.acquisition_commands;
 select control_bytes into prior from app_private.acquisition_policy;
 update app_private.acquisition_policy set control_bytes=8192;
 perform test.reject($q$select public.worker_prepare_acquisition(gen_random_uuid(),'2403.10009',1)$q$,'acquisition_control_capacity');
 perform test.assert((select count(*) from app_private.acquisition_jobs)=before_jobs and (select count(*) from app_private.acquisition_commands)=before_commands,'capacity rejection leaves no job/receipt');
 update app_private.acquisition_policy set control_bytes=prior;
end $$;

-- A failed license stage retries its pinned metadata observation, not an
-- incompatible fresh catalog row for the same arXiv version.
select gen_random_uuid() as retryimport,gen_random_uuid() as retrylookup,gen_random_uuid() as retryop \gset
select test.acq_lookup('2403.10010','b1100000-0000-0000-0000-000000000011',:'retryimport',:'retrylookup',null);
select test.assert((select status='failed' and retryable and metadata_id is not null from app_private.acquisition_jobs where id=:'retrylookup'),'bounded license attempts end with pinned retryable failure');
select public.worker_retry_lookup(:'retryop',:'retrylookup') as retried \gset
select test.assert(:'retried'::jsonb->'job'->>'stage'='license','pinned retry resumes license stage');
select test.assert(:'retried'::jsonb->'job'->>'metadata_id'=(select metadata_id::text from app_private.acquisition_jobs where id=:'retrylookup'),'metadata pin survives retry generation');
select test.assert((select active_job_id is distinct from :'retryop'::uuid from app_private.acquisition_source_slots where source_id='2403.10010'),'pinned retry never becomes latest source-cache answer');
select set_config('request.jwt.claim.sub','b1100000-0000-0000-0000-000000000011',true);
select public.v2_retry_import(gen_random_uuid(),:'retryimport',1);
select public.worker_link_import_acquisition('b1100000-0000-0000-0000-000000000011',:'retryimport',2,
 (public.worker_import_state('b1100000-0000-0000-0000-000000000011',:'retryimport')->'entry'->>'state_seq')::bigint,:'retryop');
update app_private.arxiv_network_gate set next_allowed_at='-infinity';
select public.worker_claim_arxiv_stage(:'retryop',gen_random_uuid(),'staging') as retrygrant \gset
select test.assert((:'retrygrant'::jsonb->>'granted')::boolean,'current retried interest claims pinned observation');
select public.worker_finish_arxiv_request((:'retrygrant'::jsonb->>'token')::uuid,100,0);

-- Legacy original adoption is explicitly unsupported. Verifying a new path
-- cannot attest an existing immutable approval's old path for equal bytes.
select test.acq_uploaded('2403.10011','b1100000-0000-0000-0000-000000000010',decode(repeat('c7',32),'hex')) as legacyfixture \gset
select :'legacyfixture'::jsonb->>'reservation' as legacyreservation,:'legacyfixture'::jsonb->>'original' as legacyjob,:'legacyfixture'::jsonb->>'lookup' as legacylookup,:'legacyfixture'::jsonb->>'import' as legacyimport \gset
select gen_random_uuid() as legacydocument,gen_random_uuid() as legacyobject,gen_random_uuid() as legacyapproval \gset
insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count) values(:'legacydocument',decode(repeat('c7',32),'hex'),'shared_catalog','{"fixture":true}',1000,2);
insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
 values(:'legacyobject','paper-assets','legacy/'||:'legacyobject'||'.pdf',:'legacydocument','verified',decode(repeat('c7',32),'hex'),1000,'application/pdf',now());
select public.worker_approve_arxiv_asset(:'legacyapproval',metadata_id,:'legacydocument',:'legacyobject',license_uri,evidence) from app_private.acquisition_jobs where id=:'legacylookup';
select gen_random_uuid() as legacyverify,gen_random_uuid() as legacyresult \gset
set local role science_reader_pdf_verifier;
select public.worker_claim_original_verification(:'legacyreservation',:'legacyverify');
select public.worker_record_original_verification(:'legacyreservation',:'legacyverify',1,:'legacyresult','b1100000-0000-0000-0000-000000000001',decode(repeat('f1',32),'hex'),'verified',decode(repeat('c7',32),'hex'),1000,2,'{"cpu_ms":1,"wall_ms":2,"peak_host_bytes":100000000,"wasm_bytes":67108864,"warnings":0,"repaired":false}');
reset role;
select gen_random_uuid() as legacypublish \gset
select public.worker_claim_acquisition(:'legacyjob',:'legacypublish');
select test.assert(public.worker_publish_original(:'legacyjob',:'legacypublish',3,:'legacyreservation')->>'error_code'='legacy_original_unverified','pin conflict is typed permanent publication outcome');
select test.assert((select original_object_id=:'legacyobject'::uuid from app_private.catalog_asset_approvals where id=:'legacyapproval'),'legacy pin not replaced');
select test.assert(not exists(select 1 from app_private.paper_originals where document_id=:'legacydocument'),'no fabricated canonical original after legacy conflict');
select test.assert((select count(*)=1 from app_private.stored_objects where document_id=:'legacydocument'),'no publication side-effect objects after legacy conflict');
select public.worker_project_import_acquisition('b1100000-0000-0000-0000-000000000010',:'legacyimport',1);
select test.assert((select phase='failed' and not retryable from app_private.import_requests where id=:'legacyimport'),'legacy adoption does not spin retry loop');
update app_private.paper_asset_reservations set safe_after=clock_timestamp()-interval '1 second' where id in (:'legacyreservation',:'transientreservation');
select public.worker_claim_original_orphans();
select test.assert((select error_code='verification_failed' and not retryable from app_private.acquisition_jobs where id=:'transientjob'),'cleanup preserves permanent verifier failure');
select test.assert((select error_code='legacy_original_unverified' and not retryable from app_private.acquisition_jobs where id=:'legacyjob'),'cleanup preserves permanent legacy-adoption outcome');

-- Different source versions with identical verified bytes converge on one
-- canonical original; the losing upload remains a counted unpublished orphan.
select revision as duplicate_asset_revision from app_private.paper_asset_availability where object_id=:'object' \gset
select public.worker_set_original_availability(gen_random_uuid(),:'object',:duplicate_asset_revision,'available',null,decode(repeat('b1',32),'hex'),1000);
select test.acq_uploaded('2403.10012','b1100000-0000-0000-0000-000000000010',decode(repeat('b1',32),'hex')) as duplicatefixture \gset
select :'duplicatefixture'::jsonb->>'reservation' as duplicatereservation,:'duplicatefixture'::jsonb->>'original' as duplicatejob,:'duplicatefixture'::jsonb->>'lookup' as duplicatelookup \gset
select gen_random_uuid() as duplicatedverify,gen_random_uuid() as duplicatedresult \gset
set local role science_reader_pdf_verifier;
select public.worker_claim_original_verification(:'duplicatereservation',:'duplicatedverify');
select public.worker_record_original_verification(:'duplicatereservation',:'duplicatedverify',1,:'duplicatedresult','b1100000-0000-0000-0000-000000000001',decode(repeat('f1',32),'hex'),'verified',decode(repeat('b1',32),'hex'),1000,2,'{"cpu_ms":1,"wall_ms":2,"peak_host_bytes":100000000,"wasm_bytes":67108864,"warnings":0,"repaired":false}');
reset role;
select gen_random_uuid() as duplicatepublish \gset
select public.worker_claim_acquisition(:'duplicatejob',:'duplicatepublish');
select test.assert(public.worker_publish_original(:'duplicatejob',:'duplicatepublish',3,:'duplicatereservation')->>'original_object_id'=:'object','exact bytes reuse existing canonical original');
select test.assert((select count(*)=1 from app_private.paper_originals where document_id=:'document'),'canonical exact-byte original unique');
select test.assert((select state='quarantined' and original_object_id is null and held_bytes=1000 from app_private.paper_asset_reservations where id=:'duplicatereservation'),'duplicate upload remains counted until deletion');
update app_private.paper_asset_reservations set safe_after=clock_timestamp()-interval '1 second' where id=:'duplicatereservation';
select public.worker_claim_original_orphans();
select test.assert((select status='complete' and original_object_id=:'object'::uuid from app_private.acquisition_jobs where id=:'duplicatejob'),'duplicate orphan cleanup preserves successful canonical reuse');

-- Resource modes distinguish observed usage from enforced limits. Fixtures
-- assert the contract only; no hosted configuration has been admitted.
insert into app_private.paper_verification_profiles(id,profile_sha256,definition,canonical_profile,build_sha256,max_bytes,max_pages,wasm_memory_bytes,host_memory_bytes,cpu_ms,wall_ms,verifier_identity,resource_evidence,host_enforcement_sha256)
 values('b1100000-0000-0000-0000-000000000002',sha256(convert_to('{"hard_limit_fixture":true}','UTF8')),'{"hard_limit_fixture":true}','{"hard_limit_fixture":true}',decode(repeat('f1',32),'hex'),5242880,50,67108864,268435456,2000,120000,'local-hard-limit-fixture','hard_limits',decode(repeat('e1',32),'hex'));
update app_private.acquisition_policy set active_verification_profile='b1100000-0000-0000-0000-000000000002';
select test.acq_uploaded('2403.10013','b1100000-0000-0000-0000-000000000010',decode(repeat('cd',32),'hex')) as hardfixture \gset
select :'hardfixture'::jsonb->>'reservation' as hardreservation \gset
select gen_random_uuid() as hardclaim,gen_random_uuid() as hardop \gset
set local role science_reader_pdf_verifier;
select public.worker_claim_original_verification(:'hardreservation',:'hardclaim');
select test.reject(format($q$select public.worker_record_original_verification(%L,%L,1,%L,'b1100000-0000-0000-0000-000000000002',decode(repeat('f1',32),'hex'),'verified',decode(repeat('cd',32),'hex'),1000,2,'{"cpu_ms":1,"wall_ms":2,"peak_host_bytes":100000000,"wasm_bytes":67108864,"warnings":0,"repaired":false}')$q$,:'hardreservation',:'hardclaim',:'hardop'),'verification_profile_limit');
select public.worker_record_original_verification(:'hardreservation',:'hardclaim',1,:'hardop','b1100000-0000-0000-0000-000000000002',decode(repeat('f1',32),'hex'),'verified',decode(repeat('cd',32),'hex'),1000,2,
 jsonb_build_object('cpu_limit_ms',2000,'host_memory_limit_bytes',268435456,'wall_ms',2,'wasm_bytes',67108864,'warnings',0,'repaired',false,'host_enforcement_sha256',repeat('e1',32)));
reset role;

-- Admission preserves already-held completion and cleanup capacity when new
-- jobs are refused. A source ceiling rejection issues no permit or charge.
do $$ declare a uuid:='b1100000-0000-0000-0000-000000000011'; i uuid:=gen_random_uuid(); j uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); r jsonb; previous_bytes bigint; old_cap bigint;
begin
 perform set_config('request.jwt.claim.sub',a::text,true);
 r:=public.v2_begin_import(i,'2403.10014',(select last_seq from app_private.library_sync_state where account_id=a),1);
 perform public.worker_prepare_acquisition(j,'2403.10014',1);
 perform public.worker_link_import_acquisition(a,i,1,(r->'entry'->>'state_seq')::bigint,j);
 update app_private.arxiv_network_gate set next_allowed_at='-infinity';
 select coalesce(sum(charged),0) into previous_bytes from app_private.acquisition_transfer_windows where kind='source_bytes';
 select source_download_bytes_month into old_cap from app_private.acquisition_policy;
 update app_private.acquisition_policy set source_download_bytes_month=greatest(1,previous_bytes);
 perform test.reject(format('select public.worker_claim_arxiv_stage(%L,%L,%L)',j,c,'staging'),'acquisition_source_transfer_limit');
 perform test.assert(not exists(select 1 from app_private.acquisition_steps where job_id=j and operation_id=c),'rejected source budget emits no claim/permit');
 perform test.assert((select generation=0 and atom_attempts=0 and status='queued' from app_private.acquisition_jobs where id=j),'source budget rejection cannot consume attempt or generation');
 perform test.assert((select coalesce(sum(charged),0) from app_private.acquisition_transfer_windows where kind='source_bytes')=previous_bytes,'rejected source ceiling rolls back transfer charge');
 update app_private.acquisition_policy set source_download_bytes_month=old_cap;
end $$;
-- Repeated deferrals cannot exhaust the bounded retry/control allowance.
do $$ declare a uuid:='b1100000-0000-0000-0000-000000000011'; i uuid:=gen_random_uuid(); j uuid:=gen_random_uuid();
 c uuid:=gen_random_uuid(); r jsonb; before_job jsonb; before_steps bigint; before_charge bigint; n integer;
begin
 perform set_config('request.jwt.claim.sub',a::text,true);
 r:=public.v2_begin_import(i,'2403.10015',(select last_seq from app_private.library_sync_state where account_id=a),1);
 perform public.worker_prepare_acquisition(j,'2403.10015',1);
 perform public.worker_link_import_acquisition(a,i,1,(r->'entry'->>'state_seq')::bigint,j);
 select to_jsonb(x) into before_job from app_private.acquisition_jobs x where id=j;
 select count(*) into before_steps from app_private.acquisition_steps;
 select coalesce(sum(charged),0) into before_charge from app_private.acquisition_transfer_windows;
 update app_private.arxiv_network_gate set next_allowed_at=clock_timestamp()+interval '1 hour';
 for n in 1..20 loop
  perform test.assert(public.worker_claim_arxiv_stage(j,case when n%2=0 then c else gen_random_uuid() end,'staging')->>'action'='wait','cooldown does not allocate a claim');
 end loop;
 perform test.assert((select to_jsonb(x)=before_job from app_private.acquisition_jobs x where id=j),'all job fields stable under repeated cooldown');
 perform test.assert((select count(*) from app_private.acquisition_steps)=before_steps,'no deferred receipt growth');
 perform test.assert((select coalesce(sum(charged),0) from app_private.acquisition_transfer_windows)=before_charge,'no deferred quota charge');
 update app_private.arxiv_network_gate set next_allowed_at='-infinity';
 r:=public.worker_claim_arxiv_stage(j,c,'staging');
 perform test.assert((r->>'granted')::boolean and r->'job'->>'generation'='1','first actual permit consumes first generation');
 -- Admission can close while an authorized transfer ends. Its immutable
 -- close/failure receipt and reserved-byte refund must remain available.
 update app_private.acquisition_policy set source_requests_day=1,source_download_bytes_month=1,control_bytes=8192;
 perform public.worker_finish_arxiv_request((r->>'token')::uuid,10,0);
 perform public.worker_fail_acquisition(j,c,1,'metadata_unavailable',true);
 perform test.assert((select status='retry_wait' and atom_attempts=1 from app_private.acquisition_jobs where id=j),'completion survives lowered new-work caps');
 update app_private.acquisition_policy set source_requests_day=1000,source_download_bytes_month=1073741824,control_bytes=33554432;
end $$;

-- Eligible, already-projected metadata cannot permanently occupy the prefix
-- of a metadata-only import scan. Missing link/revision/retirement still wins.
do $$ declare a uuid:='b1100000-0000-0000-0000-000000000012'; l uuid; i uuid; n integer; r jsonb; ids uuid[]:=array[]::uuid[]; target uuid:='ffffffff-ffff-ffff-ffff-ffffffffffff';
begin
 insert into auth.users values(a);
 select id into l from app_private.acquisition_jobs where kind='lookup' and source_id='2403.10002' and status='complete' limit 1;
 perform set_config('request.jwt.claim.sub',a::text,true);
 for n in 1..4 loop
  i:=('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid; ids:=array_append(ids,i);
  r:=public.v2_begin_import(i,'2403.10002',(select last_seq from app_private.library_sync_state where account_id=a),1);
  perform public.worker_link_import_acquisition(a,i,1,(r->'entry'->>'state_seq')::bigint,l);
  perform public.worker_project_import_acquisition(a,i,1);
 end loop;
 perform public.v2_begin_import(target,'2403.10016',(select last_seq from app_private.library_sync_state where account_id=a),1);
 r:=public.worker_scan_acquisition_imports(a,'00000000-0000-0000-0000-000000000000',2,true);
 perform test.assert(r->'entries'->0->>'import_id'=target::text,'metadata-only scan reaches unlinked import after more than a page of eligible waits');
 perform test.assert(public.worker_scan_acquisition_imports(a,'00000000-0000-0000-0000-000000000000',2)->>'has_more'='true','default full scan retains original scheduling obligations');
 update app_private.acquisition_interests set projected_lookup_revision=0 where account_id=a and import_id=ids[1];
 perform public.v2_cancel_import(gen_random_uuid(),ids[2],1);
 r:=public.worker_scan_acquisition_imports(a,'00000000-0000-0000-0000-000000000000',2,true);
 perform test.assert(r->'entries'->0->>'import_id'=ids[1]::text and r->'entries'->1->>'import_id'=ids[2]::text,'metadata scan retains projection and retirement obligations');
 perform test.assert(not exists(select 1 from jsonb_array_elements(public.worker_scan_acquisition_jobs(null,100,'lookup')) e where e->>'kind'<>'lookup'),'metadata job scan excludes original work');
 perform test.reject($q$select public.worker_scan_acquisition_jobs(null,50,'invalid')$q$,'invalid_acquisition_limit');
 perform test.reject($q$select public.worker_scan_acquisition_imports(null,null,50,null)$q$,'invalid_acquisition_cursor');
end $$;

-- Original upload state only changes with the atomic permit. An uncertain
-- prior writer retains its safe horizon even when its network permit closed.
do $$ declare a uuid:='b1100000-0000-0000-0000-000000000011'; i uuid:=gen_random_uuid(); l uuid:=gen_random_uuid(); o uuid:=gen_random_uuid();
 res uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); later uuid:=gen_random_uuid(); r jsonb; before_res jsonb; before_job jsonb;
begin
 perform test.acq_lookup('2403.10017',a,i,l,true);
 perform public.worker_prepare_original(o,l);
 perform public.worker_link_import_acquisition(a,i,1,(public.worker_import_state(a,i)->'entry'->>'state_seq')::bigint,l,o);
 perform public.worker_claim_acquisition(o,c); perform public.worker_reserve_original(o,c,1,res);
 select to_jsonb(x) into before_res from app_private.paper_asset_reservations x where id=res;
 select to_jsonb(x) into before_job from app_private.acquisition_jobs x where id=o;
 update app_private.arxiv_network_gate set next_allowed_at=clock_timestamp()+interval '1 hour';
 perform test.assert(public.worker_claim_arxiv_stage(o,later,'staging',res)->>'action'='wait','original gate cooldown defers atomically');
 perform test.assert((select to_jsonb(x)=before_res from app_private.paper_asset_reservations x where id=res),'cooldown preserves reservation including safe_after');
 perform test.assert((select to_jsonb(x)=before_job from app_private.acquisition_jobs x where id=o),'cooldown preserves original generation/attempts');
 update app_private.arxiv_network_gate set next_allowed_at='-infinity';
 r:=public.worker_claim_arxiv_stage(o,later,'staging',res);
 perform test.assert((r->>'granted')::boolean and r->'job'->>'generation'='2','download grant consumes one source attempt');
 perform test.assert((select state='uploading' and generation=2 and safe_after=(r->'job'->>'hard_deadline')::timestamptz from app_private.paper_asset_reservations where id=res),'reservation writer horizon advances with permit');
 perform test.assert(public.worker_claim_arxiv_stage(o,later,'staging',res)->>'granted'='false','lost upload grant cannot refetch');
 perform test.reject(format('select public.worker_claim_arxiv_stage(%L,%L,%L,%L)',o,later,'staging',gen_random_uuid()),'operation_id_conflict');
 perform public.worker_finish_arxiv_request((r->>'token')::uuid,10,0);
 perform public.worker_fail_acquisition(o,later,2,'download_failed',true);
 update app_private.acquisition_jobs set next_attempt_at=clock_timestamp()-interval '1 second' where id=o;
 update app_private.arxiv_network_gate set next_allowed_at='-infinity';
 perform test.assert(public.worker_claim_arxiv_stage(o,gen_random_uuid(),'staging',res)->>'action'='wait','uncertain storage writer horizon prevents overlap');
 perform test.assert((select download_attempts=1 and generation=2 from app_private.acquisition_jobs where id=o),'writer-horizon wait consumes no download attempt');
 update app_private.paper_asset_reservations set safe_after=clock_timestamp()-interval '1 second' where id=res;
 c:=gen_random_uuid(); r:=public.worker_claim_arxiv_stage(o,c,'staging',res);
 perform test.assert((r->>'granted')::boolean and r->'job'->>'generation'='3','fresh attempt only after writer horizon');
 perform public.worker_finish_arxiv_request((r->>'token')::uuid,10,0);
 perform public.worker_fail_acquisition(o,c,3,'download_failed',true);
end $$;
rollback;
