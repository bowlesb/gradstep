-- Reviewed acquisition contract; outbound and verification start disabled.
-- Original storage/verification only. Paid OCR authorization remains closed.
begin;
-- Freeze account-owned writers before creating FK/trigger locks or taking the
-- catalog mutex for the bounded projection backfill. Readers remain available.
lock table app_private.accounts in exclusive mode;
-- Global catalog writers do not take account locks. Drain their policy lock
-- before FK DDL takes referenced-table locks that those writers may need.
do $$ begin perform 1 from app_private.library_policy where singleton for update; end $$;

create table app_private.acquisition_policy (
 singleton boolean primary key default true check(singleton),
 metadata_enabled boolean not null default false, original_enabled boolean not null default false, verification_enabled boolean not null default false,
 gateway_environment text not null default 'staging' check(gateway_environment='staging'),
 source_slots integer not null default 2000 check(source_slots>0), jobs integer not null default 10000 check(jobs>0),
 steps integer not null default 100000 check(steps>0), control_bytes bigint not null default 33554432 check(control_bytes>=8192),
 source_requests_day integer not null default 1000 check(source_requests_day>0),
 source_download_bytes_month bigint not null default 1073741824 check(source_download_bytes_month>0),
 worker_read_bytes_month bigint not null default 2147483648 check(worker_read_bytes_month>0),
 reader_bytes_month bigint not null default 2147483648 check(reader_bytes_month>0),
 account_reader_bytes_month bigint not null default 268435456 check(account_reader_bytes_month>0),
 lookup_fresh_seconds integer not null default 86400 check(lookup_fresh_seconds between 1 and 86400),
 stage_lease_seconds integer not null default 120 check(stage_lease_seconds between 1 and 120),
 hard_recovery_seconds integer not null default 450 check(hard_recovery_seconds>=450),
 retry_age_seconds integer not null default 86400 check(retry_age_seconds between 1 and 86400),
 active_verification_profile uuid
);
insert into app_private.acquisition_policy(singleton) values(true);
create table app_private.acquisition_source_slots (
 id uuid primary key default gen_random_uuid(), source_id text not null check(length(source_id) between 1 and 128),
 requested_revision integer not null check(requested_revision>=0), generation bigint not null default 0 check(generation>=0),
 active_job_id uuid, cached_job_id uuid, fresh_until timestamptz,
 unique(source_id,requested_revision)
);
create table app_private.acquisition_jobs (
 id uuid primary key, kind text not null check(kind in ('lookup','original')),
 source_slot_id uuid references app_private.acquisition_source_slots(id), slot_generation bigint,
 source_id text not null check(length(source_id) between 1 and 128), requested_revision integer check(requested_revision>0),
 input_sha256 bytea not null check(octet_length(input_sha256)=32),
 metadata_id uuid references app_private.catalog_metadata(id), version_id uuid references app_private.publication_versions(id),
 source_revision integer check(source_revision>0), atom_published_at timestamptz, atom_updated_at timestamptz,
 reuse_policy text not null default 'arxiv-reuse-v1' check(reuse_policy='arxiv-reuse-v1'),
 acquisition_profile text not null default 'arxiv-original-v1' check(acquisition_profile='arxiv-original-v1'),
 stage text not null check(stage in ('atom','license','reserve','download','pending_verification','publish','complete')),
 status text not null default 'queued' check(status in ('queued','leased','retry_wait','no_interest','blocked','failed','complete')),
 state_revision bigint not null default 1 check(state_revision>0),
 generation bigint not null default 0 check(generation>=0), claim_id uuid,
 lease_until timestamptz, hard_deadline timestamptz, next_attempt_at timestamptz not null default now(),
 atom_attempts integer not null default 0 check(atom_attempts between 0 and 3),
 license_attempts integer not null default 0 check(license_attempts between 0 and 3),
 download_attempts integer not null default 0 check(download_attempts between 0 and 2),
 eligibility text check(eligibility in ('eligible','source_only')), license_uri text,
 evidence jsonb check(evidence is null or (jsonb_typeof(evidence)='object' and octet_length(evidence::text)<=4096)),
 source_detail text check(source_detail in ('revision_unverified','license_unverified','license_not_supported')),
 error_code text check(error_code in ('metadata_unavailable','source_not_found','invalid_source_metadata','rate_limited','download_failed','pdf_invalid','verification_failed','capacity_exhausted','no_interest','legacy_original_unverified')),
 retryable boolean not null default false,
 document_id uuid references app_private.documents(id), original_object_id uuid references app_private.stored_objects(id),
 approval_id uuid references app_private.catalog_asset_approvals(id),
 slots_held integer not null check(slots_held between 1 and 24), created_at timestamptz not null default now(),
 check((kind='lookup' and source_slot_id is not null and slot_generation is not null)
    or (kind='original' and source_slot_id is null and slot_generation is null and version_id is not null and metadata_id is not null)),
 check((lease_until is null)=(claim_id is null)),
 unique(source_slot_id,slot_generation)
);
create unique index active_original_acquisition on app_private.acquisition_jobs(version_id,reuse_policy,acquisition_profile)
 where kind='original' and status in ('queued','leased','retry_wait','blocked');
create index acquisition_job_ready on app_private.acquisition_jobs(status,next_attempt_at,id);
alter table app_private.acquisition_source_slots
 add foreign key(active_job_id) references app_private.acquisition_jobs(id),
 add foreign key(cached_job_id) references app_private.acquisition_jobs(id);
create table app_private.acquisition_steps (
 job_id uuid not null references app_private.acquisition_jobs(id), operation_id uuid not null,
 request_sha256 bytea not null check(octet_length(request_sha256)=32), kind text not null,
 generation bigint not null, stage text not null,
 outcome text not null default 'issued' check(outcome in ('issued','complete','failed','uncertain')),
 result jsonb check(result is null or (jsonb_typeof(result)='object' and octet_length(result::text)<=8192)),
 result_sha256 bytea check(result_sha256 is null or octet_length(result_sha256)=32),
 network_token uuid, network_granted_at timestamptz, network_closed_at timestamptz,
 network_byte_ceiling bigint, network_actual_bytes bigint, network_period date, network_retry_after_seconds integer,
 created_at timestamptz not null default now(), completed_at timestamptz,
 primary key(job_id,operation_id), unique(network_token), check(length(kind) between 1 and 32)
);
create table app_private.acquisition_commands (
 id uuid primary key, request_sha256 bytea not null check(octet_length(request_sha256)=32),
 job_id uuid not null references app_private.acquisition_jobs(id), created_at timestamptz not null default now()
);
create trigger acquisition_command_immutable before update or delete on app_private.acquisition_commands
 for each row execute function app_private.immutable_record();
create table app_private.acquisition_interests (
 account_id uuid not null, import_id uuid not null, intent_revision bigint not null check(intent_revision>0),
 lookup_job_id uuid not null references app_private.acquisition_jobs(id),
 original_job_id uuid references app_private.acquisition_jobs(id),
 projected_lookup_revision bigint not null default 0 check(projected_lookup_revision>=0),
 projected_original_revision bigint not null default 0 check(projected_original_revision>=0),
 import_state_seq bigint not null check(import_state_seq>0), retired boolean not null default false,
 primary key(account_id,import_id),
 foreign key(account_id,import_id) references app_private.import_requests(account_id,id) on delete cascade
);
create index acquisition_interest_jobs on app_private.acquisition_interests(lookup_job_id,original_job_id);
create table app_private.arxiv_network_gate (
 singleton boolean primary key default true check(singleton),
 token uuid, job_id uuid, operation_id uuid, generation bigint not null default 0,
 granted_at timestamptz, hard_deadline timestamptz, next_allowed_at timestamptz not null default '-infinity',
 check((token is null)=(job_id is null)),
 foreign key(job_id,operation_id) references app_private.acquisition_steps(job_id,operation_id)
);
insert into app_private.arxiv_network_gate(singleton) values(true);
create table app_private.acquisition_transfer_windows (
 period date not null, scope text not null check(length(scope) between 1 and 64),
 kind text not null check(kind in ('source_requests','source_bytes','worker_bytes','reader_bytes')),
 charged bigint not null check(charged>=0), primary key(period,scope,kind)
);
create table app_private.paper_storage_capacity (
 singleton boolean primary key default true check(singleton),
 max_bytes bigint not null default 536870912 check(max_bytes>0), max_objects integer not null default 2000 check(max_objects>0),
 active_reservations integer not null default 4 check(active_reservations between 1 and 100),
 input_max_bytes bigint not null default 5242880 check(input_max_bytes between 1 and 33554432),
 page_max integer not null default 50 check(page_max between 1 and 250), asset_state_seq bigint not null default 0 check(asset_state_seq>=0)
);
insert into app_private.paper_storage_capacity(singleton) values(true);
create table app_private.paper_verification_profiles (
 id uuid primary key, profile_sha256 bytea not null check(octet_length(profile_sha256)=32),
 definition jsonb not null check(jsonb_typeof(definition)='object' and octet_length(definition::text)<=8192),
 canonical_profile text not null check(octet_length(canonical_profile)<=8192 and canonical_profile::jsonb=definition
  and profile_sha256=sha256(convert_to(canonical_profile,'UTF8'))),
 build_sha256 bytea not null check(octet_length(build_sha256)=32),
 max_bytes bigint not null check(max_bytes between 1 and 5242880), max_pages integer not null check(max_pages between 1 and 50),
 wasm_memory_bytes bigint not null check(wasm_memory_bytes between 1 and 67108864),
 host_memory_bytes bigint not null check(host_memory_bytes between wasm_memory_bytes and 268435456),
 cpu_ms integer not null check(cpu_ms between 1 and 2000), wall_ms integer not null check(wall_ms between 1 and 120000),
 resource_evidence text not null default 'measured' check(resource_evidence in ('measured','hard_limits')),
 host_enforcement_sha256 bytea check(host_enforcement_sha256 is null or octet_length(host_enforcement_sha256)=32),
 check((resource_evidence='hard_limits')=(host_enforcement_sha256 is not null)),
 verifier_identity text not null check(length(verifier_identity) between 1 and 256), created_at timestamptz not null default now()
);
create trigger verification_profile_immutable before update or delete on app_private.paper_verification_profiles
 for each row execute function app_private.immutable_record();
alter table app_private.acquisition_policy add foreign key(active_verification_profile) references app_private.paper_verification_profiles(id);
create table app_private.paper_asset_reservations (
 id uuid primary key, job_id uuid not null references app_private.acquisition_jobs(id),
 operation_id uuid not null, request_sha256 bytea not null check(octet_length(request_sha256)=32),
 generation bigint not null, path text not null unique,
 max_bytes bigint not null check(max_bytes between 1 and 5242880), held_bytes bigint not null check(held_bytes>=0),
 state text not null default 'reserved' check(state in ('reserved','uploading','upload_uncertain','pending_verification','verifying','verified','published','quarantined','deleting','deleted')),
 candidate_sha256 bytea check(candidate_sha256 is null or octet_length(candidate_sha256)=32),
 candidate_bytes bigint check(candidate_bytes between 1 and 5242880),
 verification_profile_id uuid not null references app_private.paper_verification_profiles(id),
 verification_generation bigint not null default 0 check(verification_generation>=0),
 verification_attempts integer not null default 0 check(verification_attempts between 0 and 3),
 verification_claim uuid, verification_execution_deadline timestamptz, verification_lease_until timestamptz,
 verification_result_id uuid, original_object_id uuid references app_private.stored_objects(id),
 deletion_operation_id uuid, deletion_generation bigint not null default 0, deletion_lease_until timestamptz,
 expires_at timestamptz not null, safe_after timestamptz not null,
 created_at timestamptz not null default now(), deleted_at timestamptz,
 unique(job_id,operation_id), check(held_bytes<=max_bytes),
 check(path='originals/'||id::text||'/original.pdf'),
 check((candidate_sha256 is null)=(candidate_bytes is null)),
 check((state='deleted')=(deleted_at is not null))
);
create table app_private.paper_verification_results (
 id uuid primary key, reservation_id uuid not null references app_private.paper_asset_reservations(id),
 generation bigint not null, profile_id uuid not null references app_private.paper_verification_profiles(id),
 operation_id uuid not null, request_sha256 bytea not null check(octet_length(request_sha256)=32),
 sha256 bytea not null check(octet_length(sha256)=32), byte_count bigint not null check(byte_count between 1 and 5242880),
 page_count integer check(page_count between 1 and 50),
 outcome text not null check(outcome in ('verified','malformed','encrypted','unsupported','parser_resource_limit','input_limit','page_limit','resource_limit','time_limit','internal_error')),
 verifier_identity text not null, metrics jsonb not null check(jsonb_typeof(metrics)='object' and octet_length(metrics::text)<=8192),
 created_at timestamptz not null default now(), unique(reservation_id,operation_id),
 check((outcome='verified')=(page_count is not null))
);
create trigger verification_result_immutable before update or delete on app_private.paper_verification_results
 for each row execute function app_private.immutable_record();
alter table app_private.paper_asset_reservations add foreign key(verification_result_id) references app_private.paper_verification_results(id);
create table app_private.paper_originals (
 document_id uuid primary key references app_private.documents(id),
 object_id uuid not null unique references app_private.stored_objects(id),
 verification_result_id uuid not null unique references app_private.paper_verification_results(id),
 published_at timestamptz not null default now()
);
create trigger paper_original_immutable before update or delete on app_private.paper_originals
 for each row execute function app_private.immutable_record();
create table app_private.paper_asset_availability (
 object_id uuid primary key references app_private.stored_objects(id),
 revision bigint not null check(revision>0), state text not null check(state in ('available','unavailable','quarantined')),
 reason text check(reason in ('missing','checksum_mismatch','temporarily_unavailable','verification_revoked')),
 checked_at timestamptz not null default now(), last_operation_id uuid, last_request_sha256 bytea,
 check(state<>'available' or reason is null)
);
create table app_private.paper_availability_outbox (
 document_id uuid primary key references app_private.documents(id), target_revision bigint not null check(target_revision>0),
 pass_revision bigint, after_account uuid, after_item uuid,
 generation bigint not null default 0, claim_id uuid, lease_until timestamptz,
 check((after_account is null)=(after_item is null)), check((claim_id is null)=(lease_until is null))
);
create table app_private.library_asset_projection (
 account_id uuid not null, item_id uuid not null, document_id uuid not null,
 original_object_id uuid references app_private.stored_objects(id), artifact_id uuid references app_private.render_artifacts(id),
 original_availability text not null check(original_availability in ('available','unavailable','quarantined','unverified')),
 render_availability text not null check(render_availability in ('available','unavailable','quarantined','unverified','not_converted','incompatible')),
 original_availability_revision bigint not null default 0 check(original_availability_revision>=0),
 render_availability_revision bigint not null default 0 check(render_availability_revision>=0),
 primary key(account_id,item_id),
 foreign key(account_id,item_id,document_id) references app_private.library_items(account_id,id,document_id) on delete cascade
);

-- Global identity/FK keys are immutable. Mutable job/slot/object state uses
-- NO KEY UPDATE so an account linker holding library_policy can obtain the
-- corresponding FK KEY SHARE without waiting on a publisher needing policy.
create function app_private.protect_acquisition_identity() returns trigger language plpgsql set search_path='' as $$
begin
 if TG_TABLE_NAME='acquisition_jobs' then
  if (new.id,new.kind,new.source_slot_id,new.slot_generation,new.source_id,new.requested_revision,new.input_sha256,new.reuse_policy,new.acquisition_profile,new.created_at)
   is distinct from (old.id,old.kind,old.source_slot_id,old.slot_generation,old.source_id,old.requested_revision,old.input_sha256,old.reuse_policy,old.acquisition_profile,old.created_at)
   or (old.metadata_id is not null and (new.metadata_id,new.version_id,new.source_revision,new.atom_published_at,new.atom_updated_at) is distinct from (old.metadata_id,old.version_id,old.source_revision,old.atom_published_at,old.atom_updated_at))
   or (old.eligibility is not null and (new.eligibility,new.license_uri,new.evidence,new.source_detail) is distinct from (old.eligibility,old.license_uri,old.evidence,old.source_detail))
   or (old.original_object_id is not null and (new.document_id,new.original_object_id) is distinct from (old.document_id,old.original_object_id))
   then raise exception 'immutable_acquisition_identity'; end if;
  if new.slots_held>old.slots_held then raise exception 'acquisition_headroom_cannot_grow'; end if;
 elsif TG_TABLE_NAME='acquisition_source_slots' then
  if (new.id,new.source_id,new.requested_revision) is distinct from (old.id,old.source_id,old.requested_revision) then raise exception 'immutable_acquisition_identity'; end if;
 elsif TG_TABLE_NAME='paper_asset_reservations' then
  if (new.id,new.job_id,new.operation_id,new.request_sha256,new.path,new.max_bytes,new.verification_profile_id,new.created_at)
    is distinct from (old.id,old.job_id,old.operation_id,old.request_sha256,old.path,old.max_bytes,old.verification_profile_id,old.created_at)
   or (old.candidate_sha256 is not null and (new.candidate_sha256,new.candidate_bytes) is distinct from (old.candidate_sha256,old.candidate_bytes))
   or (old.original_object_id is not null and new.original_object_id is distinct from old.original_object_id)
   then raise exception 'immutable_original_identity'; end if;
 elsif TG_TABLE_NAME='acquisition_steps' then
  if (new.job_id,new.operation_id,new.request_sha256,new.kind,new.generation,new.stage,new.created_at)
    is distinct from (old.job_id,old.operation_id,old.request_sha256,old.kind,old.generation,old.stage,old.created_at)
   or (old.result_sha256 is not null and (new.result,new.result_sha256) is distinct from (old.result,old.result_sha256))
   then raise exception 'immutable_acquisition_step'; end if;
 end if;
 return new;
end $$;
create trigger acquisition_job_identity before update on app_private.acquisition_jobs for each row execute function app_private.protect_acquisition_identity();
create trigger acquisition_slot_identity before update on app_private.acquisition_source_slots for each row execute function app_private.protect_acquisition_identity();
create trigger original_reservation_identity before update on app_private.paper_asset_reservations for each row execute function app_private.protect_acquisition_identity();
create trigger acquisition_step_identity before update on app_private.acquisition_steps for each row execute function app_private.protect_acquisition_identity();

create function app_private.acquisition_job_entry(p_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',j.id,'kind',j.kind,'source_id',j.source_id,'requested_revision',j.requested_revision,'source_revision',j.source_revision,
  'metadata_id',j.metadata_id,'version_id',j.version_id,'metadata',m.metadata,
  'atom_published_at',to_char(j.atom_published_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
  'atom_updated_at',to_char(j.atom_updated_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
  'stage',j.stage,'status',j.status,'state_revision',j.state_revision,'generation',j.generation,
  'claim_id',j.claim_id,'lease_until',j.lease_until,'hard_deadline',j.hard_deadline,'next_attempt_at',j.next_attempt_at,
  'eligibility',j.eligibility,'license_uri',j.license_uri,'evidence',j.evidence,'source_detail',j.source_detail,'error_code',j.error_code,'retryable',j.retryable,
  'document_id',j.document_id,'original_object_id',j.original_object_id,'approval_id',j.approval_id,
  'reservations',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'state',r.state,'generation',r.generation,'verification_generation',r.verification_generation) order by r.id),'[]'::jsonb) from app_private.paper_asset_reservations r where r.job_id=j.id))
 from app_private.acquisition_jobs j left join app_private.catalog_metadata m on m.id=j.metadata_id where j.id=p_id
$$;
create function app_private.acquisition_has_interest(p_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.acquisition_interests x join app_private.import_requests i on (i.account_id,i.id)=(x.account_id,x.import_id)
  join app_private.accounts a on a.id=x.account_id and a.closed_at is null
  where (x.lookup_job_id=p_id or x.original_job_id=p_id) and not x.retired and x.intent_revision=i.intent_revision
  and i.desired_present and i.phase in ('accepted','resolving','acquiring'))
$$;
create function app_private.acquisition_admit(p_slots integer,p_new_slot boolean) returns void language plpgsql security definer set search_path='' as $$
declare p app_private.acquisition_policy; n bigint; held bigint; commands bigint;
begin
 select * into strict p from app_private.acquisition_policy where singleton for update;
 select count(*),coalesce(sum(slots_held),0) into n,held from app_private.acquisition_jobs;
 select count(*) into commands from app_private.acquisition_commands;
 if n+(case when p_slots>0 then 1 else 0 end)>p.jobs or held+p_slots+commands+1>p.steps
 or (n+(case when p_slots>0 then 1 else 0 end)+held+p_slots+commands+1+2*(select count(*) from app_private.paper_verification_profiles))*8192>p.control_bytes then raise exception 'acquisition_control_capacity'; end if;
 if p_new_slot and (select count(*) from app_private.acquisition_source_slots)+1>p.source_slots then raise exception 'acquisition_source_capacity'; end if;
end $$;
create function app_private.acquisition_add_step(j uuid,op uuid,digest bytea,p_kind text,p_generation bigint,p_stage text,p_completion boolean default false)
returns boolean language plpgsql security definer set search_path='' as $$
declare s app_private.acquisition_steps; n integer; held integer; obligations integer;
begin
 select * into s from app_private.acquisition_steps where job_id=j and operation_id=op;
 if found then
  if s.request_sha256<>digest or s.kind<>p_kind then raise exception 'operation_id_conflict'; end if;
  return false;
 end if;
 select slots_held into strict held from app_private.acquisition_jobs where id=j;
 select (select count(*) from app_private.acquisition_steps where job_id=j)
  +(select count(*) from app_private.paper_verification_results v join app_private.paper_asset_reservations r on r.id=v.reservation_id where r.job_id=j)
  +(select count(*) from app_private.paper_integrity_failures f join app_private.paper_asset_reservations r on r.id=f.reservation_id where r.job_id=j) into n;
 select 1+2*count(*) into obligations from app_private.paper_asset_reservations where job_id=j and state not in ('published','deleted');
 if n+1+(case when p_completion then 0 else obligations end)>held then raise exception 'acquisition_attempt_limit'; end if;
 insert into app_private.acquisition_steps(job_id,operation_id,request_sha256,kind,generation,stage)
 values(j,op,digest,p_kind,p_generation,p_stage);
 return true;
end $$;
create function app_private.acquisition_finish_step(j uuid,op uuid,p_result jsonb,p_outcome text default 'complete') returns void
language plpgsql security definer set search_path='' as $$
declare s app_private.acquisition_steps; digest bytea:=sha256(convert_to(p_result::text,'UTF8'));
begin
 if p_result is null or jsonb_typeof(p_result)<>'object' or octet_length(p_result::text)>8192 or p_outcome not in ('complete','failed','uncertain') then raise exception 'invalid_acquisition_result'; end if;
 select * into strict s from app_private.acquisition_steps where job_id=j and operation_id=op for no key update;
 if s.result_sha256 is not null then
  if s.result_sha256<>digest then raise exception 'operation_id_conflict'; end if;
  return;
 end if;
 update app_private.acquisition_steps set result=p_result,result_sha256=digest,outcome=p_outcome,completed_at=clock_timestamp()
 where job_id=j and operation_id=op;
end $$;

create function public.worker_acquisition_state(p_job_id uuid,p_operation_id uuid default null) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('job',app_private.acquisition_job_entry(p_job_id),
  'step',(select jsonb_build_object('operation_id',operation_id,'kind',kind,'generation',generation,'stage',stage,'outcome',outcome,'result',result,
   'network_closed',network_closed_at is not null) from app_private.acquisition_steps where job_id=p_job_id and operation_id=p_operation_id))
$$;
create function public.worker_prepare_acquisition(p_operation_id uuid,p_source_id text,p_requested_revision integer default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare src text:=app_private.validate_arxiv_id(p_source_id); digest bytea; command app_private.acquisition_commands;
 slot app_private.acquisition_source_slots; j app_private.acquisition_jobs; p app_private.acquisition_policy; chosen uuid;
begin
 if p_operation_id is null or (p_requested_revision is not null and p_requested_revision<1) then raise exception 'invalid_acquisition_request'; end if;
 digest:=sha256(convert_to(jsonb_build_array('lookup',src,p_requested_revision)::text,'UTF8'));
 select * into strict p from app_private.acquisition_policy where singleton for update;
 select * into command from app_private.acquisition_commands where id=p_operation_id;
 if found then
  if command.request_sha256<>digest then raise exception 'operation_id_conflict'; end if;
  return jsonb_build_object('job',app_private.acquisition_job_entry(command.job_id),'replayed',true);
 end if;
 select * into slot from app_private.acquisition_source_slots where source_id=src and requested_revision=coalesce(p_requested_revision,0) for no key update;
 if found then
  select * into j from app_private.acquisition_jobs where id=slot.active_job_id for no key update;
  if j.status in ('queued','leased','retry_wait','blocked') and j.created_at+make_interval(secs=>p.retry_age_seconds)>clock_timestamp() then chosen:=j.id;
  elsif slot.cached_job_id is not null and slot.fresh_until>clock_timestamp() then chosen:=slot.cached_job_id;
  end if;
 end if;
 if chosen is not null then
  perform app_private.acquisition_admit(0,false);
 else
  perform app_private.acquisition_admit(12,slot.id is null);
  if slot.id is null then
   insert into app_private.acquisition_source_slots(source_id,requested_revision) values(src,coalesce(p_requested_revision,0)) returning * into slot;
  end if;
  -- Retire expired unclaimed work before installing a new generation. A late
  -- claim/output is fenced by status/generation and cannot repin its successor.
  if j.id is not null and j.status in ('queued','retry_wait','blocked') then
   update app_private.acquisition_jobs set status='failed',error_code='metadata_unavailable',retryable=true,state_revision=state_revision+1
   where id=j.id;
  end if;
  chosen:=p_operation_id;
  insert into app_private.acquisition_jobs(id,kind,source_slot_id,slot_generation,source_id,requested_revision,input_sha256,stage,slots_held)
  values(chosen,'lookup',slot.id,slot.generation+1,src,p_requested_revision,digest,'atom',12);
  update app_private.acquisition_source_slots set generation=generation+1,active_job_id=chosen where id=slot.id;
 end if;
 insert into app_private.acquisition_commands(id,request_sha256,job_id) values(p_operation_id,digest,chosen);
 return jsonb_build_object('job',app_private.acquisition_job_entry(chosen),'replayed',false);
end $$;
-- Retry retains the failed lookup's immutable observation. A pinned license
-- retry is not a refresh of the unversioned shared source cache.
create function public.worker_retry_lookup(p_operation_id uuid,p_previous_job_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare old app_private.acquisition_jobs; j app_private.acquisition_jobs; slot app_private.acquisition_source_slots;
 command app_private.acquisition_commands; digest bytea; chosen uuid; p app_private.acquisition_policy;
begin
 if p_operation_id is null or p_previous_job_id is null then raise exception 'invalid_acquisition_request'; end if;
 digest:=sha256(convert_to(jsonb_build_array('retry-lookup',p_previous_job_id)::text,'UTF8'));
 select * into strict p from app_private.acquisition_policy where singleton for update;
 select * into command from app_private.acquisition_commands where id=p_operation_id;
 if found then
  if command.request_sha256<>digest then raise exception 'operation_id_conflict'; end if;
  return jsonb_build_object('job',app_private.acquisition_job_entry(command.job_id),'replayed',true);
 end if;
 select * into old from app_private.acquisition_jobs where id=p_previous_job_id and kind='lookup';
 if not found or old.status<>'failed' or not old.retryable then raise exception 'acquisition_retry_unavailable'; end if;
 select * into slot from app_private.acquisition_source_slots where id=old.source_slot_id for no key update;
 select * into j from app_private.acquisition_jobs where kind='lookup' and input_sha256=digest
  and status in ('queued','leased','retry_wait','blocked','complete') and created_at+make_interval(secs=>p.retry_age_seconds)>clock_timestamp()
  order by created_at desc,id limit 1 for no key update;
 if found then chosen:=j.id; perform app_private.acquisition_admit(0,false);
 else
  perform app_private.acquisition_admit(12,false); chosen:=p_operation_id;
  update app_private.acquisition_source_slots set generation=generation+1 where id=slot.id returning * into slot;
  insert into app_private.acquisition_jobs(id,kind,source_slot_id,slot_generation,source_id,requested_revision,input_sha256,
   metadata_id,version_id,source_revision,atom_published_at,atom_updated_at,stage,slots_held)
  values(chosen,'lookup',slot.id,slot.generation,old.source_id,old.requested_revision,digest,old.metadata_id,old.version_id,
   old.source_revision,old.atom_published_at,old.atom_updated_at,case when old.metadata_id is null then 'atom' else 'license' end,12);
 end if;
 insert into app_private.acquisition_commands(id,request_sha256,job_id) values(p_operation_id,digest,chosen);
 return jsonb_build_object('job',app_private.acquisition_job_entry(chosen),'replayed',false);
end $$;
create function public.worker_prepare_original(p_operation_id uuid,p_lookup_job_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare digest bytea; command app_private.acquisition_commands; l app_private.acquisition_jobs; j app_private.acquisition_jobs; chosen uuid;
begin
 if p_operation_id is null or p_lookup_job_id is null then raise exception 'invalid_acquisition_request'; end if;
 digest:=sha256(convert_to(jsonb_build_array('original',p_lookup_job_id)::text,'UTF8'));
 perform 1 from app_private.acquisition_policy where singleton for update;
 select * into command from app_private.acquisition_commands where id=p_operation_id;
 if found then
  if command.request_sha256<>digest then raise exception 'operation_id_conflict'; end if;
  return jsonb_build_object('job',app_private.acquisition_job_entry(command.job_id),'replayed',true);
 end if;
 select * into l from app_private.acquisition_jobs where id=p_lookup_job_id and kind='lookup';
 if not found or l.status<>'complete' or l.eligibility<>'eligible' or l.metadata_id is null then raise exception 'acquisition_eligibility_required'; end if;
 select * into j from app_private.acquisition_jobs where kind='original' and version_id=l.version_id and reuse_policy=l.reuse_policy
  and acquisition_profile=l.acquisition_profile and status in ('queued','leased','retry_wait','blocked','complete')
 order by case when status='complete' then 0 else 1 end,created_at,id limit 1 for no key update;
 if found then
  chosen:=j.id; perform app_private.acquisition_admit(0,false);
 else
  perform app_private.acquisition_admit(24,false); chosen:=p_operation_id;
  insert into app_private.acquisition_jobs(id,kind,source_id,requested_revision,input_sha256,metadata_id,version_id,source_revision,
   atom_published_at,atom_updated_at,eligibility,license_uri,evidence,stage,slots_held)
  values(chosen,'original',l.source_id,l.source_revision,digest,l.metadata_id,l.version_id,l.source_revision,
   l.atom_published_at,l.atom_updated_at,l.eligibility,l.license_uri,l.evidence,'reserve',24);
 end if;
 insert into app_private.acquisition_commands(id,request_sha256,job_id) values(p_operation_id,digest,chosen);
 return jsonb_build_object('job',app_private.acquisition_job_entry(chosen),'replayed',false);
end $$;
create function public.worker_import_state(p_account_id uuid,p_import_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('entry',app_private.library_import_entry(p_account_id,p_import_id),
  'desired_present',i.desired_present,'observed_cursor',i.observed_cursor,
  'acquisition',case when x.import_id is null then null else jsonb_build_object('intent_revision',x.intent_revision,'lookup_job_id',x.lookup_job_id,
   'original_job_id',x.original_job_id,'projected_lookup_revision',x.projected_lookup_revision,'projected_original_revision',x.projected_original_revision,'retired',x.retired) end)
 from app_private.import_requests i left join app_private.acquisition_interests x on (x.account_id,x.import_id)=(i.account_id,i.id)
 where i.account_id=p_account_id and i.id=p_import_id
$$;
create function public.worker_scan_acquisition_imports(p_after_account uuid default null,p_after_import uuid default null,p_limit integer default 50,p_metadata_only boolean default false)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare entries jsonb; lastrow jsonb; more boolean;
begin
 if (p_after_account is null)<>(p_after_import is null) or p_limit is null or p_limit not between 1 and 100 or p_metadata_only is null then raise exception 'invalid_acquisition_cursor'; end if;
 with pending as (
  select i.account_id,i.id from app_private.import_requests i join app_private.accounts a on a.id=i.account_id and a.closed_at is null
  left join app_private.acquisition_interests x on (x.account_id,x.import_id)=(i.account_id,i.id)
  left join app_private.acquisition_jobs l on l.id=x.lookup_job_id left join app_private.acquisition_jobs o on o.id=x.original_job_id
  where (p_after_account is null or (i.account_id,i.id)>(p_after_account,p_after_import))
   and ((i.desired_present and i.phase in ('accepted','resolving','acquiring') and
    (x.import_id is null or x.intent_revision<>i.intent_revision or x.projected_lookup_revision<l.state_revision
     or x.projected_original_revision<o.state_revision or (not p_metadata_only and l.eligibility='eligible' and o.id is null)))
    or (x.import_id is not null and not x.retired and (not i.desired_present or i.intent_revision<>x.intent_revision)))
  order by i.account_id,i.id limit p_limit+1)
 select coalesce(jsonb_agg(jsonb_build_object('account_id',account_id,'import_id',id) order by account_id,id),'[]'::jsonb) into entries from pending;
 more:=jsonb_array_length(entries)>p_limit;
 if more then entries:=entries-p_limit; end if;
 lastrow:=entries->(jsonb_array_length(entries)-1);
 return jsonb_build_object('entries',entries,'has_more',more,'next_cursor',lastrow);
end $$;
create function public.worker_link_import_acquisition(p_account_id uuid,p_import_id uuid,p_expected_intent_revision bigint,p_expected_state_seq bigint,
 p_lookup_job_id uuid,p_original_job_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare i app_private.import_requests; x app_private.acquisition_interests; l app_private.acquisition_jobs; o app_private.acquisition_jobs; m app_private.catalog_metadata; e jsonb;
begin
 perform app_private.lock_library_account(p_account_id);
 -- Neither linking nor projection acquires global acquisition/paper capacity.
 select * into l from app_private.acquisition_jobs where id=p_lookup_job_id and kind='lookup';
 if not found then raise exception 'acquisition_unavailable'; end if;
 if p_original_job_id is not null then
  select * into o from app_private.acquisition_jobs where id=p_original_job_id and kind='original';
  if not found or o.version_id is distinct from l.version_id or l.eligibility is distinct from 'eligible' then raise exception 'acquisition_source_mismatch'; end if;
  if o.document_id is not null then perform 1 from app_private.documents where id=o.document_id for key share; end if;
 end if;
 perform app_private.lock_library_state(p_account_id);
 select * into i from app_private.import_requests where account_id=p_account_id and id=p_import_id;
 if not found then raise exception 'import_unavailable'; end if;
 select * into x from app_private.acquisition_interests where account_id=p_account_id and import_id=p_import_id;
 if x.import_id is not null and x.intent_revision=p_expected_intent_revision and x.lookup_job_id=p_lookup_job_id
  and x.original_job_id is not distinct from p_original_job_id and not x.retired then return public.worker_import_state(p_account_id,p_import_id); end if;
 if i.intent_revision is distinct from p_expected_intent_revision or i.state_seq is distinct from p_expected_state_seq or not i.desired_present
  or i.phase not in ('accepted','resolving','acquiring') then raise exception 'stale_import_checkpoint'; end if;
 if l.source_id<>i.source_id or (i.requested_revision is not null and coalesce(l.source_revision,l.requested_revision) is distinct from i.requested_revision)
  or (i.metadata_id is not null and l.metadata_id is distinct from i.metadata_id) then raise exception 'acquisition_source_mismatch'; end if;
 if x.intent_revision=i.intent_revision and x.lookup_job_id<>p_lookup_job_id then raise exception 'immutable_import_acquisition'; end if;
 insert into app_private.acquisition_interests(account_id,import_id,intent_revision,lookup_job_id,original_job_id,import_state_seq)
 values(p_account_id,p_import_id,i.intent_revision,p_lookup_job_id,p_original_job_id,i.state_seq)
 on conflict(account_id,import_id) do update set intent_revision=excluded.intent_revision,lookup_job_id=excluded.lookup_job_id,
  original_job_id=excluded.original_job_id,import_state_seq=excluded.import_state_seq,
  projected_lookup_revision=case when app_private.acquisition_interests.intent_revision=excluded.intent_revision then app_private.acquisition_interests.projected_lookup_revision else 0 end,
  projected_original_revision=case when app_private.acquisition_interests.original_job_id=excluded.original_job_id then app_private.acquisition_interests.projected_original_revision else 0 end,retired=false;
 return public.worker_import_state(p_account_id,p_import_id);
end $$;

create function public.worker_claim_acquisition(p_job_id uuid,p_claim_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.acquisition_jobs; p app_private.acquisition_policy; s app_private.acquisition_steps; digest bytea; held integer;
begin
 if p_claim_id is null then raise exception 'invalid_acquisition_claim'; end if;
 select * into strict p from app_private.acquisition_policy;
 select * into j from app_private.acquisition_jobs where id=p_job_id for no key update;
 if not found then raise exception 'acquisition_unavailable'; end if;
 select * into s from app_private.acquisition_steps where job_id=j.id and operation_id=p_claim_id;
 digest:=sha256(convert_to(jsonb_build_array('claim',j.id,p_claim_id)::text,'UTF8'));
 if found then
  if s.request_sha256<>digest or s.kind<>'claim' then raise exception 'operation_id_conflict'; end if;
  return jsonb_build_object('granted',false,'action','reconcile','job',app_private.acquisition_job_entry(j.id),'step_result',s.result);
 end if;
 if (j.kind='lookup' and not p.metadata_enabled) or (j.kind='original' and (not p.original_enabled or not p.verification_enabled or p.active_verification_profile is null)) then
  return jsonb_build_object('granted',false,'action','disabled','job',app_private.acquisition_job_entry(j.id));
 end if;
 if j.status in ('complete','failed','no_interest') then return jsonb_build_object('granted',false,'action','terminal','job',app_private.acquisition_job_entry(j.id)); end if;
 if j.stage='pending_verification' then return jsonb_build_object('granted',false,'action','await_verifier','job',app_private.acquisition_job_entry(j.id)); end if;
 if j.stage in ('atom','license','download') then return jsonb_build_object('granted',false,'action','source_claim_required','job',app_private.acquisition_job_entry(j.id)); end if;
 if j.stage not in ('reserve','publish') then raise exception 'invalid_acquisition_stage'; end if;
 if j.next_attempt_at>clock_timestamp() or (j.hard_deadline is not null and j.hard_deadline>clock_timestamp()) then
  return jsonb_build_object('granted',false,'action','wait','job',app_private.acquisition_job_entry(j.id));
 end if;
 if not app_private.acquisition_has_interest(j.id) then
  return jsonb_build_object('granted',false,'action','no_interest','job',app_private.acquisition_job_entry(j.id));
 end if;
 if j.created_at+make_interval(secs=>p.retry_age_seconds)<=clock_timestamp() then
  select greatest(1,(select count(*) from app_private.acquisition_steps where job_id=j.id)
   +2*(select count(*) from app_private.paper_asset_reservations where job_id=j.id and state not in ('published','deleted'))) into held;
  update app_private.acquisition_jobs set status='failed',error_code=case when kind='lookup' then 'metadata_unavailable' else 'download_failed' end,
   retryable=true,state_revision=state_revision+1,claim_id=null,lease_until=null,slots_held=slots_held where id=j.id;
  return jsonb_build_object('granted',false,'action','terminal','job',app_private.acquisition_job_entry(j.id));
 end if;
 digest:=sha256(convert_to(jsonb_build_array('claim',j.id,p_claim_id)::text,'UTF8'));
 begin
  perform app_private.acquisition_add_step(j.id,p_claim_id,digest,'claim',j.generation+1,j.stage);
 exception when others then
  if sqlerrm<>'acquisition_attempt_limit' then raise; end if;
  update app_private.acquisition_jobs set status='failed',error_code='capacity_exhausted',retryable=false,state_revision=state_revision+1,claim_id=null,lease_until=null where id=j.id;
  return jsonb_build_object('granted',false,'action','terminal','job',app_private.acquisition_job_entry(j.id));
 end;
 update app_private.acquisition_jobs set generation=generation+1,claim_id=p_claim_id,status='leased',state_revision=state_revision+1,
  lease_until=clock_timestamp()+make_interval(secs=>p.stage_lease_seconds),hard_deadline=clock_timestamp()+make_interval(secs=>p.stage_lease_seconds+p.hard_recovery_seconds) where id=j.id;
 return jsonb_build_object('granted',true,'action','perform_stage','job',app_private.acquisition_job_entry(j.id));
end $$;

-- A source stage and its one-use network authority commit together. A gate
-- deferral must not consume retry counts, control headroom, or storage state.
create function public.worker_claim_arxiv_stage(p_job_id uuid,p_claim_id uuid,p_environment text,p_reservation_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.acquisition_jobs; s app_private.acquisition_steps; g app_private.arxiv_network_gate; p app_private.acquisition_policy;
 r app_private.paper_asset_reservations; digest bytea; grant_token uuid; ceiling bigint; used bigint; started timestamptz;
 d date; month date;
begin
 if p_job_id is null or p_claim_id is null or p_environment is null then raise exception 'invalid_acquisition_claim'; end if;
 digest:=sha256(convert_to(jsonb_build_array('arxiv_stage',p_job_id,p_claim_id,p_environment,p_reservation_id)::text,'UTF8'));
 -- kind is immutable; this initial read only selects the lock-order prefix.
 select * into j from app_private.acquisition_jobs where id=p_job_id;
 if not found then raise exception 'acquisition_unavailable'; end if;
 if j.kind='original' then perform 1 from app_private.paper_storage_capacity where singleton for update; end if;
 select * into strict g from app_private.arxiv_network_gate where singleton for update;
 select * into j from app_private.acquisition_jobs where id=p_job_id for no key update;
 if j.kind='original' and p_reservation_id is not null then
  select * into r from app_private.paper_asset_reservations where id=p_reservation_id and job_id=j.id for no key update;
 end if;
 select * into s from app_private.acquisition_steps where job_id=j.id and operation_id=p_claim_id for no key update;
 if found then
  if s.request_sha256<>digest or s.kind<>'arxiv_stage' then raise exception 'operation_id_conflict'; end if;
  return jsonb_build_object('granted',false,'action','reconcile','job',app_private.acquisition_job_entry(j.id),
   'token',s.network_token,'closed',s.network_closed_at is not null,'step_result',s.result);
 end if;
 -- Policy is deliberately read-only here: policy holders can wait for a job.
 select * into strict p from app_private.acquisition_policy;
 if p_environment is distinct from p.gateway_environment then raise exception 'arxiv_outbound_disabled'; end if;
 if not p.metadata_enabled or (j.kind='original' and (not p.original_enabled or not p.verification_enabled or p.active_verification_profile is null)) then
  return jsonb_build_object('granted',false,'action','disabled','job',app_private.acquisition_job_entry(j.id));
 end if;
 if j.status in ('complete','failed','no_interest') then return jsonb_build_object('granted',false,'action','terminal','job',app_private.acquisition_job_entry(j.id)); end if;
 if j.stage not in ('atom','license','download') then raise exception 'invalid_acquisition_stage'; end if;
 if (j.kind='lookup' and (j.stage='download' or p_reservation_id is not null))
  or (j.kind='original' and (j.stage<>'download' or p_reservation_id is null)) then raise exception 'invalid_source_reservation'; end if;
 if j.next_attempt_at>clock_timestamp() or (j.hard_deadline is not null and j.hard_deadline>clock_timestamp()) then
  return jsonb_build_object('granted',false,'action','wait','job',app_private.acquisition_job_entry(j.id),
   'next_allowed_at',greatest(j.next_attempt_at,j.hard_deadline));
 end if;
 if g.token is not null and g.hard_deadline+interval '3 seconds'>clock_timestamp() then
  return jsonb_build_object('granted',false,'action','wait','job',app_private.acquisition_job_entry(j.id),'next_allowed_at',greatest(g.next_allowed_at,g.hard_deadline+interval '3 seconds'));
 end if;
 if g.next_allowed_at>clock_timestamp() then
  return jsonb_build_object('granted',false,'action','wait','job',app_private.acquisition_job_entry(j.id),'next_allowed_at',g.next_allowed_at);
 end if;
 if j.kind='original' then
  if r.id is null or r.job_id<>j.id or r.expires_at<=clock_timestamp() or r.state not in ('reserved','upload_uncertain','uploading') then raise exception 'stale_original_reservation'; end if;
  if r.verification_profile_id is distinct from p.active_verification_profile then return jsonb_build_object('granted',false,'action','disabled','job',app_private.acquisition_job_entry(j.id)); end if;
  if r.state in ('uploading','upload_uncertain') and r.safe_after>clock_timestamp() then
   return jsonb_build_object('granted',false,'action','wait','job',app_private.acquisition_job_entry(j.id),'next_allowed_at',r.safe_after);
  end if;
  ceiling:=r.max_bytes;
 else ceiling:=1048576; end if;
 -- Lock admission/windows before the last interest read, so waiting on a
 -- concurrent transfer cannot make a committed cancellation invisible here.
 perform 1 from app_private.acquisition_transfer_capacity where singleton for update;
 d:=(clock_timestamp() at time zone 'UTC')::date;
 month:=date_trunc('month',clock_timestamp() at time zone 'UTC')::date;
 perform 1 from app_private.acquisition_transfer_windows where scope='environment'
  and ((period=d and kind='source_requests') or (period=month and kind='source_bytes')) order by period,scope,kind for no key update;
 -- A committed kill switch/profile/cap change during admission wait must be
 -- observed before fresh authority. Read-only refresh avoids policy→job cycles.
 select * into strict p from app_private.acquisition_policy;
 if p_environment is distinct from p.gateway_environment then raise exception 'arxiv_outbound_disabled'; end if;
 if not p.metadata_enabled or (j.kind='original' and (not p.original_enabled or not p.verification_enabled
  or p.active_verification_profile is null or r.verification_profile_id is distinct from p.active_verification_profile)) then
  return jsonb_build_object('granted',false,'action','disabled','job',app_private.acquisition_job_entry(j.id));
 end if;
 if j.kind='original' and r.expires_at<=clock_timestamp() then raise exception 'stale_original_reservation'; end if;
 if not app_private.acquisition_has_interest(j.id) then return jsonb_build_object('granted',false,'action','no_interest','job',app_private.acquisition_job_entry(j.id)); end if;
 if j.created_at+make_interval(secs=>p.retry_age_seconds)<=clock_timestamp() or (j.stage='atom' and j.atom_attempts>=3)
  or (j.stage='license' and j.license_attempts>=3) or (j.stage='download' and j.download_attempts>=2) then
  update app_private.acquisition_jobs set status='failed',error_code=case when kind='lookup' then 'metadata_unavailable' else 'download_failed' end,
   retryable=true,state_revision=state_revision+1,claim_id=null,lease_until=null where id=j.id;
  return jsonb_build_object('granted',false,'action','terminal','job',app_private.acquisition_job_entry(j.id));
 end if;
 begin
  perform app_private.acquisition_add_step(j.id,p_claim_id,digest,'arxiv_stage',j.generation+1,j.stage);
 exception when others then
  if sqlerrm<>'acquisition_attempt_limit' then raise; end if;
  update app_private.acquisition_jobs set status='failed',error_code='capacity_exhausted',retryable=false,state_revision=state_revision+1,claim_id=null,lease_until=null where id=j.id;
  return jsonb_build_object('granted',false,'action','terminal','job',app_private.acquisition_job_entry(j.id));
 end;
 insert into app_private.acquisition_transfer_windows(period,scope,kind,charged) values(d,'environment','source_requests',1)
 on conflict(period,scope,kind) do update set charged=app_private.acquisition_transfer_windows.charged+1 returning charged into used;
 if used>p.source_requests_day then raise exception 'arxiv_daily_limit'; end if;
 insert into app_private.acquisition_transfer_windows(period,scope,kind,charged) values(month,'environment','source_bytes',ceiling)
 on conflict(period,scope,kind) do update set charged=app_private.acquisition_transfer_windows.charged+excluded.charged returning charged into used;
 if used>p.source_download_bytes_month then raise exception 'acquisition_source_transfer_limit'; end if;
 started:=clock_timestamp(); grant_token:=gen_random_uuid();
 update app_private.acquisition_jobs set generation=generation+1,claim_id=p_claim_id,status='leased',state_revision=state_revision+1,
  lease_until=started+make_interval(secs=>p.stage_lease_seconds),hard_deadline=started+make_interval(secs=>p.stage_lease_seconds+p.hard_recovery_seconds),
  atom_attempts=atom_attempts+case when stage='atom' then 1 else 0 end,license_attempts=license_attempts+case when stage='license' then 1 else 0 end,
  download_attempts=download_attempts+case when stage='download' then 1 else 0 end where id=j.id returning * into j;
 if j.kind='original' then
  update app_private.paper_asset_reservations set state='uploading',generation=j.generation,safe_after=greatest(safe_after,j.hard_deadline) where id=r.id;
 end if;
 update app_private.acquisition_steps set network_token=grant_token,network_granted_at=started,network_byte_ceiling=ceiling,network_period=month
 where job_id=j.id and operation_id=p_claim_id;
 -- An expired uncertain owner's ceiling remains charged. Only a new atomic
 -- grant can replace its gate after the full hard lifetime plus closure grace.
 update app_private.arxiv_network_gate set token=grant_token,job_id=j.id,operation_id=p_claim_id,generation=generation+1,
  granted_at=started,hard_deadline=started+make_interval(secs=>p.hard_recovery_seconds) where singleton;
 return jsonb_build_object('granted',true,'action','perform_stage','job',app_private.acquisition_job_entry(j.id),'token',grant_token,
  'byte_ceiling',ceiling,'request_deadline',j.lease_until,
  'reservation',case when r.id is not null then app_private.original_reservation_entry(r.id) else null end);
end $$;
-- Retained typed failure for old development callers. Neither this split
-- permit nor the old upload-mark endpoint has an EXECUTE grant.
create function public.worker_begin_arxiv_request(p_job_id uuid,p_claim_id uuid,p_generation bigint,p_environment text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin raise exception 'source_claim_required'; end $$;
create function public.worker_finish_arxiv_request(p_token uuid,p_actual_bytes bigint,p_retry_after_seconds integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare g app_private.arxiv_network_gate; s app_private.acquisition_steps;
begin
 if p_token is null or p_actual_bytes is null or p_actual_bytes<0 or p_retry_after_seconds is null or p_retry_after_seconds not between 0 and 86400 then raise exception 'invalid_arxiv_completion'; end if;
 select * into strict g from app_private.arxiv_network_gate where singleton for update;
 select * into s from app_private.acquisition_steps where network_token=p_token for no key update;
 if not found then raise exception 'arxiv_attempt_unavailable'; end if;
 if s.network_closed_at is not null then
  if s.network_actual_bytes<>p_actual_bytes or s.network_retry_after_seconds is distinct from p_retry_after_seconds then raise exception 'operation_id_conflict'; end if;
  return jsonb_build_object('closed',true,'replayed',true);
 end if;
 if g.token is distinct from p_token or g.hard_deadline<=clock_timestamp() or p_actual_bytes>s.network_byte_ceiling then raise exception 'stale_arxiv_permit'; end if;
 update app_private.acquisition_steps set network_closed_at=clock_timestamp(),network_actual_bytes=p_actual_bytes,network_retry_after_seconds=p_retry_after_seconds where network_token=p_token;
 update app_private.acquisition_transfer_windows set charged=charged-(s.network_byte_ceiling-p_actual_bytes)
 where period=s.network_period and scope='environment' and kind='source_bytes';
 update app_private.arxiv_network_gate set token=null,job_id=null,operation_id=null,
  next_allowed_at=clock_timestamp()+make_interval(secs=>greatest(3,p_retry_after_seconds)) where singleton;
 return jsonb_build_object('closed',true,'replayed',false);
end $$;
create function public.worker_arxiv_request_state(p_job_id uuid,p_claim_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('token',s.network_token,'closed',s.network_closed_at is not null,'granted_at',s.network_granted_at,
  'byte_ceiling',s.network_byte_ceiling,'actual_bytes',s.network_actual_bytes,'active',g.token=s.network_token,
  'next_allowed_at',case when g.token is not null then greatest(g.next_allowed_at,g.hard_deadline+interval '3 seconds') else g.next_allowed_at end)
 from app_private.acquisition_steps s cross join app_private.arxiv_network_gate g
 where s.job_id=p_job_id and s.operation_id=p_claim_id and g.singleton
$$;

create function public.worker_finish_lookup(p_job_id uuid,p_claim_id uuid,p_generation bigint,p_result jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.acquisition_jobs; s app_private.acquisition_steps; slot app_private.acquisition_source_slots; p app_private.acquisition_policy;
 meta uuid; m app_private.catalog_metadata; revision integer; eligible boolean; proof jsonb; published timestamptz; updated timestamptz; license text;
 digest bytea:=sha256(convert_to(p_result::text,'UTF8'));
begin
 if p_result is null or jsonb_typeof(p_result)<>'object' or octet_length(p_result::text)>40960 then raise exception 'invalid_acquisition_result'; end if;
 select * into strict p from app_private.acquisition_policy where singleton for update;
 select * into j from app_private.acquisition_jobs where id=p_job_id and kind='lookup';
 if not found then raise exception 'acquisition_unavailable'; end if;
 select * into slot from app_private.acquisition_source_slots where id=j.source_slot_id for no key update;
 select * into j from app_private.acquisition_jobs where id=p_job_id for no key update;
 select * into s from app_private.acquisition_steps where job_id=p_job_id and operation_id=p_claim_id;
 if s.result_sha256 is not null then
  if s.result->>'input_sha256' is distinct from encode(digest,'hex') then raise exception 'operation_id_conflict'; end if;
  return app_private.acquisition_job_entry(j.id);
 end if;
 if j.status<>'leased' or j.claim_id is distinct from p_claim_id or j.generation is distinct from p_generation or j.lease_until<=clock_timestamp()
  or s.network_closed_at is null or s.generation<>j.generation or j.stage not in ('atom','license') then raise exception 'stale_acquisition_lease'; end if;
 if j.stage='atom' then
  if (p_result-'revision'-'metadata'-'atom_published_at'-'atom_updated_at')<>'{}'::jsonb or jsonb_typeof(p_result->'revision') is distinct from 'number'
   or (p_result->>'revision')!~'^[1-9][0-9]{0,9}$' then raise exception 'invalid_source_metadata'; end if;
  revision:=(p_result->>'revision')::integer;
  if j.requested_revision is not null and j.requested_revision<>revision then raise exception 'acquisition_source_mismatch'; end if;
  if p_result->>'atom_published_at' is not null then published:=(p_result->>'atom_published_at')::timestamptz; end if;
  if p_result->>'atom_updated_at' is not null then updated:=(p_result->>'atom_updated_at')::timestamptz; end if;
  if (p_result->'metadata'->>'published_at') is distinct from to_char(published at time zone 'UTC','YYYY-MM-DD')
   or (p_result->'metadata'->>'updated_at') is distinct from to_char(updated at time zone 'UTC','YYYY-MM-DD') then raise exception 'source_timestamp_mismatch'; end if;
  meta:=public.worker_record_arxiv_metadata(j.source_id,revision,p_result->'metadata');
  select * into strict m from app_private.catalog_metadata where id=meta;
  update app_private.acquisition_jobs set metadata_id=meta,version_id=m.version_id,source_revision=revision,
   atom_published_at=published,atom_updated_at=updated,stage='license',status='queued',state_revision=state_revision+1,
   claim_id=null,lease_until=null,hard_deadline=null,next_attempt_at=clock_timestamp()
   where id=j.id;
 else
  if (p_result-'eligible'-'license_uri'-'evidence'-'reason')<>'{}'::jsonb or jsonb_typeof(p_result->'eligible') is distinct from 'boolean' then raise exception 'invalid_reuse_decision'; end if;
  eligible:=(p_result->>'eligible')::boolean;
  if eligible then
   proof:=p_result->'evidence'; license:=p_result->>'license_uri';
   if license is null or license not in ('https://creativecommons.org/licenses/by/4.0/','https://creativecommons.org/publicdomain/zero/1.0/')
    or jsonb_typeof(proof) is distinct from 'object' or octet_length(proof::text)>4096
    or proof->>'source_id' is distinct from j.source_id or proof->>'source_revision' is distinct from j.source_revision::text
    or proof->>'source_url' is distinct from 'https://arxiv.org/abs/'||j.source_id||'v'||j.source_revision
    or proof->>'license_uri' is distinct from license or proof->>'evidence_format' is distinct from 'arXivRaw'
    or proof->>'evidence_sha256' is null or (proof->>'evidence_sha256')!~'^[0-9a-f]{64}$'
    or proof->>'observed_at' is null or proof->>'latest_version_at' is null
    or j.atom_updated_at is null or (proof->>'latest_version_at')::timestamptz<>j.atom_updated_at
    then raise exception 'reuse_evidence_mismatch'; end if;
   perform (proof->>'observed_at')::timestamptz;
  elsif p_result->>'reason' is null or p_result->>'reason' not in ('revision_unverified','license_unverified','license_not_supported') then raise exception 'invalid_reuse_decision';
  end if;
  update app_private.acquisition_jobs set eligibility=case when eligible then 'eligible' else 'source_only' end,
   license_uri=license,evidence=proof,source_detail=case when not eligible then p_result->>'reason' end,
   stage='complete',status='complete',state_revision=state_revision+1,claim_id=null,lease_until=null,hard_deadline=null,
   slots_held=greatest(1,(select count(*) from app_private.acquisition_steps where job_id=j.id)) where id=j.id;
  if slot.active_job_id=j.id then
   update app_private.acquisition_source_slots set cached_job_id=j.id,fresh_until=clock_timestamp()+make_interval(secs=>p.lookup_fresh_seconds)
   where id=slot.id;
  end if;
 end if;
 perform app_private.acquisition_finish_step(j.id,p_claim_id,jsonb_build_object('input_sha256',encode(digest,'hex'),'job_id',j.id));
 return app_private.acquisition_job_entry(j.id);
end $$;

create function public.worker_fail_acquisition(p_job_id uuid,p_claim_id uuid,p_generation bigint,p_error_code text,p_retryable boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.acquisition_jobs; s app_private.acquisition_steps; result jsonb;
 retry boolean; count_steps integer; cleanup integer; wait_until timestamptz;
begin
 if p_error_code is null or p_error_code not in ('metadata_unavailable','source_not_found','invalid_source_metadata','rate_limited','download_failed','pdf_invalid','verification_failed','capacity_exhausted')
  or p_retryable is null then raise exception 'invalid_acquisition_error'; end if;
 result:=jsonb_build_object('error_code',p_error_code,'retryable',p_retryable);
 select * into j from app_private.acquisition_jobs where id=p_job_id for no key update;
 if not found then raise exception 'acquisition_unavailable'; end if;
 select * into s from app_private.acquisition_steps where job_id=p_job_id and operation_id=p_claim_id;
 if s.result_sha256 is not null then
  if s.result<>result then raise exception 'operation_id_conflict'; end if;
  return app_private.acquisition_job_entry(j.id);
 end if;
 if j.status<>'leased' or j.claim_id is distinct from p_claim_id or j.generation is distinct from p_generation or j.lease_until<=clock_timestamp() then raise exception 'stale_acquisition_lease'; end if;
 retry:=p_retryable and p_error_code in ('metadata_unavailable','rate_limited','download_failed','capacity_exhausted')
  and case j.stage when 'atom' then j.atom_attempts<3 when 'license' then j.license_attempts<3 when 'download' then j.download_attempts<2 else true end;
 wait_until:=clock_timestamp()+interval '30 seconds';
 if s.network_token is not null and s.network_closed_at is null then wait_until:=greatest(wait_until,j.hard_deadline); end if;
 perform app_private.acquisition_finish_step(j.id,p_claim_id,result,case when s.network_token is not null and s.network_closed_at is null then 'uncertain' else 'failed' end);
 select (select count(*) from app_private.acquisition_steps where job_id=j.id)
  +(select count(*) from app_private.paper_verification_results v join app_private.paper_asset_reservations r on r.id=v.reservation_id where r.job_id=j.id)
  +(select count(*) from app_private.paper_integrity_failures f join app_private.paper_asset_reservations r on r.id=f.reservation_id where r.job_id=j.id) into count_steps;
 select 2*count(*) into cleanup from app_private.paper_asset_reservations where job_id=j.id and state not in ('published','deleted');
 update app_private.acquisition_jobs set status=case when retry then 'retry_wait' else 'failed' end,error_code=p_error_code,retryable=p_retryable,
  state_revision=state_revision+1,claim_id=null,lease_until=null,next_attempt_at=wait_until,
  hard_deadline=case when s.network_token is not null and s.network_closed_at is null then hard_deadline else null end,
  slots_held=slots_held where id=j.id;
 return app_private.acquisition_job_entry(j.id);
end $$;

create function app_private.lock_acquisition_projection_requests(a uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare r app_private.api_rate_rules; w timestamptz; environment_used integer; account_used integer;
begin
 select * into strict r from app_private.api_rate_rules where route='library-write';
 w:=to_timestamp(floor(extract(epoch from now())/r.window_seconds)*r.window_seconds);
 insert into app_private.api_rate_windows values(r.route,'environment',w,0)
 on conflict(route,scope_id,window_start) do update set used=app_private.api_rate_windows.used returning used into environment_used;
 insert into app_private.api_rate_windows values(r.route,a::text,w,0)
 on conflict(route,scope_id,window_start) do update set used=app_private.api_rate_windows.used returning used into account_used;
 return environment_used+1<=floor(r.environment_limit*0.8) and account_used+1<=floor(r.account_limit*0.8);
end $$;
create function public.worker_project_import_acquisition(p_account_id uuid,p_import_id uuid,p_expected_intent_revision bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare i app_private.import_requests; x app_private.acquisition_interests; l app_private.acquisition_jobs; o app_private.acquisition_jobs;
 m app_private.catalog_metadata; phase text; code text; retry boolean; e jsonb;
begin
 -- 010 checkpoint/resolve consumes exactly one request. Acquire its window
 -- locks first, but defer background work before it consumes foreground room.
 if not app_private.lock_acquisition_projection_requests(p_account_id) then
  return public.worker_import_state(p_account_id,p_import_id)||jsonb_build_object('projection_deferred',true);
 end if;
 perform app_private.lock_library_account(p_account_id);
 select * into x from app_private.acquisition_interests where account_id=p_account_id and import_id=p_import_id;
 if not found then raise exception 'acquisition_interest_required'; end if;
 select * into l from app_private.acquisition_jobs where id=x.lookup_job_id;
 select * into o from app_private.acquisition_jobs where id=x.original_job_id;
 perform 1 from app_private.documents where id in (l.document_id,o.document_id) order by id for key share;
 perform app_private.lock_library_state(p_account_id);
 select * into i from app_private.import_requests where account_id=p_account_id and id=p_import_id;
 if p_expected_intent_revision is distinct from x.intent_revision then return public.worker_import_state(p_account_id,p_import_id); end if;
 if x.intent_revision<>i.intent_revision or not i.desired_present or i.phase not in ('accepted','resolving','acquiring') then
  update app_private.acquisition_interests set retired=true where account_id=p_account_id and import_id=p_import_id;
  return public.worker_import_state(p_account_id,p_import_id);
 end if;
 -- Retain both pre-policy job snapshots, including a lookup's approval. A
 -- publication or binding during the wait is picked up by the next scan.
 -- Fresh output reads could require a new document lock after policy.
 if l.state_revision<=x.projected_lookup_revision and coalesce(o.state_revision,0)<=x.projected_original_revision then
  return public.worker_import_state(p_account_id,p_import_id);
 end if;
 if l.status='failed' then
  phase:='failed'; code:=case when l.error_code='rate_limited' then 'rate_limited' when l.error_code='legacy_original_unverified' then 'download_failed' else 'metadata_unavailable' end; retry:=l.retryable;
 elsif l.eligibility='source_only' then phase:='source_only'; code:='license_unverified'; retry:=false;
 elsif o.status='failed' then
  phase:='failed'; code:=case when o.error_code in ('pdf_invalid','verification_failed') then 'pdf_invalid' else 'download_failed' end;
  retry:=o.retryable and code='download_failed';
 elsif o.status='complete' and l.approval_id is not null then
  -- Approval must belong to this lookup's metadata, not merely its version.
  e:=public.worker_resolve_import(p_account_id,p_import_id,i.state_seq,i.intent_revision,l.approval_id);
 else phase:=case when l.eligibility='eligible' then 'acquiring' else 'resolving' end; retry:=false;
 end if;
 if e is null and (i.phase is distinct from phase or i.metadata_id is distinct from coalesce(l.metadata_id,i.metadata_id)
  or i.error_code is distinct from code or i.retryable is distinct from retry) then
  e:=public.worker_checkpoint_import(p_account_id,p_import_id,i.state_seq,i.intent_revision,phase,l.metadata_id,code,retry);
 end if;
 update app_private.acquisition_interests set projected_lookup_revision=l.state_revision,projected_original_revision=coalesce(o.state_revision,0),
  import_state_seq=coalesce((e->>'state_seq')::bigint,i.state_seq) where account_id=p_account_id and import_id=p_import_id;
 return public.worker_import_state(p_account_id,p_import_id);
end $$;

create function app_private.original_reservation_entry(p_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',id,'job_id',job_id,'generation',generation,'path',path,'state',state,'max_bytes',max_bytes,
  'candidate_sha256',encode(candidate_sha256,'hex'),'candidate_bytes',candidate_bytes,'verification_profile_id',verification_profile_id,
  'verification_generation',verification_generation,'verification_attempts',verification_attempts,
  'verification_claim',verification_claim,'verification_execution_deadline',verification_execution_deadline,'verification_lease_until',verification_lease_until,'verification_result_id',verification_result_id,
  'original_object_id',original_object_id,'expires_at',expires_at,'safe_after',safe_after)
 from app_private.paper_asset_reservations where id=p_id
$$;
create function public.worker_original_reservation(p_reservation_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select app_private.original_reservation_entry(p_reservation_id)
$$;
create function public.worker_reserve_original(p_job_id uuid,p_claim_id uuid,p_generation bigint,p_reservation_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.acquisition_jobs; r app_private.paper_asset_reservations; p app_private.acquisition_policy;
 c app_private.paper_storage_capacity; v app_private.paper_verification_profiles; digest bytea; total_bytes bigint; objects bigint; ceiling bigint;
begin
 if p_reservation_id is null then raise exception 'invalid_original_reservation'; end if;
 digest:=sha256(convert_to(jsonb_build_array(p_job_id,p_claim_id,p_generation,p_reservation_id)::text,'UTF8'));
 select * into strict c from app_private.paper_storage_capacity where singleton for update;
 select * into j from app_private.acquisition_jobs where id=p_job_id and kind='original' for no key update;
 if not found then raise exception 'acquisition_unavailable'; end if;
 select * into r from app_private.paper_asset_reservations where id=p_reservation_id;
 if found then
  if r.request_sha256<>digest then raise exception 'operation_id_conflict'; end if;
  return app_private.original_reservation_entry(r.id);
 end if;
 select * into strict p from app_private.acquisition_policy;
 if not p.original_enabled or not p.verification_enabled or p.active_verification_profile is null then raise exception 'original_acquisition_disabled'; end if;
 select * into strict v from app_private.paper_verification_profiles where id=p.active_verification_profile;
 if j.status<>'leased' or j.stage<>'reserve' or j.claim_id is distinct from p_claim_id or j.generation is distinct from p_generation
  or j.lease_until<=clock_timestamp() or j.eligibility is distinct from 'eligible' then raise exception 'stale_acquisition_lease'; end if;
 ceiling:=least(c.input_max_bytes,v.max_bytes);
 select coalesce(sum(byte_count),0),count(*) into total_bytes,objects from app_private.stored_objects where bucket='paper-assets' and state<>'deleted';
 select total_bytes+coalesce(sum(held_bytes),0),objects+count(*) into total_bytes,objects from app_private.paper_asset_reservations where state not in ('published','deleted');
 if total_bytes+ceiling>c.max_bytes or objects+1>c.max_objects then raise exception 'original_storage_capacity'; end if;
 if (select count(*) from app_private.paper_asset_reservations where state in ('reserved','uploading','upload_uncertain','pending_verification','verifying','verified'))>=c.active_reservations
 then raise exception 'original_concurrency_limit'; end if;
 insert into app_private.paper_asset_reservations(id,job_id,operation_id,request_sha256,generation,path,max_bytes,held_bytes,verification_profile_id,expires_at,safe_after)
 values(p_reservation_id,j.id,p_claim_id,digest,j.generation,'originals/'||p_reservation_id||'/original.pdf',ceiling,ceiling,v.id,
  clock_timestamp()+interval '24 hours',j.hard_deadline);
 perform app_private.acquisition_finish_step(j.id,p_claim_id,jsonb_build_object('reservation_id',p_reservation_id));
 update app_private.acquisition_jobs set stage='download',status='queued',state_revision=state_revision+1,
  claim_id=null,lease_until=null,hard_deadline=null,next_attempt_at=clock_timestamp() where id=j.id;
 return app_private.original_reservation_entry(p_reservation_id);
end $$;
create function public.worker_mark_original_uploading(p_reservation_id uuid,p_claim_id uuid,p_generation bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
begin raise exception 'source_claim_required'; end $$;
create function public.worker_record_original_upload(p_reservation_id uuid,p_claim_id uuid,p_generation bigint,p_sha256 bytea,p_byte_count bigint,p_uncertain boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r app_private.paper_asset_reservations; j app_private.acquisition_jobs; s app_private.acquisition_steps; result jsonb;
begin
 if p_sha256 is null or octet_length(p_sha256)<>32 or p_byte_count is null or p_byte_count<1 or p_uncertain is null then raise exception 'invalid_original_upload'; end if;
 result:=jsonb_build_object('reservation_id',p_reservation_id,'sha256',encode(p_sha256,'hex'),'byte_count',p_byte_count,'uncertain',p_uncertain);
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 select * into r from app_private.paper_asset_reservations where id=p_reservation_id;
 if not found then raise exception 'original_reservation_unavailable'; end if;
 select * into j from app_private.acquisition_jobs where id=r.job_id for no key update;
 select * into r from app_private.paper_asset_reservations where id=p_reservation_id for no key update;
 select * into s from app_private.acquisition_steps where job_id=j.id and operation_id=p_claim_id;
 if s.result is not null then
  if s.result<>result then raise exception 'operation_id_conflict'; end if;
  return app_private.original_reservation_entry(r.id);
 end if;
 if j.status<>'leased' or j.stage<>'download' or j.claim_id is distinct from p_claim_id or j.generation is distinct from p_generation
  or j.lease_until<=clock_timestamp() or r.generation<>j.generation or r.state<>'uploading' or p_byte_count>r.max_bytes
  or s.network_token is null or s.network_closed_at is null then raise exception 'stale_acquisition_lease'; end if;
 update app_private.paper_asset_reservations set candidate_sha256=p_sha256,candidate_bytes=p_byte_count,
  state=case when p_uncertain then 'upload_uncertain' else 'pending_verification' end,
  held_bytes=case when p_uncertain then held_bytes else p_byte_count end where id=r.id;
 perform app_private.acquisition_finish_step(j.id,p_claim_id,result,case when p_uncertain then 'uncertain' else 'complete' end);
 update app_private.acquisition_jobs set stage='pending_verification',status='queued',state_revision=state_revision+1,
  claim_id=null,lease_until=null,hard_deadline=null,next_attempt_at=clock_timestamp() where id=j.id;
 return app_private.original_reservation_entry(r.id);
end $$;

-- No login or credential is provisioned. A later deployment must bind an
-- authenticated verifier ingress to this narrow role. Service acquisition
-- callbacks receive no attestation grant, including through PUBLIC.
do $$ begin
 if not exists(select 1 from pg_roles where rolname='science_reader_pdf_verifier') then create role science_reader_pdf_verifier nologin; end if;
end $$;
grant usage on schema public to science_reader_pdf_verifier;
create function app_private.require_verifier_role() returns void language plpgsql security definer set search_path='' as $$
begin
 -- SECURITY DEFINER changes current_user; the exposed caller's SET ROLE / JWT
 -- role is the relevant boundary. Never authorize against current_user here.
 if current_setting('role',true) is distinct from 'science_reader_pdf_verifier' then raise exception 'verifier_authority_required' using errcode='42501'; end if;
end $$;
create function public.worker_original_verification_state(p_reservation_id uuid,p_operation_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.require_verifier_role();
 return jsonb_build_object('reservation',app_private.original_reservation_entry(p_reservation_id),
  'result',(select jsonb_build_object('id',id,'outcome',outcome,'sha256',encode(sha256,'hex'),'byte_count',byte_count,'page_count',page_count,'profile_id',profile_id)
   from app_private.paper_verification_results where reservation_id=p_reservation_id and operation_id=p_operation_id),
  'integrity_failure',(select jsonb_build_object('id',id,'outcome',outcome,'complete_input',complete_input,'observed_sha256',encode(observed_sha256,'hex'),'observed_bytes',observed_bytes)
   from app_private.paper_integrity_failures where reservation_id=p_reservation_id and operation_id=p_operation_id));
end $$;
create function public.worker_claim_original_verification(p_reservation_id uuid,p_claim_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r app_private.paper_asset_reservations; j app_private.acquisition_jobs; v app_private.paper_verification_profiles; p app_private.acquisition_policy;
 digest bytea; used bigint; month date:=date_trunc('month',clock_timestamp() at time zone 'UTC')::date;
begin
 perform app_private.require_verifier_role();
 if p_claim_id is null then raise exception 'invalid_verification_claim'; end if;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 select * into r from app_private.paper_asset_reservations where id=p_reservation_id;
 if not found then raise exception 'original_reservation_unavailable'; end if;
 select * into j from app_private.acquisition_jobs where id=r.job_id for no key update;
 select * into r from app_private.paper_asset_reservations where id=p_reservation_id for no key update;
 if exists(select 1 from app_private.acquisition_steps where job_id=j.id and operation_id=p_claim_id) then
  return jsonb_build_object('granted',false,'action','reconcile','reservation',app_private.original_reservation_entry(r.id));
 end if;
 select * into strict p from app_private.acquisition_policy;
 if not p.verification_enabled or p.active_verification_profile is distinct from r.verification_profile_id then
  return jsonb_build_object('granted',false,'action','disabled');
 end if;
 select * into strict v from app_private.paper_verification_profiles where id=r.verification_profile_id;
 if r.state in ('verified','published','quarantined','deleting','deleted') or j.status in ('failed','no_interest') then
  return jsonb_build_object('granted',false,'action','terminal','reservation',app_private.original_reservation_entry(r.id));
 end if;
 if j.stage<>'pending_verification' or j.next_attempt_at>clock_timestamp() or r.state not in ('pending_verification','upload_uncertain','verifying') or r.candidate_sha256 is null
  or (r.verification_lease_until is not null and r.verification_lease_until>clock_timestamp())
  or (r.state='upload_uncertain' and r.safe_after>clock_timestamp()) then return jsonb_build_object('granted',false,'action','wait'); end if;
 if r.expires_at<=clock_timestamp() or r.verification_attempts>=3 then
  update app_private.paper_asset_reservations set state='quarantined',verification_claim=null,verification_lease_until=null where id=r.id;
  update app_private.acquisition_jobs set status='failed',error_code='verification_failed',retryable=false,state_revision=state_revision+1,
   claim_id=null,lease_until=null where id=j.id;
  return jsonb_build_object('granted',false,'action','terminal','reservation',app_private.original_reservation_entry(r.id));
 end if;
 if not app_private.acquisition_has_interest(j.id) then return jsonb_build_object('granted',false,'action','no_interest'); end if;
 digest:=sha256(convert_to(jsonb_build_array('verify',r.id,p_claim_id)::text,'UTF8'));
 begin
  perform app_private.acquisition_add_step(j.id,p_claim_id,digest,'verify',r.verification_generation+1,'pending_verification');
 exception when others then
  if sqlerrm<>'acquisition_attempt_limit' then raise; end if;
  update app_private.paper_asset_reservations set state='quarantined',verification_claim=null,verification_lease_until=null where id=r.id;
  update app_private.acquisition_jobs set status='failed',error_code='capacity_exhausted',retryable=false,state_revision=state_revision+1,claim_id=null,lease_until=null where id=j.id;
  return jsonb_build_object('granted',false,'action','terminal','reservation',app_private.original_reservation_entry(r.id));
 end;
 insert into app_private.acquisition_transfer_windows(period,scope,kind,charged) values(month,'environment','worker_bytes',r.max_bytes)
 on conflict(period,scope,kind) do update set charged=app_private.acquisition_transfer_windows.charged+excluded.charged returning charged into used;
 if used>p.worker_read_bytes_month then raise exception 'verification_transfer_limit'; end if;
 update app_private.paper_asset_reservations set state='verifying',verification_generation=verification_generation+1,
  verification_attempts=verification_attempts+1,verification_claim=p_claim_id,
  verification_execution_deadline=clock_timestamp()+make_interval(secs=>v.wall_ms::double precision/1000),
  verification_lease_until=clock_timestamp()+make_interval(secs=>v.wall_ms::double precision/1000)+interval '120 seconds'
 where id=r.id;
 return jsonb_build_object('granted',true,'action','verify','reservation',app_private.original_reservation_entry(r.id),
  'profile',jsonb_build_object('id',v.id,'sha256',encode(v.profile_sha256,'hex'),'build_sha256',encode(v.build_sha256,'hex'),'definition',v.definition,
   'max_bytes',v.max_bytes,'max_pages',v.max_pages,'wasm_memory_bytes',v.wasm_memory_bytes,'host_memory_bytes',v.host_memory_bytes,'cpu_ms',v.cpu_ms,'wall_ms',v.wall_ms,'resource_evidence',v.resource_evidence,'host_enforcement_sha256',encode(v.host_enforcement_sha256,'hex')));
end $$;

create function public.worker_record_original_verification(p_reservation_id uuid,p_claim_id uuid,p_generation bigint,p_operation_id uuid,
 p_profile_id uuid,p_build_sha256 bytea,p_outcome text,p_sha256 bytea,p_byte_count bigint,p_page_count integer,p_metrics jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r app_private.paper_asset_reservations; j app_private.acquisition_jobs; v app_private.paper_verification_profiles;
 old app_private.paper_verification_results; p app_private.acquisition_policy; digest bytea; result_id uuid; n integer;
begin
 perform app_private.require_verifier_role();
 if p_operation_id is null or p_outcome is null or p_outcome not in ('verified','malformed','encrypted','unsupported','parser_resource_limit','input_limit','page_limit','resource_limit','time_limit','internal_error')
  or p_sha256 is null or octet_length(p_sha256)<>32 or p_byte_count is null or p_byte_count<1
  or p_metrics is null or jsonb_typeof(p_metrics)<>'object' or octet_length(p_metrics::text)>8192
  or ((p_outcome='verified')<>(p_page_count is not null)) then raise exception 'invalid_verification_result'; end if;
 digest:=sha256(convert_to(jsonb_build_array(p_reservation_id,p_claim_id,p_generation,p_operation_id,p_profile_id,encode(p_build_sha256,'hex'),
  p_outcome,encode(p_sha256,'hex'),p_byte_count,p_page_count,p_metrics)::text,'UTF8'));
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 select * into r from app_private.paper_asset_reservations where id=p_reservation_id;
 if not found then raise exception 'original_reservation_unavailable'; end if;
 select * into j from app_private.acquisition_jobs where id=r.job_id for no key update;
 select * into r from app_private.paper_asset_reservations where id=p_reservation_id for no key update;
 select * into old from app_private.paper_verification_results where reservation_id=r.id and operation_id=p_operation_id;
 if found then
  if old.request_sha256<>digest then raise exception 'operation_id_conflict'; end if;
  return jsonb_build_object('result_id',old.id,'outcome',old.outcome,'replayed',true);
 end if;
 select * into strict p from app_private.acquisition_policy;
 if not p.verification_enabled or p.active_verification_profile is distinct from r.verification_profile_id then raise exception 'verification_disabled'; end if;
 select * into strict v from app_private.paper_verification_profiles where id=r.verification_profile_id;
 if r.state<>'verifying' or r.verification_claim is distinct from p_claim_id or r.verification_generation is distinct from p_generation
  or r.verification_lease_until<=clock_timestamp() or r.verification_profile_id is distinct from p_profile_id
  or v.build_sha256 is distinct from p_build_sha256 or r.candidate_sha256<>p_sha256 or r.candidate_bytes<>p_byte_count
  then raise exception 'stale_verification_claim'; end if;
 if p_byte_count>v.max_bytes or (p_page_count is not null and (p_page_count<1 or p_page_count>v.max_pages)) then raise exception 'verification_profile_limit'; end if;
 if p_outcome='verified' and v.resource_evidence='measured' then
  if (p_metrics-'cpu_ms'-'wall_ms'-'peak_host_bytes'-'wasm_bytes'-'warnings'-'repaired')<>'{}'::jsonb
   or jsonb_typeof(p_metrics->'cpu_ms') is distinct from 'number' or jsonb_typeof(p_metrics->'wall_ms') is distinct from 'number'
   or jsonb_typeof(p_metrics->'peak_host_bytes') is distinct from 'number' or jsonb_typeof(p_metrics->'wasm_bytes') is distinct from 'number'
   or p_metrics->'warnings' is distinct from '0'::jsonb or p_metrics->'repaired' is distinct from 'false'::jsonb
   or (p_metrics->>'cpu_ms')::numeric not between 0 and v.cpu_ms or (p_metrics->>'wall_ms')::numeric not between 0 and v.wall_ms
   or (p_metrics->>'peak_host_bytes')::numeric not between 1 and v.host_memory_bytes
   or (p_metrics->>'wasm_bytes')::numeric not between 1 and v.wasm_memory_bytes then raise exception 'verification_profile_limit'; end if;
 elsif p_outcome='verified' then
  if (p_metrics-'cpu_limit_ms'-'host_memory_limit_bytes'-'wall_ms'-'wasm_bytes'-'warnings'-'repaired'-'host_enforcement_sha256')<>'{}'::jsonb
   or jsonb_typeof(p_metrics->'cpu_limit_ms') is distinct from 'number' or jsonb_typeof(p_metrics->'host_memory_limit_bytes') is distinct from 'number'
   or jsonb_typeof(p_metrics->'wall_ms') is distinct from 'number' or jsonb_typeof(p_metrics->'wasm_bytes') is distinct from 'number'
   or p_metrics->'warnings' is distinct from '0'::jsonb or p_metrics->'repaired' is distinct from 'false'::jsonb
   or p_metrics->>'host_enforcement_sha256' is distinct from encode(v.host_enforcement_sha256,'hex')
   or (p_metrics->>'cpu_limit_ms')::numeric not between 1 and v.cpu_ms
   or (p_metrics->>'host_memory_limit_bytes')::numeric not between 1 and v.host_memory_bytes
   or (p_metrics->>'wall_ms')::numeric not between 0 and v.wall_ms
   or (p_metrics->>'wasm_bytes')::numeric not between 1 and v.wasm_memory_bytes then raise exception 'verification_profile_limit'; end if;
 end if;
 -- A result is another bounded control record within pre-admitted headroom.
 select (select count(*) from app_private.acquisition_steps where job_id=j.id)
  +(select count(*) from app_private.paper_verification_results vr join app_private.paper_asset_reservations rr on rr.id=vr.reservation_id where rr.job_id=j.id)
  +(select count(*) from app_private.paper_integrity_failures f join app_private.paper_asset_reservations rr on rr.id=f.reservation_id where rr.job_id=j.id) into n;
 if n+1+1+2*(select count(*) from app_private.paper_asset_reservations where job_id=j.id and state not in ('published','deleted'))>j.slots_held then raise exception 'acquisition_attempt_limit'; end if;
 result_id:=gen_random_uuid();
 insert into app_private.paper_verification_results(id,reservation_id,generation,profile_id,operation_id,request_sha256,sha256,byte_count,page_count,outcome,verifier_identity,metrics)
 values(result_id,r.id,p_generation,v.id,p_operation_id,digest,p_sha256,p_byte_count,p_page_count,p_outcome,v.verifier_identity,p_metrics);
 update app_private.paper_asset_reservations set verification_result_id=result_id,verification_claim=null,verification_lease_until=null,
  state=case when p_outcome='verified' then 'verified' else 'quarantined' end,held_bytes=p_byte_count where id=r.id;
 perform app_private.acquisition_finish_step(j.id,p_claim_id,jsonb_build_object('verification_result_id',result_id,'outcome',p_outcome));
 update app_private.acquisition_jobs set stage=case when p_outcome='verified' then 'publish' else stage end,
  status=case when p_outcome='verified' then 'queued' else 'failed' end,
  error_code=case when p_outcome<>'verified' then 'verification_failed' end,retryable=false,state_revision=state_revision+1,
  claim_id=null,lease_until=null,hard_deadline=null,next_attempt_at=clock_timestamp() where id=j.id;
 return jsonb_build_object('result_id',result_id,'outcome',p_outcome,'replayed',false);
end $$;
create function public.worker_verification_input_unavailable(p_reservation_id uuid,p_claim_id uuid,p_generation bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r app_private.paper_asset_reservations; j app_private.acquisition_jobs; s app_private.acquisition_steps;
begin
 perform app_private.require_verifier_role();
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 select * into r from app_private.paper_asset_reservations where id=p_reservation_id;
 if not found then raise exception 'original_reservation_unavailable'; end if;
 select * into j from app_private.acquisition_jobs where id=r.job_id for no key update;
 select * into r from app_private.paper_asset_reservations where id=p_reservation_id for no key update;
 select * into s from app_private.acquisition_steps where job_id=j.id and operation_id=p_claim_id;
 if s.result=jsonb_build_object('error_code','input_unavailable') then return app_private.original_reservation_entry(r.id); end if;
 if r.state<>'verifying' or r.verification_claim is distinct from p_claim_id or r.verification_generation is distinct from p_generation
  or r.verification_lease_until<=clock_timestamp() then raise exception 'stale_verification_claim'; end if;
 -- A failed object read is not a PDF verdict and creates no verification row.
 perform app_private.acquisition_finish_step(j.id,p_claim_id,jsonb_build_object('error_code','input_unavailable'),'failed');
 update app_private.paper_asset_reservations set state='pending_verification',verification_claim=null,verification_lease_until=null where id=r.id;
 update app_private.acquisition_jobs set stage='pending_verification',status='retry_wait',state_revision=state_revision+1,error_code='download_failed',retryable=true,
  claim_id=null,lease_until=null,hard_deadline=null,next_attempt_at=clock_timestamp()+interval '30 seconds' where id=j.id;
 return app_private.original_reservation_entry(r.id);
end $$;

create function app_private.mark_paper_availability(p_object_id uuid,p_state text,p_reason text default null) returns bigint
language plpgsql security definer set search_path='' as $$
declare o app_private.stored_objects; old app_private.paper_asset_availability; revision bigint;
begin
 -- Caller already holds paper capacity, then the document FOR UPDATE. This
 -- helper never acquires either lock in reverse from an object/policy lock.
 select * into strict o from app_private.stored_objects where id=p_object_id and bucket='paper-assets';
 if p_state is null or p_state not in ('available','unavailable','quarantined') or (p_state='available' and p_reason is not null)
  or (p_state<>'available' and (p_reason is null or p_reason not in ('missing','checksum_mismatch','temporarily_unavailable','verification_revoked')))
  then raise exception 'invalid_asset_availability'; end if;
 select * into old from app_private.paper_asset_availability where object_id=o.id for no key update;
 -- Every new accepted observation advances revision, including unchanged
 -- state. Older CAS inputs cannot act again after an intervening observation.
 update app_private.paper_storage_capacity set asset_state_seq=asset_state_seq+1 where singleton returning asset_state_seq into revision;
 insert into app_private.paper_asset_availability(object_id,revision,state,reason) values(o.id,revision,p_state,p_reason)
 on conflict(object_id) do update set revision=excluded.revision,state=excluded.state,reason=excluded.reason,checked_at=clock_timestamp();
 insert into app_private.paper_availability_outbox(document_id,target_revision) values(o.document_id,revision)
 on conflict(document_id) do update set target_revision=excluded.target_revision;
 return revision;
end $$;
create function public.worker_publish_original(p_job_id uuid,p_claim_id uuid,p_generation bigint,p_reservation_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.acquisition_jobs; r app_private.paper_asset_reservations; v app_private.paper_verification_results;
 p app_private.acquisition_policy; d app_private.documents; existing app_private.paper_originals; s app_private.acquisition_steps;
 object_id uuid; approval uuid; result jsonb; identity bytea; is_duplicate boolean:=false;
begin
 identity:=sha256(convert_to(jsonb_build_array(p_job_id,p_claim_id,p_generation,p_reservation_id)::text,'UTF8'));
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 select * into r from app_private.paper_asset_reservations where id=p_reservation_id and job_id=p_job_id;
 if not found then raise exception 'original_reservation_unavailable'; end if;
 select * into v from app_private.paper_verification_results where id=r.verification_result_id and outcome='verified';
 if not found then raise exception 'original_verification_required'; end if;
 -- Capacity serializes exact-hash insertions; all document locks precede jobs,
 -- reservations, objects and the catalog policy, including implied FK locks.
 select * into d from app_private.documents where scope='shared_catalog' and sha256=v.sha256 for update;
 select * into j from app_private.acquisition_jobs where id=p_job_id and kind='original' for no key update;
 select * into r from app_private.paper_asset_reservations where id=p_reservation_id for no key update;
 select * into s from app_private.acquisition_steps where job_id=j.id and operation_id=p_claim_id;
 if s.result is not null then
  if s.result->>'publication_sha256' is distinct from encode(identity,'hex') then raise exception 'operation_id_conflict'; end if;
  return app_private.acquisition_job_entry(j.id);
 end if;
 select * into strict p from app_private.acquisition_policy;
 if not p.verification_enabled or p.active_verification_profile is distinct from v.profile_id then raise exception 'verification_disabled'; end if;
 if j.status<>'leased' or j.stage<>'publish' or j.claim_id is distinct from p_claim_id or j.generation is distinct from p_generation
  or j.lease_until<=clock_timestamp() or r.state<>'verified' or r.expires_at<=clock_timestamp()
  or v.sha256<>r.candidate_sha256 or v.byte_count<>r.candidate_bytes or v.reservation_id<>r.id then raise exception 'stale_acquisition_lease'; end if;
 if d.id is null then
  insert into app_private.documents(sha256,scope,reuse_evidence,byte_count,page_count)
  values(v.sha256,'shared_catalog',j.evidence,v.byte_count,v.page_count) returning * into d;
 elsif d.byte_count<>v.byte_count or d.page_count<>v.page_count then raise exception 'document_verification_conflict'; end if;
 select * into existing from app_private.paper_originals where document_id=d.id;
 if exists(select 1 from app_private.catalog_asset_approvals ca where ca.document_id=d.id and ca.metadata_id=j.metadata_id
  and ca.original_object_id is distinct from existing.object_id) then
  -- A 010 approval pins another physical object. Verifying these new bytes
  -- cannot attest its old path. Adoption is a separate, unimplemented lane.
  perform app_private.acquisition_finish_step(j.id,p_claim_id,jsonb_build_object('publication_sha256',encode(identity,'hex'),'error_code','legacy_original_unverified'),'failed');
  update app_private.paper_asset_reservations set state='quarantined' where id=r.id;
  update app_private.acquisition_jobs set status='failed',error_code='legacy_original_unverified',retryable=false,state_revision=state_revision+1,
   claim_id=null,lease_until=null,hard_deadline=null where id=j.id;
  return app_private.acquisition_job_entry(j.id);
 end if;
 if existing.object_id is not null then
  if not exists(select 1 from app_private.stored_objects so join app_private.paper_asset_availability a on a.object_id=so.id
   where so.id=existing.object_id and so.state='verified' and a.state='available' and so.sha256=v.sha256 and so.byte_count=v.byte_count)
   then raise exception 'published_original_unavailable'; end if;
  object_id:=existing.object_id; is_duplicate:=true;
 else
  object_id:=gen_random_uuid();
  insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at)
  values(object_id,'paper-assets',r.path,d.id,'verified',v.sha256,v.byte_count,'application/pdf',clock_timestamp());
  insert into app_private.paper_originals(document_id,object_id,verification_result_id) values(d.id,object_id,v.id);
 end if;
 insert into app_private.version_documents(version_id,document_id) values(j.version_id,d.id) on conflict do nothing;
 approval:=public.worker_approve_arxiv_asset(gen_random_uuid(),j.metadata_id,d.id,object_id,j.license_uri,j.evidence);
 if not is_duplicate then perform app_private.mark_paper_availability(object_id,'available'); end if;
 update app_private.paper_asset_reservations set state=case when is_duplicate then 'quarantined' else 'published' end,
  original_object_id=case when not is_duplicate then object_id end,held_bytes=v.byte_count where id=r.id;
 result:=jsonb_build_object('publication_sha256',encode(identity,'hex'),'document_id',d.id,'original_object_id',object_id,'approval_id',approval);
 perform app_private.acquisition_finish_step(j.id,p_claim_id,result);
 update app_private.acquisition_jobs set document_id=d.id,original_object_id=object_id,approval_id=approval,stage='complete',status='complete',state_revision=state_revision+1,
  claim_id=null,lease_until=null,hard_deadline=null,error_code=null,retryable=false where id=j.id;
 return app_private.acquisition_job_entry(j.id);
end $$;
create function public.worker_bind_lookup_original(p_lookup_job_id uuid,p_original_job_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare l app_private.acquisition_jobs; o app_private.acquisition_jobs; approval uuid;
begin
 select * into o from app_private.acquisition_jobs where id=p_original_job_id and kind='original';
 if not found or o.status<>'complete' or o.document_id is null then raise exception 'original_acquisition_incomplete'; end if;
 perform 1 from app_private.documents where id=o.document_id for key share;
 select * into l from app_private.acquisition_jobs where id=p_lookup_job_id and kind='lookup' for no key update;
 if not found or l.status<>'complete' or l.eligibility is distinct from 'eligible' or l.version_id<>o.version_id then raise exception 'acquisition_source_mismatch'; end if;
 if l.approval_id is not null then return app_private.acquisition_job_entry(l.id); end if;
 if not exists(select 1 from app_private.stored_objects so join app_private.paper_asset_availability a on a.object_id=so.id
  where so.id=o.original_object_id and so.state='verified' and a.state='available') then raise exception 'published_original_unavailable'; end if;
 perform 1 from app_private.library_policy where singleton for update;
 if exists(select 1 from app_private.catalog_asset_approvals ca where ca.document_id=o.document_id and ca.metadata_id=l.metadata_id
  and ca.original_object_id<>o.original_object_id) then
  update app_private.acquisition_jobs set status='failed',error_code='legacy_original_unverified',retryable=false,state_revision=state_revision+1 where id=l.id;
  return app_private.acquisition_job_entry(l.id);
 end if;
 approval:=public.worker_approve_arxiv_asset(gen_random_uuid(),l.metadata_id,o.document_id,o.original_object_id,l.license_uri,l.evidence);
 update app_private.acquisition_jobs set approval_id=approval,document_id=o.document_id,original_object_id=o.original_object_id,state_revision=state_revision+1 where id=l.id;
 return app_private.acquisition_job_entry(l.id);
end $$;

create function app_private.current_library_assets(p_account_id uuid,p_item_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('original_object_id',ca.original_object_id,'artifact_id',li.artifact_id,
  'original_availability',case when ca.id is null or po.object_id is null then 'unverified' when so.state<>'verified' then 'unavailable' else coalesce(a.state,'unverified') end,
  'original_availability_revision',coalesce(a.revision,0),
  'render_availability',case when li.artifact_id is null then 'not_converted' when not (ra.renderer_version=any(lp.compatible_renderers)) then 'incompatible'
   when ro.state<>'verified' or ma.state='unavailable' then 'unavailable' when ma.state='quarantined' then 'quarantined' else 'unverified' end,
  'render_availability_revision',coalesce(ma.revision,0))
 from app_private.library_items li left join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
 left join app_private.stored_objects so on so.id=ca.original_object_id left join app_private.paper_originals po on po.object_id=so.id
 left join app_private.paper_asset_availability a on a.object_id=so.id
 left join app_private.render_artifacts ra on ra.id=li.artifact_id left join app_private.stored_objects ro on ro.id=ra.manifest_object_id
 left join app_private.paper_asset_availability ma on ma.object_id=ro.id cross join app_private.library_policy lp
 where li.account_id=p_account_id and li.id=p_item_id and lp.singleton
$$;
create function app_private.write_library_assets(p_account_id uuid,p_item_id uuid,p_value jsonb) returns void
language plpgsql security definer set search_path='' as $$
begin
 insert into app_private.library_asset_projection(account_id,item_id,document_id,original_object_id,artifact_id,original_availability,render_availability,
  original_availability_revision,render_availability_revision)
 select li.account_id,li.id,li.document_id,(p_value->>'original_object_id')::uuid,(p_value->>'artifact_id')::uuid,
  p_value->>'original_availability',p_value->>'render_availability',(p_value->>'original_availability_revision')::bigint,(p_value->>'render_availability_revision')::bigint
 from app_private.library_items li where li.account_id=p_account_id and li.id=p_item_id
 on conflict(account_id,item_id) do update set original_object_id=excluded.original_object_id,artifact_id=excluded.artifact_id,
  original_availability=excluded.original_availability,render_availability=excluded.render_availability,
  original_availability_revision=excluded.original_availability_revision,render_availability_revision=excluded.render_availability_revision;
end $$;
create function app_private.initialize_library_assets() returns trigger language plpgsql security definer set search_path='' as $$
begin
 -- 010 membership writers already hold account -> document KEY SHARE -> policy.
 -- Pins change together with their library sequence, never through this hook.
 perform app_private.write_library_assets(new.account_id,new.id,app_private.current_library_assets(new.account_id,new.id));
 return new;
end $$;
create trigger library_asset_projection_on_pin after insert or update of approval_id,artifact_id on app_private.library_items
 for each row execute function app_private.initialize_library_assets();
create or replace function app_private.library_item_entry(a uuid,p_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('kind','item','id',li.id,'document_id',li.document_id,'created_seq',li.created_seq,'state_seq',li.state_seq,
  'membership_revision',li.membership_revision,'visible',li.removed_at is null,'added_at',li.added_at,
  'last_remove_seq',li.last_remove_seq,'approval_id',li.approval_id,'version_id',ca.version_id,'metadata_id',cm.id,
  'source',case when cm.id is not null then 'arxiv' end,'source_id',cm.source_id,'source_revision',cm.source_revision,
  'metadata',cm.metadata,'metadata_recorded_at',cm.recorded_at,'source_url',case when cm.id is not null then 'https://arxiv.org/abs/'||cm.source_id||'v'||cm.source_revision end,
  'scope',d.scope,'page_count',d.page_count,'original_object_id',ca.original_object_id,'artifact_id',li.artifact_id,
  'original_availability',coalesce(ap.original_availability,'unverified'),'render_availability',coalesce(ap.render_availability,'unverified'),
  'original_availability_revision',coalesce(ap.original_availability_revision,0),'render_availability_revision',coalesce(ap.render_availability_revision,0),
  'readiness',case when ap.render_availability='available' then 'converted_ready' when ap.original_availability='available' then 'pdf_ready'
   when ca.id is not null or li.artifact_id is not null then 'unavailable' else 'unverified' end)
 from app_private.library_items li join app_private.documents d on d.id=li.document_id
 left join app_private.catalog_asset_approvals ca on ca.id=li.approval_id left join app_private.catalog_metadata cm on cm.id=ca.metadata_id
 left join app_private.library_asset_projection ap on (ap.account_id,ap.item_id)=(li.account_id,li.id) where li.account_id=a and li.id=p_id
$$;
create function public.worker_project_library_availability(p_account_id uuid,p_item_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare li app_private.library_items; p app_private.library_asset_projection; current_value jsonb; previous jsonb; s bigint;
begin
 perform 1 from app_private.accounts where id=p_account_id for no key update;
 if not found then raise exception 'account_unavailable'; end if;
 select * into li from app_private.library_items where account_id=p_account_id and id=p_item_id;
 if not found then raise exception 'library_item_unavailable'; end if;
 perform 1 from app_private.documents where id=li.document_id for key share;
 perform app_private.lock_library_state(p_account_id);
 select * into p from app_private.library_asset_projection where account_id=p_account_id and item_id=p_item_id;
 previous:=jsonb_build_object('original_object_id',p.original_object_id,'artifact_id',p.artifact_id,'original_availability',p.original_availability,
  'render_availability',p.render_availability,'original_availability_revision',p.original_availability_revision,'render_availability_revision',p.render_availability_revision);
 current_value:=app_private.current_library_assets(p_account_id,p_item_id);
 if current_value is distinct from previous then
  s:=app_private.library_next_seq(p_account_id);
  perform app_private.write_library_assets(p_account_id,p_item_id,current_value);
  update app_private.library_items set state_seq=s where account_id=p_account_id and id=p_item_id;
  perform app_private.library_emit(p_account_id,s,jsonb_build_array(app_private.library_item_entry(p_account_id,p_item_id)));
 end if;
 return app_private.library_item_entry(p_account_id,p_item_id);
end $$;

create function public.worker_set_original_availability(p_operation_id uuid,p_object_id uuid,p_expected_revision bigint,p_state text,p_reason text,
 p_observed_sha256 bytea default null,p_observed_bytes bigint default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o app_private.stored_objects; a app_private.paper_asset_availability; digest bytea; revision bigint;
begin
 if p_operation_id is null or p_expected_revision is null or p_expected_revision<1 then raise exception 'invalid_asset_observation'; end if;
 digest:=sha256(convert_to(jsonb_build_array(p_object_id,p_expected_revision,p_state,p_reason,encode(p_observed_sha256,'hex'),p_observed_bytes)::text,'UTF8'));
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 select * into o from app_private.stored_objects where id=p_object_id and bucket='paper-assets';
 if not found or not exists(select 1 from app_private.paper_originals where object_id=o.id) then raise exception 'published_original_required'; end if;
 perform 1 from app_private.documents where id=o.document_id for update;
 select * into a from app_private.paper_asset_availability where object_id=o.id for no key update;
 if a.last_operation_id=p_operation_id then
  if a.last_request_sha256<>digest then raise exception 'operation_id_conflict'; end if;
  return jsonb_build_object('state',a.state,'revision',a.revision,'replayed',true);
 end if;
 if a.revision is distinct from p_expected_revision then return jsonb_build_object('status','revision_conflict','state',a.state,'revision',a.revision); end if;
 if p_state='available' and (o.state<>'verified' or o.sha256 is distinct from p_observed_sha256 or o.byte_count is distinct from p_observed_bytes) then
  raise exception 'original_probe_required';
 end if;
 revision:=app_private.mark_paper_availability(o.id,p_state,p_reason);
 update app_private.paper_asset_availability set last_operation_id=p_operation_id,last_request_sha256=digest where object_id=o.id;
 return jsonb_build_object('state',p_state,'revision',revision,'replayed',false);
end $$;
create function public.worker_claim_asset_projection(p_document_id uuid,p_claim_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o app_private.paper_availability_outbox;
begin
 if p_claim_id is null then raise exception 'invalid_projection_claim'; end if;
 select * into o from app_private.paper_availability_outbox where document_id=p_document_id for no key update;
 if not found then return null; end if;
 if o.claim_id=p_claim_id then return jsonb_build_object('granted',false,'action','reconcile','document_id',o.document_id,'generation',o.generation,'pass_revision',o.pass_revision,'after_account',o.after_account,'after_item',o.after_item); end if;
 if o.lease_until>clock_timestamp() then return jsonb_build_object('granted',false,'action','wait'); end if;
 update app_private.paper_availability_outbox set claim_id=p_claim_id,generation=generation+1,lease_until=clock_timestamp()+interval '60 seconds',
  pass_revision=coalesce(pass_revision,target_revision) where document_id=p_document_id returning * into o;
 return jsonb_build_object('granted',true,'document_id',o.document_id,'generation',o.generation,'pass_revision',o.pass_revision,'after_account',o.after_account,'after_item',o.after_item);
end $$;
create function public.worker_asset_projection_page(p_document_id uuid,p_claim_id uuid,p_generation bigint,p_limit integer default 50) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare o app_private.paper_availability_outbox; entries jsonb; more boolean;
begin
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'invalid_projection_limit'; end if;
 select * into o from app_private.paper_availability_outbox where document_id=p_document_id;
 if not found or o.claim_id is distinct from p_claim_id or o.generation is distinct from p_generation or o.lease_until<=clock_timestamp() then raise exception 'stale_projection_claim'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('account_id',account_id,'item_id',id) order by account_id,id),'[]'::jsonb) into entries from
  (select li.account_id,li.id from app_private.library_items li where li.document_id=p_document_id
   and (o.after_account is null or (li.account_id,li.id)>(o.after_account,o.after_item)) order by li.account_id,li.id limit p_limit+1) page;
 more:=jsonb_array_length(entries)>p_limit; if more then entries:=entries-p_limit; end if;
 return jsonb_build_object('entries',entries,'has_more',more,'pass_revision',o.pass_revision,'target_revision',o.target_revision);
end $$;
create function public.worker_ack_asset_projection(p_document_id uuid,p_claim_id uuid,p_generation bigint,p_account_id uuid default null,p_item_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o app_private.paper_availability_outbox; candidate record; p app_private.library_asset_projection; live jsonb;
begin
 if (p_account_id is null)<>(p_item_id is null) then raise exception 'invalid_projection_ack'; end if;
 select * into o from app_private.paper_availability_outbox where document_id=p_document_id for no key update;
 if not found then return jsonb_build_object('complete',true); end if;
 if o.claim_id is distinct from p_claim_id or o.generation is distinct from p_generation or o.lease_until<=clock_timestamp() then raise exception 'stale_projection_claim'; end if;
 select li.account_id,li.id into candidate from app_private.library_items li where li.document_id=p_document_id
  and (o.after_account is null or (li.account_id,li.id)>(o.after_account,o.after_item)) order by li.account_id,li.id limit 1;
 if not found then
  if p_account_id is not null then raise exception 'invalid_projection_ack'; end if;
  if o.target_revision=o.pass_revision then delete from app_private.paper_availability_outbox where document_id=p_document_id; return jsonb_build_object('complete',true); end if;
  update app_private.paper_availability_outbox set pass_revision=target_revision,after_account=null,after_item=null,claim_id=null,lease_until=null where document_id=p_document_id;
  return jsonb_build_object('complete',false,'restart',true);
 end if;
 if (p_account_id,p_item_id) is distinct from (candidate.account_id,candidate.id) then raise exception 'projection_ack_out_of_order'; end if;
 -- No account locks are taken while holding outbox. Verify the committed
 -- projection by read; publication serializes behind this outbox lock and
 -- will dirty a later pass if it changes after the check.
 select * into p from app_private.library_asset_projection where account_id=p_account_id and item_id=p_item_id;
 live:=app_private.current_library_assets(p_account_id,p_item_id);
 if p.item_id is null or live is distinct from jsonb_build_object('original_object_id',p.original_object_id,'artifact_id',p.artifact_id,
  'original_availability',p.original_availability,'render_availability',p.render_availability,
  'original_availability_revision',p.original_availability_revision,'render_availability_revision',p.render_availability_revision)
 then raise exception 'projection_not_committed'; end if;
 update app_private.paper_availability_outbox set after_account=p_account_id,after_item=p_item_id where document_id=p_document_id;
 return jsonb_build_object('complete',false,'after_account',p_account_id,'after_item',p_item_id);
end $$;

create function public.worker_claim_original_orphans(p_limit integer default 20) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r app_private.paper_asset_reservations; j app_private.acquisition_jobs; result jsonb:='[]'; deletion uuid; digest bytea;
begin
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'invalid_orphan_limit'; end if;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 for r in select * from app_private.paper_asset_reservations where original_object_id is null and state not in ('published','deleted')
  and (state in ('quarantined','deleting') or expires_at<=clock_timestamp()) and safe_after<=clock_timestamp()
  and (deletion_lease_until is null or deletion_lease_until<=clock_timestamp()) order by job_id,id limit p_limit loop
  select * into j from app_private.acquisition_jobs where id=r.job_id for no key update;
  perform 1 from app_private.paper_asset_reservations where id=r.id for no key update;
  if exists(select 1 from app_private.stored_objects where path=r.path and state<>'deleted') then continue; end if;
  deletion:=coalesce(r.deletion_operation_id,gen_random_uuid());
  if r.deletion_operation_id is null then
   digest:=sha256(convert_to(jsonb_build_array('delete',r.id)::text,'UTF8'));
   perform app_private.acquisition_add_step(j.id,deletion,digest,'orphan_delete',j.generation,'cleanup',true);
  end if;
  if j.status in ('queued','leased','retry_wait','blocked') and j.original_object_id is null and not exists(select 1 from app_private.paper_asset_reservations r2 where r2.job_id=j.id and r2.id<>r.id and r2.state not in ('quarantined','deleting','deleted')) then
   update app_private.acquisition_jobs set status='failed',error_code='download_failed',retryable=true,generation=generation+1,
    state_revision=state_revision+1,claim_id=null,lease_until=null,hard_deadline=null where id=j.id;
  end if;
  update app_private.paper_asset_reservations set state='deleting',deletion_operation_id=deletion,deletion_generation=deletion_generation+1,
   deletion_lease_until=clock_timestamp()+interval '120 seconds',verification_claim=null,verification_lease_until=null where id=r.id returning * into r;
  result:=result||jsonb_build_array(jsonb_build_object('id',r.id,'path',r.path,'deletion_operation_id',deletion,'deletion_generation',r.deletion_generation));
 end loop;
 return result;
end $$;
create function public.worker_confirm_original_deleted(p_reservation_id uuid,p_operation_id uuid,p_generation bigint,p_absent boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r app_private.paper_asset_reservations; j app_private.acquisition_jobs; n integer;
begin
 if p_absent is distinct from true then raise exception 'storage_absence_required'; end if;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 select * into r from app_private.paper_asset_reservations where id=p_reservation_id;
 if not found then raise exception 'original_reservation_unavailable'; end if;
 select * into j from app_private.acquisition_jobs where id=r.job_id for no key update;
 select * into r from app_private.paper_asset_reservations where id=p_reservation_id for no key update;
 if r.deletion_operation_id is distinct from p_operation_id or r.deletion_generation is distinct from p_generation then raise exception 'stale_orphan_claim'; end if;
 if r.state='deleted' then return jsonb_build_object('deleted',true,'replayed',true); end if;
 if r.state<>'deleting' or r.deletion_lease_until<=clock_timestamp() or r.original_object_id is not null
  or exists(select 1 from app_private.stored_objects where path=r.path and state<>'deleted') then raise exception 'stale_orphan_claim'; end if;
 perform app_private.acquisition_finish_step(j.id,p_operation_id,jsonb_build_object('deleted',true,'reservation_id',r.id,'generation',p_generation));
 update app_private.paper_asset_reservations set state='deleted',held_bytes=0,deleted_at=clock_timestamp(),deletion_lease_until=null where id=r.id;
 return jsonb_build_object('deleted',true,'replayed',false);
end $$;


-- Integrity failures bind the expected candidate plus truthful observed facts.
-- A prefix/oversized read never masquerades as a complete-object digest.
create table app_private.paper_integrity_failures (
 id uuid primary key, reservation_id uuid not null references app_private.paper_asset_reservations(id),
 operation_id uuid not null, request_sha256 bytea not null check(octet_length(request_sha256)=32),
 generation bigint not null, profile_id uuid not null references app_private.paper_verification_profiles(id),
 expected_sha256 bytea not null check(octet_length(expected_sha256)=32), expected_bytes bigint not null,
 outcome text not null check(outcome in ('binding_mismatch','input_limit')),
 complete_input boolean not null, observed_sha256 bytea, observed_bytes bigint not null check(observed_bytes between 0 and 33554433),
 created_at timestamptz not null default now(), unique(reservation_id,operation_id),
 check((complete_input and observed_sha256 is not null and octet_length(observed_sha256)=32) or (not complete_input and observed_sha256 is null)),
 check(outcome<>'binding_mismatch' or (complete_input and (observed_sha256<>expected_sha256 or observed_bytes<>expected_bytes)))
);
create trigger paper_integrity_failure_immutable before update or delete on app_private.paper_integrity_failures
 for each row execute function app_private.immutable_record();
create function public.worker_record_original_integrity_failure(p_reservation_id uuid,p_claim_id uuid,p_generation bigint,p_operation_id uuid,
 p_profile_id uuid,p_build_sha256 bytea,p_expected_sha256 bytea,p_expected_bytes bigint,p_outcome text,p_complete_input boolean,
 p_observed_sha256 bytea,p_observed_bytes bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare r app_private.paper_asset_reservations; j app_private.acquisition_jobs; v app_private.paper_verification_profiles;
 old app_private.paper_integrity_failures; digest bytea; result_id uuid; n integer;
begin
 perform app_private.require_verifier_role();
 if p_operation_id is null or p_outcome is null or p_outcome not in ('binding_mismatch','input_limit') or p_complete_input is null
  or p_observed_bytes is null or p_observed_bytes not between 0 and 33554433
  or (p_complete_input and (p_observed_sha256 is null or octet_length(p_observed_sha256)<>32))
  or (not p_complete_input and p_observed_sha256 is not null)
  or (p_outcome='binding_mismatch' and (not p_complete_input or (p_observed_sha256,p_observed_bytes) is not distinct from (p_expected_sha256,p_expected_bytes)))
  then raise exception 'invalid_integrity_result'; end if;
 digest:=sha256(convert_to(jsonb_build_array(p_reservation_id,p_claim_id,p_generation,p_operation_id,p_profile_id,encode(p_build_sha256,'hex'),
  encode(p_expected_sha256,'hex'),p_expected_bytes,p_outcome,p_complete_input,encode(p_observed_sha256,'hex'),p_observed_bytes)::text,'UTF8'));
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 select * into r from app_private.paper_asset_reservations where id=p_reservation_id;
 if not found then raise exception 'original_reservation_unavailable'; end if;
 select * into j from app_private.acquisition_jobs where id=r.job_id for no key update;
 select * into r from app_private.paper_asset_reservations where id=p_reservation_id for no key update;
 select * into old from app_private.paper_integrity_failures where reservation_id=r.id and operation_id=p_operation_id;
 if found then
  if old.request_sha256<>digest then raise exception 'operation_id_conflict'; end if;
  return jsonb_build_object('result_id',old.id,'outcome',old.outcome,'replayed',true);
 end if;
 select * into strict v from app_private.paper_verification_profiles where id=r.verification_profile_id;
 if not exists(select 1 from app_private.acquisition_policy where singleton and verification_enabled and active_verification_profile=v.id)
 then raise exception 'verification_disabled'; end if;
 if r.state<>'verifying' or r.verification_claim is distinct from p_claim_id or r.verification_generation is distinct from p_generation
  or r.verification_lease_until<=clock_timestamp() or v.id is distinct from p_profile_id or v.build_sha256 is distinct from p_build_sha256
  or r.candidate_sha256 is distinct from p_expected_sha256 or r.candidate_bytes is distinct from p_expected_bytes then raise exception 'stale_verification_claim'; end if;
 if p_outcome='input_limit' and p_observed_bytes<=v.max_bytes then raise exception 'invalid_integrity_result'; end if;
 select (select count(*) from app_private.acquisition_steps where job_id=j.id)
  +(select count(*) from app_private.paper_verification_results f join app_private.paper_asset_reservations rr on rr.id=f.reservation_id where rr.job_id=j.id)
  +(select count(*) from app_private.paper_integrity_failures f join app_private.paper_asset_reservations rr on rr.id=f.reservation_id where rr.job_id=j.id) into n;
 if n+1+2*(select count(*) from app_private.paper_asset_reservations where job_id=j.id and state not in ('published','deleted'))>j.slots_held
 then raise exception 'acquisition_attempt_limit'; end if;
 result_id:=gen_random_uuid();
 insert into app_private.paper_integrity_failures(id,reservation_id,operation_id,request_sha256,generation,profile_id,expected_sha256,expected_bytes,
  outcome,complete_input,observed_sha256,observed_bytes) values(result_id,r.id,p_operation_id,digest,p_generation,v.id,p_expected_sha256,p_expected_bytes,
  p_outcome,p_complete_input,p_observed_sha256,p_observed_bytes);
 perform app_private.acquisition_finish_step(j.id,p_claim_id,jsonb_build_object('integrity_failure_id',result_id,'outcome',p_outcome),'failed');
 update app_private.paper_asset_reservations set state='quarantined',verification_claim=null,verification_lease_until=null,held_bytes=max_bytes where id=r.id;
 update app_private.acquisition_jobs set status='failed',error_code='verification_failed',retryable=false,state_revision=state_revision+1,
  claim_id=null,lease_until=null,hard_deadline=null where id=j.id;
 return jsonb_build_object('result_id',result_id,'outcome',p_outcome,'replayed',false);
end $$;

-- Small global row envelopes are explicit and fail closed. Historical transfer
-- charges are retained; a separately reviewed archive may later compact them.
create table app_private.acquisition_transfer_capacity(singleton boolean primary key default true check(singleton), max_rows integer not null default 10000 check(max_rows>0));
insert into app_private.acquisition_transfer_capacity(singleton) values(true);
create function app_private.bound_acquisition_records() returns trigger language plpgsql set search_path='' as $$
declare cap integer; p app_private.acquisition_policy; held bigint; jobs bigint; commands bigint;
begin
 if TG_TABLE_NAME='acquisition_transfer_windows' then
  select max_rows into strict cap from app_private.acquisition_transfer_capacity where singleton for update;
  if not exists(select 1 from app_private.acquisition_transfer_windows where (period,scope,kind)=(new.period,new.scope,new.kind))
   and (select count(*) from app_private.acquisition_transfer_windows)>=cap then raise exception 'acquisition_transfer_row_limit'; end if;
 else
  select * into strict p from app_private.acquisition_policy where singleton for update;
  if (select count(*) from app_private.paper_verification_profiles)>=32 then raise exception 'verification_profile_limit'; end if;
  select count(*),coalesce(sum(slots_held),0) into jobs,held from app_private.acquisition_jobs;
  select count(*) into commands from app_private.acquisition_commands;
  if (jobs+held+commands+2*((select count(*) from app_private.paper_verification_profiles)+1))*8192>p.control_bytes then raise exception 'acquisition_control_capacity'; end if;
 end if;
 return new;
end $$;
create trigger transfer_row_bound before insert on app_private.acquisition_transfer_windows for each row execute function app_private.bound_acquisition_records();
create trigger verification_profile_bound before insert on app_private.paper_verification_profiles for each row execute function app_private.bound_acquisition_records();

-- Original reads use a service-owned proxy, not reusable unmetered signed URLs.
-- Descriptor is customer-safe; storage paths leave SQL only for the trusted
-- proxy after one-use authority and worst-case transfer charge commit.
create table app_private.paper_read_policy (
 singleton boolean primary key default true check(singleton), enabled boolean not null default false,
 environment_daily integer not null default 1000 check(environment_daily>0 and environment_daily<=1000),
 account_daily integer not null default 100 check(account_daily>0 and account_daily<=100)
);
insert into app_private.paper_read_policy(singleton) values(true);
create table app_private.paper_read_grants (
 day date not null, account_id uuid not null references app_private.accounts(id) on delete cascade, operation_id uuid not null,
 request_sha256 bytea not null check(octet_length(request_sha256)=32), item_id uuid not null,
 object_id uuid not null references app_private.stored_objects(id), first_byte bigint not null, last_byte bigint not null,
 byte_ceiling bigint not null check(byte_ceiling>0 and byte_ceiling<=5242880), expires_at timestamptz not null,
 primary key(day,account_id,operation_id), check(first_byte>=0 and last_byte>=first_byte and byte_ceiling=last_byte-first_byte+1)
);
create function app_private.original_descriptor(a uuid,i uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('item_id',li.id,'document_id',li.document_id,'approval_id',ca.id,'object_id',so.id,
  'sha256',encode(so.sha256,'hex'),'byte_count',so.byte_count,'media_type',so.media_type,'page_count',d.page_count,
  'verification_profile_id',vr.profile_id,'availability_revision',av.revision,
  'read_day',(clock_timestamp() at time zone 'UTC')::date,'read_transport','bounded_proxy')
 from app_private.library_items li join app_private.accounts a0 on a0.id=li.account_id and a0.closed_at is null
 join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
 join app_private.documents d on d.id=li.document_id
 join app_private.paper_originals po on po.document_id=d.id and po.object_id=ca.original_object_id
 join app_private.paper_verification_results vr on vr.id=po.verification_result_id and vr.outcome='verified'
 join app_private.stored_objects so on so.id=po.object_id and so.state='verified'
 join app_private.paper_asset_availability av on av.object_id=so.id and av.state='available'
 where li.account_id=a and li.id=i and li.removed_at is null
$$;
create function public.v2_original_descriptor(p_item_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a uuid:=auth.uid(); result jsonb;
begin
 if a is null then raise exception 'authentication_required' using errcode='42501'; end if;
 result:=app_private.original_descriptor(a,p_item_id);
 if result is null then raise exception 'original_unavailable'; end if;
 return result;
end $$;
create function public.worker_authorize_original_read(p_account_id uuid,p_item_id uuid,p_operation_id uuid,p_day date,
 p_first_byte bigint default 0,p_last_byte bigint default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare r app_private.paper_read_grants; p app_private.paper_read_policy; ap app_private.acquisition_policy; li app_private.library_items;
 descriptor jsonb; digest bytea; object uuid; bytes bigint; ceiling bigint; used bigint; expires timestamptz;
 today date:=(clock_timestamp() at time zone 'UTC')::date; month date:=date_trunc('month',clock_timestamp() at time zone 'UTC')::date;
begin
 if p_operation_id is null or p_day is null or p_first_byte is null or p_first_byte<0 or (p_last_byte is not null and p_last_byte<p_first_byte) then raise exception 'invalid_original_read'; end if;
 digest:=sha256(convert_to(jsonb_build_array(p_item_id,p_day,p_first_byte,p_last_byte)::text,'UTF8'));
 -- Read policy -> account -> document -> transfer-capacity/windows; never
 -- acquire paper capacity, acquisition jobs, or library policy on this route.
 select * into strict p from app_private.paper_read_policy where singleton for update;
 perform app_private.lock_library_account(p_account_id);
 select * into r from app_private.paper_read_grants where (day,account_id,operation_id)=(p_day,p_account_id,p_operation_id);
 if found then
  if r.request_sha256<>digest then raise exception 'operation_id_conflict'; end if;
  return jsonb_build_object('granted',false,'action','reconcile','expires_at',r.expires_at);
 end if;
 if p_day<>today then raise exception 'original_read_day_expired'; end if;
 if not p.enabled then return jsonb_build_object('granted',false,'action','disabled'); end if;
 delete from app_private.paper_read_grants where day<today-1;
 if (select count(*) from app_private.paper_read_grants where day=today)>=p.environment_daily
  or (select count(*) from app_private.paper_read_grants where day=today and account_id=p_account_id)>=p.account_daily then raise exception 'original_read_receipt_limit'; end if;
 select * into li from app_private.library_items where account_id=p_account_id and id=p_item_id and removed_at is null;
 if not found then raise exception 'original_unavailable'; end if;
 perform 1 from app_private.documents where id=li.document_id for key share;
 descriptor:=app_private.original_descriptor(p_account_id,p_item_id);
 if descriptor is null then raise exception 'original_unavailable'; end if;
 object:=(descriptor->>'object_id')::uuid; bytes:=(descriptor->>'byte_count')::bigint;
 if p_first_byte>=bytes or (p_last_byte is not null and p_last_byte>=bytes) then raise exception 'invalid_original_range'; end if;
 ceiling:=coalesce(p_last_byte,bytes-1)-p_first_byte+1;
 select * into strict ap from app_private.acquisition_policy;
 insert into app_private.acquisition_transfer_windows(period,scope,kind,charged) values(month,'reader-environment','reader_bytes',ceiling)
 on conflict(period,scope,kind) do update set charged=app_private.acquisition_transfer_windows.charged+excluded.charged returning charged into used;
 if used>ap.reader_bytes_month then raise exception 'original_environment_transfer_limit'; end if;
 insert into app_private.acquisition_transfer_windows(period,scope,kind,charged) values(month,p_account_id::text,'reader_bytes',ceiling)
 on conflict(period,scope,kind) do update set charged=app_private.acquisition_transfer_windows.charged+excluded.charged returning charged into used;
 if used>ap.account_reader_bytes_month then raise exception 'original_account_transfer_limit'; end if;
 expires:=clock_timestamp()+interval '120 seconds';
 insert into app_private.paper_read_grants(day,account_id,operation_id,request_sha256,item_id,object_id,first_byte,last_byte,byte_ceiling,expires_at)
 values(p_day,p_account_id,p_operation_id,digest,p_item_id,object,p_first_byte,coalesce(p_last_byte,bytes-1),ceiling,expires);
 return jsonb_build_object('granted',true,'descriptor',descriptor,'path',(select path from app_private.stored_objects where id=object),
  'first_byte',p_first_byte,'last_byte',coalesce(p_last_byte,bytes-1),'byte_ceiling',ceiling,'expires_at',expires);
end $$;

-- Repeated bounded scans are the durable queue. Enqueue/Realtime delivery is
-- only a hint; after each completed scan restart from the beginning.
create function public.worker_scan_acquisition_jobs(p_after_id uuid default null,p_limit integer default 50,p_kind text default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if p_limit is null or p_limit not between 1 and 100 or (p_kind is not null and p_kind not in ('lookup','original')) then raise exception 'invalid_acquisition_limit'; end if;
 select coalesce(jsonb_agg(app_private.acquisition_job_entry(id) order by id),'[]'::jsonb) into result from
  (select j.id from app_private.acquisition_jobs j where (p_after_id is null or j.id>p_after_id) and (p_kind is null or j.kind=p_kind)
   and j.status in ('queued','retry_wait','leased','blocked') and j.next_attempt_at<=clock_timestamp()
   and (j.hard_deadline is null or j.hard_deadline<=clock_timestamp()) and j.stage<>'pending_verification'
   and app_private.acquisition_has_interest(j.id) order by j.id limit p_limit) page;
 return result;
end $$;
create function public.worker_scan_original_verifications(p_after_id uuid default null,p_limit integer default 50) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform app_private.require_verifier_role();
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'invalid_verification_limit'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',id) order by id),'[]'::jsonb) into result from
  (select r.id from app_private.paper_asset_reservations r join app_private.acquisition_jobs j on j.id=r.job_id
   where (p_after_id is null or r.id>p_after_id) and r.state in ('pending_verification','upload_uncertain','verifying')
   and j.stage='pending_verification' and j.next_attempt_at<=clock_timestamp() and j.status not in ('failed','no_interest')
   and (r.verification_lease_until is null or r.verification_lease_until<=clock_timestamp())
   and app_private.acquisition_has_interest(j.id) order by r.id limit p_limit) page;
 return result;
end $$;
create function public.worker_scan_asset_projections(p_after_id uuid default null,p_limit integer default 50) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'invalid_projection_limit'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('document_id',document_id,'target_revision',target_revision) order by document_id),'[]'::jsonb) into result from
  (select document_id,target_revision from app_private.paper_availability_outbox where (p_after_id is null or document_id>p_after_id)
   and (lease_until is null or lease_until<=clock_timestamp()) order by document_id limit p_limit) page;
 return result;
end $$;

-- Introducing projection fields changes entry payloads. Journal every existing
-- item (including tombstones) under a new state_seq, retaining pins and intent.
-- The migration's initial account-table barrier precedes all DDL/policy locks.
do $$ declare li record; s bigint; begin
 for li in select account_id,id,document_id from app_private.library_items order by account_id,id loop
  -- Closed accounts still own immutable rows. Backfill their payload versions
  -- without granting the active-account worker any bypass.
  perform 1 from app_private.accounts where id=li.account_id for no key update;
  perform 1 from app_private.documents where id=li.document_id for key share;
  perform app_private.lock_library_state(li.account_id);
  s:=app_private.library_next_seq(li.account_id);
  perform app_private.write_library_assets(li.account_id,li.id,app_private.current_library_assets(li.account_id,li.id));
  update app_private.library_items set state_seq=s where account_id=li.account_id and id=li.id;
  perform app_private.library_emit(li.account_id,s,jsonb_build_array(app_private.library_item_entry(li.account_id,li.id)));
 end loop;
end $$;

-- All new private relations use RLS and have no client/service table grants.
do $$ declare t text; f record; begin
 foreach t in array array['acquisition_policy','acquisition_source_slots','acquisition_jobs','acquisition_steps','acquisition_commands','acquisition_interests',
  'arxiv_network_gate','acquisition_transfer_windows','paper_storage_capacity','paper_verification_profiles','paper_asset_reservations',
  'paper_verification_results','paper_originals','paper_asset_availability','paper_availability_outbox','library_asset_projection',
  'paper_integrity_failures','acquisition_transfer_capacity','paper_read_policy','paper_read_grants'] loop
  execute format('alter table app_private.%I enable row level security',t);
  execute format('revoke all on app_private.%I from public,anon,authenticated,service_role,science_reader_pdf_verifier',t);
 end loop;
 for f in select oid::regprocedure as sig from pg_proc where pronamespace='app_private'::regnamespace loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role,science_reader_pdf_verifier',f.sig);
 end loop;
 for f in select oid::regprocedure as sig,proname from pg_proc where pronamespace='public'::regnamespace and proname in (
  'worker_scan_acquisition_jobs','worker_scan_original_verifications','worker_scan_asset_projections','worker_acquisition_state','worker_retry_lookup','worker_prepare_acquisition','worker_prepare_original','worker_import_state','worker_scan_acquisition_imports',
  'worker_link_import_acquisition','worker_claim_acquisition','worker_claim_arxiv_stage','worker_begin_arxiv_request','worker_finish_arxiv_request','worker_arxiv_request_state',
  'worker_finish_lookup','worker_fail_acquisition','worker_project_import_acquisition','worker_reserve_original','worker_mark_original_uploading',
  'worker_record_original_upload','worker_original_reservation','worker_original_verification_state','worker_claim_original_verification','worker_record_original_verification',
  'worker_verification_input_unavailable','worker_record_original_integrity_failure','worker_publish_original','worker_bind_lookup_original',
  'worker_project_library_availability','worker_set_original_availability','worker_claim_asset_projection','worker_asset_projection_page',
  'worker_ack_asset_projection','worker_claim_original_orphans','worker_confirm_original_deleted','v2_original_descriptor','worker_authorize_original_read') loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role,science_reader_pdf_verifier',f.sig);
  if f.proname in ('worker_begin_arxiv_request','worker_mark_original_uploading') then null;
  elsif f.proname in ('worker_scan_original_verifications','worker_original_verification_state','worker_claim_original_verification','worker_record_original_verification','worker_verification_input_unavailable','worker_record_original_integrity_failure') then
   execute format('grant execute on function %s to science_reader_pdf_verifier',f.sig);
  elsif f.proname='v2_original_descriptor' then execute format('grant execute on function %s to authenticated',f.sig);
  else execute format('grant execute on function %s to service_role',f.sig); end if;
 end loop;
end $$;
commit;
