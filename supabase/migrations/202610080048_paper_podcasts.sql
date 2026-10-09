-- Paper podcasts v1 (docs/architecture/PAPER_PODCASTS.md). Everything ships dark:
-- every switch below starts disabled and no seed allowance is active. Admission,
-- provider grants, uploads, publication and delivery are database-fenced; the
-- worker and Edge functions only call these bounded RPCs.
--
-- Lock order (composes with 034/035/039): platform budget period(s) -> accounts
-- (UUID order) -> provider_spending_policy -> metered operation -> podcast_policy
-- -> podcast seed period -> podcast job rows -> paper_storage_capacity ->
-- reader_delivery_policy. Nothing here acquires a budget/account row after a
-- job, source or capacity row.
begin;

-- ---------------------------------------------------------------------------
-- A. Identity, finance and provider routes
-- ---------------------------------------------------------------------------
alter table app_private.metered_operations drop constraint metered_operations_kind_check;
alter table app_private.metered_operations add constraint metered_operations_kind_check
 check(kind in ('chat','ocr','search','metadata','diagram','podcast'));

alter table app_private.provider_attempts drop constraint provider_attempts_provider_check;
alter table app_private.provider_attempts add constraint provider_attempts_provider_check
 check(provider in ('anthropic','tavily','mathpix','google'));
alter table app_private.provider_attempts drop constraint provider_attempts_route_check;
alter table app_private.provider_attempts add constraint provider_attempts_route_check
 check(route in ('chat','chat_search','ingest_lookup','reference_lookup','catalog_tags','paper_ocr',
  'podcast_script','podcast_review','podcast_speech'));

-- Observed speech units only; nothing is inferred into a final usage record.
create or replace function app_private.valid_provider_units(p_units jsonb) returns boolean
language plpgsql immutable set search_path='' as $$
declare item record;
begin
 if p_units is null or jsonb_typeof(p_units)<>'object' or octet_length(p_units::text)>2048 then return false; end if;
 for item in select key,value from jsonb_each(p_units) loop
  if item.key not in ('input_tokens','output_tokens','cache_write_5m_tokens','cache_write_1h_tokens','cache_read_tokens',
    'web_searches','attempts','credits','searches','pages','estimated','text_input_tokens','audio_output_tokens','audio_ms')
   or jsonb_typeof(item.value)<>'number' or item.value::text !~ '^[0-9]{1,12}$' then return false; end if;
 end loop;
 return true;
end $$;

-- Immutable, versioned profiles. The active pointer lives in podcast_policy.
create table app_private.podcast_profiles (
 id text not null check(id ~ '^[a-z][a-z0-9-]{2,47}$'),
 version integer not null check(version between 1 and 1000),
 spec jsonb not null check(jsonb_typeof(spec)='object' and octet_length(spec::text)<=8192),
 spec_sha256 bytea not null check(spec_sha256=sha256(convert_to(spec::text,'UTF8'))),
 created_at timestamptz not null default now(),
 primary key(id,version)
);
create trigger podcast_profiles_immutable before update or delete on app_private.podcast_profiles
 for each row execute function app_private.immutable_record();
-- Ceilings follow PRICING_RECOMMENDATION_20261008 "Podcast unit costs and hard holds":
-- script 80,000 in x $2/M + 6,000 out x $10/M = $0.22; review 80,000 x $2/M + 4,000 x $10/M = $0.20;
-- speech 8,192 text x $1/M + 16,384 audio x $18/M (January 2027 list price) = $0.303104.
-- Total $0.723104, held as $0.75 / 150 credits at $0.005 per credit.
insert into app_private.podcast_profiles(id,version,spec,spec_sha256)
select 'podcast-5min-v1',1,s,sha256(convert_to(s::text,'UTF8')) from (select jsonb_build_object(
 'id','podcast-5min-v1','version',1,'language','en','target_seconds',300,'min_seconds',120,'max_seconds',660,
 'max_source_bytes',400000,
 'script',jsonb_build_object('provider','anthropic','model','claude-sonnet-5-5',
  'rates_microusd_per_token',jsonb_build_object('input',2,'output',10),
  'calls',jsonb_build_array(
   jsonb_build_object('route','podcast_script','max_input_tokens',80000,'max_output_tokens',6000,'ceiling_microusd',220000),
   jsonb_build_object('route','podcast_review','max_input_tokens',80000,'max_output_tokens',4000,'ceiling_microusd',200000))),
 'speech',jsonb_build_object('provider','google','route','podcast_speech','model','gemini-3.8-flash-tts','location','global',
  'max_input_tokens',8192,'max_output_tokens',16384,'audio_tokens_per_second',25,
  'rates_microusd_per_token',jsonb_build_object('text_input',1,'audio_output',18),'ceiling_microusd',303104,
  'voices',jsonb_build_object('explainer','Sadaltager','skeptic','Erinome')),
 'encoder',jsonb_build_object('codec','aac','container','m4a','channels',1,'sample_rate',24000,'bitrate_kbps',64,'loudness_lufs',-16),
 'ceiling_microusd',723104,'hold_microusd',750000,'max_credits',150,'credit_microusd',5000,
 'storage',jsonb_build_object('bytes',20971520,'objects',3,'audio_bytes',16777216,'transcript_bytes',4194304,'manifest_bytes',262144),
 'consent_version','podcast-private-v1') s) x;

-- Further lengths (owner, 2026-10-08): Short, 10 and 20 minutes, private generation only (the seed pilot stays
-- five-minute). Same method as above: every paid call reserves its full input cap and output cap at the list price.
-- A review reads the paper plus the draft, so its input cap is the draft's input cap + the draft's output cap + 1,000.
-- Speech is planned in chunks (each call within Gemini TTS's 8,192 input / 16,384 output tokens); the profile caps the
-- number of calls and the total audio tokens (max_seconds x 25/s), and each call reserves 8,192 input tokens.
--  short: script 80,000x2+3,200x10=192,000; review 84,200x2+2,600x10=194,400; speech 1x8,192x1+8,250x18=156,692;
--         total 543,092 -> 110 credits ($0.55)
--  10min: script 80,000x2+12,000x10=280,000; review 93,000x2+10,000x10=286,000; speech 3x8,192+27,000x18=510,576;
--         total 1,076,576 -> 220 credits ($1.10)
--  20min: script 80,000x2+22,800x10=388,000; review 103,800x2+19,000x10=397,600; speech 6x8,192+51,000x18=967,152;
--         total 1,752,752 -> 360 credits ($1.80)
-- Credit maximums are the total rounded up to the next 10 credits, as 723,104 -> 150 above. Ten and twenty minutes run
-- in stages (one paid script pass per worker request, the draft and approved script checkpointed in between).
insert into app_private.podcast_profiles(id,version,spec,spec_sha256)
select id,1,s,sha256(convert_to(s::text,'UTF8')) from (
 select p.id,jsonb_build_object('id',p.id,'version',1,'label',p.label,'language','en','target_seconds',p.target,'min_seconds',p.min_s,
  'max_seconds',p.max_s,'max_source_bytes',400000,'staged',p.staged,
  'shape',jsonb_build_object('duration',p.duration,'words',p.words,'chapters',p.chapters,'segments',p.segments),
  'checker',jsonb_build_object('words',p.check_words,'chapters',p.check_chapters,'segments',p.check_segments,
   'max_spoken_characters',p.spoken,'min_evidenced',p.evidenced),
  'script',jsonb_build_object('provider','anthropic','model','claude-sonnet-5-5',
   'rates_microusd_per_token',jsonb_build_object('input',2,'output',10),
   'calls',jsonb_build_array(
    jsonb_build_object('route','podcast_script','max_input_tokens',80000,'max_output_tokens',p.draft_out,
     'ceiling_microusd',80000*2+p.draft_out*10)||case when p.staged then jsonb_build_object('window_seconds',p.draft_window) else '{}'::jsonb end,
    jsonb_build_object('route','podcast_review','max_input_tokens',80000+p.draft_out+1000,'max_output_tokens',p.review_out,
     'ceiling_microusd',(80000+p.draft_out+1000)*2+p.review_out*10)||case when p.staged then jsonb_build_object('window_seconds',p.review_window) else '{}'::jsonb end)),
  'speech',jsonb_build_object('provider','google','route','podcast_speech','model','gemini-3.8-flash-tts','location','global',
   'max_input_tokens',8192,'max_output_tokens',p.call_out,'max_calls',p.calls,'max_audio_tokens',p.audio,'audio_tokens_per_second',25,
   'rates_microusd_per_token',jsonb_build_object('text_input',1,'audio_output',18),'ceiling_microusd',p.calls*8192+p.audio*18,
   'voices',jsonb_build_object('explainer','Sadaltager','skeptic','Erinome'))
   ||case when p.staged then jsonb_build_object('window_seconds',420) else '{}'::jsonb end,
  'encoder',jsonb_build_object('codec','aac','container','m4a','channels',1,'sample_rate',24000,'bitrate_kbps',64,'loudness_lufs',-16),
  'ceiling_microusd',p.total,'hold_microusd',p.credits*5000,'max_credits',p.credits,'credit_microusd',5000,
  'storage',jsonb_build_object('bytes',p.audio_bytes+4194304+262144,'objects',3,'audio_bytes',p.audio_bytes,'transcript_bytes',4194304,'manifest_bytes',262144),
  'consent_version','podcast-private-v1') s
 from (values
  ('podcast-short-v1','Short',150,60,330,false,'about two and a half minutes','[330,420]'::jsonb,'[2,3]'::jsonb,'[8,20]'::jsonb,
   '[220,520]'::jsonb,'[2,5]'::jsonb,'[4,40]'::jsonb,3200,3,3200,2600,0,0,8250,1,8250,543092,110,4194304),
  ('podcast-10min-v1','10 min',600,300,1080,true,'about ten minutes','[1350,1650]'::jsonb,'[6,8]'::jsonb,'[30,80]'::jsonb,
   '[900,2000]'::jsonb,'[4,12]'::jsonb,'[16,160]'::jsonb,12500,10,12000,10000,420,360,16384,3,27000,1076576,220,12582912),
  ('podcast-20min-v1','20 min',1200,600,2040,true,'about twenty minutes','[2700,3300]'::jsonb,'[8,12]'::jsonb,'[60,150]'::jsonb,
   '[1800,3800]'::jsonb,'[6,20]'::jsonb,'[30,300]'::jsonb,24000,18,22800,19000,680,600,16384,6,51000,1752752,360,20971520)
 ) p(id,label,target,min_s,max_s,staged,duration,words,chapters,segments,check_words,check_chapters,check_segments,spoken,evidenced,
     draft_out,review_out,draft_window,review_window,call_out,calls,audio,total,credits,audio_bytes)
) x;
-- The stated totals are the sums of their parts (a typo here would silently mis-hold customers).
do $$ begin
 if exists(select 1 from app_private.podcast_profiles where id<>'podcast-5min-v1' and (
   (spec->>'ceiling_microusd')::bigint<>(select sum((c->>'ceiling_microusd')::bigint) from jsonb_array_elements(spec->'script'->'calls') c)
    +(spec->'speech'->>'ceiling_microusd')::bigint
   or (spec->>'max_credits')::bigint<>ceil((spec->>'ceiling_microusd')::numeric/50000)*10
   or (spec->'speech'->>'max_audio_tokens')::bigint>(spec->>'max_seconds')::bigint*25
   or (spec->'speech'->>'max_output_tokens')::bigint>16384)) then
  raise exception 'podcast_profile_arithmetic';
 end if;
end $$;

-- Disabled by default; audited changes only through worker_podcast_policy_set.
create table app_private.podcast_policy (
 singleton boolean primary key default true check(singleton),
 catalog_enabled boolean not null default false,
 delivery_enabled boolean not null default false,
 generation_enabled boolean not null default false,
 seed_enabled boolean not null default false,
 fixtures_enabled boolean not null default false,
 -- The seed and default length (Decision 2: seeds are five-minute episodes only).
 profile_id text not null default 'podcast-5min-v1',
 profile_version integer not null default 1,
 -- Lengths offered for private generation ('id:version', one version per id); audited changes only.
 allowed_profiles text[] not null default array['podcast-short-v1:1','podcast-5min-v1:1','podcast-10min-v1:1','podcast-20min-v1:1']
  check(cardinality(allowed_profiles) between 1 and 8),
 -- Rotated by restore quarantine; every mutation compares a job's captured epoch.
 epoch uuid not null default gen_random_uuid(),
 max_active_private_per_account integer not null default 1 check(max_active_private_per_account between 1 and 5),
 max_active_environment integer not null default 2 check(max_active_environment between 1 and 10),
 max_jobs_day_environment integer not null default 20 check(max_jobs_day_environment between 1 and 200),
 quality_allocation_microusd bigint not null default 750000 check(quality_allocation_microusd between 0 and 5000000),
 account_transfer_bytes_month bigint not null default 104857600 check(account_transfer_bytes_month between 1 and 2147483648),
 paid_account_transfer_bytes_month bigint not null default 536870912 check(paid_account_transfer_bytes_month between 1 and 2147483648),
 environment_transfer_bytes_month bigint not null default 2147483648 check(environment_transfer_bytes_month between 1 and 21474836480),
 revision bigint not null default 0 check(revision>=0),
 updated_at timestamptz not null default now(),
 foreign key(profile_id,profile_version) references app_private.podcast_profiles(id,version)
);
-- Every allowlisted length names an existing immutable profile, once per id.
create function app_private.podcast_policy_profiles_valid() returns trigger language plpgsql set search_path='' as $$
begin
 if exists(select 1 from unnest(new.allowed_profiles) e where e is null or e !~ '^[a-z][a-z0-9-]{2,47}:[1-9][0-9]{0,3}$'
   or not exists(select 1 from app_private.podcast_profiles p where p.id=split_part(e,':',1) and p.version=split_part(e,':',2)::integer))
  or (select count(distinct split_part(e,':',1)) from unnest(new.allowed_profiles) e)<>cardinality(new.allowed_profiles)
 then raise exception 'invalid_podcast_policy'; end if;
 return new;
end $$;
create trigger podcast_policy_profiles before insert or update of allowed_profiles on app_private.podcast_policy
 for each row execute function app_private.podcast_policy_profiles_valid();
insert into app_private.podcast_policy default values;
create table app_private.podcast_policy_events (
 id uuid primary key, actor_id uuid not null references app_private.accounts(id),
 changes jsonb not null check(jsonb_typeof(changes)='object' and octet_length(changes::text)<=2048),
 reason text not null check(length(reason) between 3 and 500),
 revision bigint not null, created_at timestamptz not null default now()
);
create trigger podcast_policy_events_immutable before update or delete on app_private.podcast_policy_events
 for each row execute function app_private.immutable_record();

-- Dated seed allowance inside the platform budget period. Created disabled.
-- Decision 2 (2026-10-08): at most $2 for the first two curated episodes; the
-- remainder is for explicit QA, never a third episode without a new decision.
create table app_private.podcast_seed_periods (
 period date primary key check(extract(day from period)=1),
 limit_microusd bigint not null check(limit_microusd between 0 and 2000000),
 max_episodes integer not null default 2 check(max_episodes between 0 and 2),
 enabled boolean not null default false,
 evidence_reference text not null check(length(evidence_reference) between 3 and 256),
 configured_by uuid references app_private.accounts(id),
 configured_at timestamptz not null default now(),
 foreign key(period) references app_private.platform_budgets(period)
);

create table app_private.podcast_episode_keys (
 id uuid primary key default gen_random_uuid(),
 scope text not null check(scope in ('shared','private')),
 owner_id uuid references app_private.accounts(id),
 work_sha256 bytea not null check(octet_length(work_sha256)=32),
 profile_id text not null, profile_version integer not null,
 created_at timestamptz not null default now(),
 check((scope='shared')=(owner_id is null)),
 foreign key(profile_id,profile_version) references app_private.podcast_profiles(id,version),
 unique(id,scope)
);
create unique index podcast_shared_work on app_private.podcast_episode_keys(work_sha256) where scope='shared';
create unique index podcast_private_work on app_private.podcast_episode_keys(owner_id,work_sha256) where scope='private';
create trigger podcast_episode_keys_immutable before update or delete on app_private.podcast_episode_keys
 for each row execute function app_private.immutable_record();

-- Exact, server-resolved source pins (one row in v1).
create table app_private.podcast_sources (
 episode_id uuid not null references app_private.podcast_episode_keys(id),
 ordinal smallint not null check(ordinal=0),
 document_id uuid not null references app_private.documents(id),
 document_sha256 bytea not null check(octet_length(document_sha256)=32),
 approval_id uuid references app_private.catalog_asset_approvals(id),
 version_id uuid, metadata_id uuid,
 ocr_run_id uuid not null references app_private.ocr_runs(id),
 raw_manifest_object_id uuid not null references app_private.stored_objects(id),
 raw_manifest_sha256 bytea not null check(octet_length(raw_manifest_sha256)=32),
 text_object_id uuid not null references app_private.stored_objects(id),
 text_sha256 bytea not null check(octet_length(text_sha256)=32),
 text_bytes bigint not null check(text_bytes between 1 and 8388608),
 artifact_id uuid references app_private.render_artifacts(id),
 normalization_version text not null check(normalization_version='mathpix-standalone-mmd-v1'),
 primary key(episode_id,ordinal)
);
create trigger podcast_sources_immutable before update or delete on app_private.podcast_sources
 for each row execute function app_private.immutable_record();

-- Revocable publication state for shared episodes; asset approvals stay immutable evidence.
create table app_private.podcast_rights (
 episode_id uuid primary key,
 scope text not null default 'shared' check(scope='shared'),
 state text not null check(state in ('active','quarantined','withdrawn')),
 rights_revision bigint not null default 1 check(rights_revision>=1),
 approval_id uuid not null references app_private.catalog_asset_approvals(id),
 license_uri text not null check(license_uri in ('https://creativecommons.org/licenses/by/4.0/','https://creativecommons.org/publicdomain/zero/1.0/')),
 evidence_sha256 bytea not null check(octet_length(evidence_sha256)=32),
 reviewer_id uuid not null references app_private.accounts(id),
 updated_at timestamptz not null default now(),
 foreign key(episode_id,scope) references app_private.podcast_episode_keys(id,scope)
);
create table app_private.podcast_rights_events (
 id uuid primary key, episode_id uuid not null references app_private.podcast_rights(episode_id),
 actor_id uuid not null references app_private.accounts(id),
 state text not null check(state in ('active','quarantined','withdrawn')),
 rights_revision bigint not null, reason text not null check(length(reason) between 3 and 500),
 created_at timestamptz not null default now()
);
create trigger podcast_rights_events_immutable before update or delete on app_private.podcast_rights_events
 for each row execute function app_private.immutable_record();

-- Short-lived quotes: ids and digests only, never prompts or titles.
create table app_private.podcast_quotes (
 id uuid primary key default gen_random_uuid(),
 account_id uuid not null references app_private.accounts(id),
 request_id uuid not null,
 item_id uuid not null,
 work_sha256 bytea not null check(octet_length(work_sha256)=32),
 pin jsonb not null check(jsonb_typeof(pin)='object' and octet_length(pin::text)<=4096),
 profile_id text not null, profile_version integer not null,
 max_credits bigint not null check(max_credits between 1 and 1000),
 max_microusd bigint not null check(max_microusd between 1 and 5000000),
 epoch uuid not null,
 consent_version text not null check(consent_version='podcast-private-v1'),
 created_at timestamptz not null default now(),
 expires_at timestamptz not null check(expires_at<=created_at+interval '30 minutes'),
 unique(account_id,request_id),
 foreign key(profile_id,profile_version) references app_private.podcast_profiles(id,version)
);
create index podcast_quote_expiry on app_private.podcast_quotes(expires_at);

create table app_private.podcast_jobs (
 id uuid primary key default gen_random_uuid(),
 episode_id uuid not null references app_private.podcast_episode_keys(id),
 generation integer not null default 1 check(generation between 1 and 1000),
 origin text not null check(origin in ('generated','fixture')),
 funding_kind text not null check(funding_kind in ('platform_seed','customer','fixture')),
 state text not null default 'queued' check(state in ('queued','scripting','checking','synthesizing','verifying','publishing',
  'ready','canceled','failed','capacity_wait','unknown_provider','quarantined')),
 stage_entered_at timestamptz not null default now(),
 operation_account_id uuid, operation_id uuid,
 actor_id uuid references app_private.accounts(id),
 reason text check(length(reason) between 3 and 500),
 seed_period date references app_private.podcast_seed_periods(period),
 cancel_requested boolean not null default false,
 claim_id uuid, claim_generation bigint not null default 0 check(claim_generation>=0), lease_until timestamptz,
 epoch uuid not null,
 rights_revision bigint,
 retry_of uuid references app_private.podcast_jobs(id),
 failure_code text check(failure_code ~ '^[a-z][a-z0-9_]{0,63}$'),
 charged_credits bigint check(charged_credits between 0 and 1000),
 -- Speech chunks planned for this job, fixed at its first speech grant (at most the profile's max_calls).
 speech_calls smallint check(speech_calls between 1 and 8),
 quality_loss_microusd bigint not null default 0 check(quality_loss_microusd>=0),
 -- Every known cost of a customer job charged zero credits (quality, interruption,
 -- unknown outcome): counted with unresolved ceilings against the allocation.
 platform_loss_microusd bigint not null default 0 check(platform_loss_microusd>=0),
 kicked_at timestamptz,
 created_at timestamptz not null default now(),
 finished_at timestamptz,
 foreign key(operation_account_id,operation_id) references app_private.metered_operations(account_id,id),
 check((funding_kind='fixture')=(operation_id is null)),
 check((operation_account_id is null)=(operation_id is null)),
 check((funding_kind='fixture')=(origin='fixture')),
 check((funding_kind='platform_seed')=(seed_period is not null)),
 check(funding_kind='customer' or actor_id is not null),
 check((claim_id is null)=(lease_until is null)),
 check((state in ('ready','canceled','failed'))=(finished_at is not null))
);
create unique index podcast_job_operation on app_private.podcast_jobs(operation_account_id,operation_id) where operation_id is not null;
-- One active job per episode work key.
create unique index podcast_job_active on app_private.podcast_jobs(episode_id)
 where state in ('queued','scripting','checking','synthesizing','verifying','publishing','capacity_wait');
create index podcast_job_due on app_private.podcast_jobs(state,created_at);
create index podcast_job_account on app_private.podcast_jobs(operation_account_id,created_at);

create table app_private.podcast_requests (
 account_id uuid not null references app_private.accounts(id),
 request_id uuid not null,
 quote_id uuid not null,
 job_id uuid references app_private.podcast_jobs(id),
 release_id uuid,
 outcome text not null check(outcome in ('started','joined','reused')),
 created_at timestamptz not null default now(),
 primary key(account_id,request_id),
 check((outcome='reused')=(job_id is null))
);
create index podcast_request_job on app_private.podcast_requests(job_id);

create table app_private.podcast_job_events (
 id bigint generated always as identity primary key,
 job_id uuid not null references app_private.podcast_jobs(id),
 kind text not null check(kind ~ '^[a-z][a-z0-9_]{0,47}$'),
 details jsonb not null default '{}'::jsonb check(jsonb_typeof(details)='object' and octet_length(details::text)<=2048),
 created_at timestamptz not null default now()
);
create index podcast_job_event_lookup on app_private.podcast_job_events(job_id,id);
create trigger podcast_job_events_immutable before update or delete on app_private.podcast_job_events
 for each row execute function app_private.immutable_record();
create table app_private.podcast_job_attempts (
 job_id uuid not null references app_private.podcast_jobs(id),
 route text not null check(route in ('podcast_script','podcast_review','podcast_speech')),
 -- Speech chunk number (0 for the script routes and single-call speech).
 ordinal smallint not null default 0 check(ordinal between 0 and 7 and (route='podcast_speech' or ordinal=0)),
 attempt_id uuid not null unique references app_private.provider_attempts(id),
 primary key(job_id,route,ordinal)
);

-- Staged jobs (profiles with "staged": true) checkpoint the draft and the approved
-- script between worker requests, so a ten- or twenty-minute script never has to
-- fit one request. Working state only: bounded, never logged, deleted when the job
-- settles (every terminal path goes through podcast_settle). Server-readable like
-- the private transcript it becomes; not end-to-end encrypted.
create table app_private.podcast_job_checkpoints (
 job_id uuid not null references app_private.podcast_jobs(id),
 stage text not null check(stage in ('draft','script')),
 document jsonb not null check(jsonb_typeof(document)='object' and octet_length(document::text)<=1048576),
 sha256 bytea not null check(octet_length(sha256)=32),
 created_at timestamptz not null default now(),
 primary key(job_id,stage)
);
create function app_private.podcast_checkpoint_immutable() returns trigger language plpgsql set search_path='' as $$
begin raise exception 'immutable_record_requires_compensating_entry'; end $$;
create trigger podcast_job_checkpoints_immutable before update on app_private.podcast_job_checkpoints
 for each row execute function app_private.podcast_checkpoint_immutable();

-- Approved scripts (identity = exact normalized transcript/evidence document hash).
create table app_private.podcast_scripts (
 id uuid primary key default gen_random_uuid(),
 job_id uuid not null unique references app_private.podcast_jobs(id),
 episode_id uuid not null references app_private.podcast_episode_keys(id),
 script_sha256 bytea not null check(octet_length(script_sha256)=32),
 draft_sha256 bytea check(octet_length(draft_sha256)=32),
 checker_version text not null check(checker_version ~ '^[a-z0-9.-]{1,64}$'),
 decision text not null check(decision='accepted'),
 segments integer not null check(segments between 1 and 400),
 chapters integer not null check(chapters between 1 and 40),
 created_at timestamptz not null default now()
);
create trigger podcast_scripts_immutable before update or delete on app_private.podcast_scripts
 for each row execute function app_private.immutable_record();

create sequence app_private.podcast_publication_seq;
create table app_private.podcast_releases (
 id uuid primary key default gen_random_uuid(),
 episode_id uuid not null references app_private.podcast_episode_keys(id),
 job_id uuid not null unique references app_private.podcast_jobs(id),
 script_id uuid not null references app_private.podcast_scripts(id),
 scope text not null check(scope in ('shared','private')),
 owner_id uuid references app_private.accounts(id),
 origin text not null check(origin in ('generated','fixture')),
 identity jsonb not null check(jsonb_typeof(identity)='object' and octet_length(identity::text)<=4096),
 manifest_sha256 bytea not null unique check(octet_length(manifest_sha256)=32),
 duration_ms integer not null check(duration_ms between 1000 and 3600000),
 public_metadata jsonb check(public_metadata is null or (jsonb_typeof(public_metadata)='object' and octet_length(public_metadata::text)<=8192)),
 state text not null check(state in ('pending_review','ready','superseded','quarantined','withdrawn')),
 replacement_id uuid references app_private.podcast_releases(id),
 published_seq bigint unique,
 published_at timestamptz,
 reviewed_by uuid references app_private.accounts(id),
 created_at timestamptz not null default now(),
 check((scope='shared')=(owner_id is null)),
 check((state='ready')<=(published_seq is not null)),
 check((published_seq is null)=(published_at is null))
);
create index podcast_release_catalog on app_private.podcast_releases(published_seq desc) where scope='shared' and state='ready';
create index podcast_release_owner on app_private.podcast_releases(owner_id,episode_id) where scope='private';
create function app_private.protect_podcast_release() returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op='DELETE' then raise exception 'immutable_record_requires_compensating_entry'; end if;
 if (new.id,new.episode_id,new.job_id,new.script_id,new.scope,new.owner_id,new.origin,new.identity,new.manifest_sha256,new.duration_ms,new.created_at)
  is distinct from (old.id,old.episode_id,old.job_id,old.script_id,old.scope,old.owner_id,old.origin,old.identity,old.manifest_sha256,old.duration_ms,old.created_at)
  or (old.published_seq is not null and new.published_seq is distinct from old.published_seq)
  or (old.public_metadata is not null and new.public_metadata is distinct from old.public_metadata)
  or (old.state in ('superseded','withdrawn') and new.state is distinct from old.state)
 then raise exception 'immutable_podcast_release'; end if;
 return new;
end $$;
create trigger podcast_release_identity before update or delete on app_private.podcast_releases
 for each row execute function app_private.protect_podcast_release();

-- ---------------------------------------------------------------------------
-- B. Storage: private bucket family, inventory, capacity
-- ---------------------------------------------------------------------------
alter table app_private.stored_objects drop constraint stored_objects_bucket_check;
alter table app_private.stored_objects add constraint stored_objects_bucket_check
 check(bucket in ('paper-assets','private-content','support','paper-uploads','podcast-assets'));
alter table app_private.stored_objects drop constraint stored_objects_check;
alter table app_private.stored_objects add constraint stored_objects_check check(
 (bucket='paper-assets' and document_id is not null and owner_id is null)
 or (bucket in ('private-content','support','paper-uploads') and owner_id is not null and document_id is null)
 or (bucket='podcast-assets' and ((document_id is not null and owner_id is null and path ~ '^shared/[0-9a-f]{64}/(audio\.m4a|transcript\.json|manifest\.json)$')
   or (owner_id is not null and document_id is null and path ~ ('^private/'||owner_id::text||'/[0-9a-f]{64}/(audio\.m4a|transcript\.json|manifest\.json)$')))));
create index stored_objects_podcasts on app_private.stored_objects(owner_id,state) where bucket='podcast-assets';

create table app_private.podcast_release_objects (
 release_id uuid not null references app_private.podcast_releases(id),
 role text not null check(role in ('audio','transcript','manifest')),
 ordinal smallint not null default 0 check(ordinal=0),
 object_id uuid not null unique references app_private.stored_objects(id),
 primary key(release_id,role,ordinal)
);
create trigger podcast_release_objects_immutable before update or delete on app_private.podcast_release_objects
 for each row execute function app_private.immutable_record();

-- Job-fenced equivalents of 035's paper adapters. Holds and pending/uncertain
-- objects count against the shared physical capacity until confirmed deletion.
create table app_private.podcast_asset_holds (
 job_id uuid primary key references app_private.podcast_jobs(id),
 owner_id uuid references app_private.accounts(id),
 -- At most the largest profile's storage reservation (twenty minutes: 20 MiB audio + transcript + manifest).
 bytes bigint not null check(bytes between 1 and 33554432), objects integer not null check(objects between 1 and 3),
 created_at timestamptz not null default clock_timestamp()
);
create table app_private.podcast_asset_uploads (
 id uuid primary key, job_id uuid not null references app_private.podcast_jobs(id),
 claim_id uuid not null, claim_generation bigint not null,
 request_sha256 bytea not null check(octet_length(request_sha256)=32),
 release_key text not null check(release_key ~ '^[0-9a-f]{64}$'),
 created_at timestamptz not null default clock_timestamp()
);
create index podcast_upload_job on app_private.podcast_asset_uploads(job_id,created_at);
create table app_private.podcast_asset_upload_members (
 upload_id uuid not null references app_private.podcast_asset_uploads(id),
 role text not null check(role in ('audio','transcript','manifest')),
 object_id uuid not null references app_private.stored_objects(id),
 primary key(upload_id,role), unique(upload_id,object_id)
);
create table app_private.podcast_asset_writes (
 id uuid primary key, upload_id uuid not null references app_private.podcast_asset_uploads(id),
 object_id uuid not null references app_private.stored_objects(id),
 started_at timestamptz not null default clock_timestamp(), finished_at timestamptz,
 outcome text check(outcome in ('verified','not_written')),
 resolved_by uuid references app_private.accounts(id),
 resolution_evidence text check(length(resolution_evidence) between 3 and 256),
 check((finished_at is null)=(outcome is null)),
 check((resolved_by is null)=(resolution_evidence is null))
);
create index podcast_asset_write_unresolved on app_private.podcast_asset_writes(object_id,started_at) where finished_at is null;

-- Capacity: the existing global/per-owner check also counts podcast objects
-- (pending, verified and deleting) and outstanding podcast holds.
create or replace function app_private.paper_asset_check_capacity(p_owner uuid) returns void
language plpgsql security definer set search_path='' as $$
declare cap app_private.paper_storage_capacity; used bigint; n bigint; owned bigint; owner_cap bigint;
begin
 select * into strict cap from app_private.paper_storage_capacity where singleton for update;
 select coalesce(sum(byte_count),0),count(*) into used,n from app_private.stored_objects
  where bucket in ('paper-assets','paper-uploads','podcast-assets') and state<>'deleted';
 select used+coalesce(sum(bytes),0),n+coalesce(sum(objects),0) into used,n from app_private.paper_asset_holds;
 select used+coalesce(sum(bytes),0),n+coalesce(sum(objects),0) into used,n from app_private.pdf_upload_holds;
 select used+coalesce(sum(bytes),0),n+coalesce(sum(objects),0) into used,n from app_private.podcast_asset_holds;
 if used>cap.max_bytes or n>cap.max_objects then raise exception 'paper_storage_capacity'; end if;
 if p_owner is not null then
  select coalesce(sum(o.byte_count),0) into owned from app_private.stored_objects o
   left join app_private.documents d on d.id=o.document_id
   where o.state<>'deleted' and ((o.bucket='paper-assets' and d.owner_id=p_owner)
    or (o.bucket in ('paper-uploads','podcast-assets') and o.owner_id=p_owner));
  select owned+coalesce(sum(bytes),0) into owned from app_private.paper_asset_holds where owner_id=p_owner;
  select owned+coalesce(sum(bytes),0) into owned from app_private.pdf_upload_holds where owner_id=p_owner;
  select owned+coalesce(sum(bytes),0) into owned from app_private.podcast_asset_holds where owner_id=p_owner;
  select private_bytes_per_owner into strict owner_cap from app_private.pipeline_policy where singleton;
  if owned>owner_cap then raise exception 'paper_owner_storage_capacity'; end if;
 end if;
end $$;

-- Inventory scope 3 adds podcast-assets. Scope-2 certification is not sufficient
-- for podcasts; existing upload gates accept scope 2 or 3.
alter table app_private.paper_asset_policy drop constraint paper_asset_policy_inventory_scope_check;
alter table app_private.paper_asset_policy add constraint paper_asset_policy_inventory_scope_check check(inventory_scope in (1,2,3));
alter table app_private.paper_asset_inventory_scans drop constraint paper_asset_inventory_scans_scope_check;
alter table app_private.paper_asset_inventory_scans add constraint paper_asset_inventory_scans_scope_check check(scope in (1,2,3));

create or replace function public.worker_asset_inventory_begin(p_scan_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if (select enabled from app_private.pdf_upload_policy where singleton)
  or exists(select 1 from app_private.pdf_upload_write_attempts where finished_at is null)
  or exists(select 1 from app_private.podcast_jobs where claim_id is not null)
  or exists(select 1 from app_private.podcast_asset_writes where finished_at is null) then raise exception 'asset_workers_not_drained'; end if;
 result:=app_private.asset_inventory_begin_before_039(p_scan_id);
 update app_private.paper_asset_inventory_scans set scope=3 where id=p_scan_id and finished_at is null;
 return result||jsonb_build_object('scope',3,'buckets',jsonb_build_array('paper-assets','paper-uploads','podcast-assets'));
end $$;
create or replace function public.worker_asset_inventory_page(p_scan_id uuid,p_after uuid default null,p_limit integer default 500) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;
begin
 if p_scan_id is null or p_limit is null or p_limit not between 1 and 500 or not exists(select 1 from app_private.paper_asset_policy where reconciliation_id=p_scan_id)
 then raise exception 'invalid_inventory_scan'; end if;
 select coalesce(jsonb_agg(to_jsonb(r) order by r.id),'[]') into rows from
  (select o.id,o.bucket,o.path,o.document_id,encode(d.sha256,'hex') document_sha256,d.scope,coalesce(d.owner_id,o.owner_id) owner_id,
   o.state,encode(o.sha256,'hex') sha256,o.byte_count bytes,o.media_type
   from app_private.stored_objects o left join app_private.documents d on d.id=o.document_id
   where o.bucket in ('paper-assets','paper-uploads','podcast-assets') and o.state<>'deleted' and (p_after is null or o.id>p_after) order by o.id limit p_limit) r;
 return jsonb_build_object('objects',rows,'next_after',case when jsonb_array_length(rows)>0 then rows->-1->>'id' else null end,'has_more',jsonb_array_length(rows)=p_limit);
end $$;
create or replace function public.worker_asset_inventory_finish(p_scan_id uuid,p_object_count bigint,p_byte_count bigint,p_discrepancies jsonb,p_report_sha256 bytea) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; scan_scope integer;
begin
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if (select enabled from app_private.pdf_upload_policy where singleton)
  or exists(select 1 from app_private.pdf_upload_write_attempts where finished_at is null)
  or exists(select 1 from app_private.podcast_jobs where claim_id is not null)
  or exists(select 1 from app_private.podcast_asset_writes where finished_at is null) then raise exception 'asset_workers_not_drained'; end if;
 select scope into scan_scope from app_private.paper_asset_inventory_scans where id=p_scan_id;
 if scan_scope is distinct from 3 then raise exception 'invalid_inventory_scan'; end if;
 result:=app_private.asset_inventory_finish_before_039(p_scan_id,p_object_count,p_byte_count,p_discrepancies,p_report_sha256);
 if (result->>'complete')::boolean then update app_private.paper_asset_policy set inventory_scope=3 where singleton; end if;
 return result||jsonb_build_object('scope',3);
end $$;

create or replace function public.worker_pdf_upload_policy(p_enabled boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if p_enabled is null then raise exception 'invalid_upload_policy'; end if;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if p_enabled then
  if not exists(select 1 from app_private.paper_asset_policy where enforced and inventory_scope>=2 and inventory_verified_at is not null
   and inventory_discrepancies=0 and reconciliation_id is null) then raise exception 'asset_inventory_incomplete'; end if;
  perform app_private.paper_asset_check_capacity(null);
  perform app_private.paper_asset_check_capacity(owner_id) from (
   select owner_id from app_private.documents where owner_id is not null union select account_id from app_private.pdf_uploads) owners;
 end if;
 update app_private.pdf_upload_policy set enabled=p_enabled where singleton;
 return (select to_jsonb(p) from app_private.pdf_upload_policy p where singleton);
end $$;

create or replace function public.v1_reader_capabilities() returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); suspended boolean; result jsonb;
begin
 select spending_suspended into suspended from app_private.accounts where id=a and closed_at is null for key share;
 if not found then raise exception 'account_unavailable' using errcode='42501'; end if;
 perform public.worker_consume_request(a,'library-read');
 select jsonb_build_object('format',1,'account_id',a,
  'library',jsonb_build_object('endpoint_family','full-v5','wire_format',2,'source_level',4,'dataset_epoch',v.upload_dataset_epoch),
  'descriptors',jsonb_build_object('format',1,'maximum_batch',24),
  'uploads',jsonb_build_object('protocol','upload-chunks-v1',
   'enabled',u.enabled and not suspended and p.enforced and p.inventory_scope>=2 and p.inventory_verified_at is not null
    and p.inventory_discrepancies=0 and p.reconciliation_id is null,
   'chunk_bytes',u.chunk_bytes,'maximum_bytes',67108864,'maximum_parts',16,'part_attempts',u.part_attempts))
 into result from app_private.library_v4_config v cross join app_private.pdf_upload_policy u cross join app_private.paper_asset_policy p
 where v.singleton and u.singleton and p.singleton;
 if result is null then raise exception 'reader_capabilities_unavailable'; end if;
 perform app_private.consume_library_transfer(a,result);
 return result;
end $$;

create or replace function public.worker_asset_spending_status() returns jsonb
language sql stable security definer set search_path='' as $$
 select app_private.asset_spending_status_before_039()||jsonb_build_object(
  'objects',coalesce((select jsonb_agg(r) from (select bucket,state,count(*) objects,sum(byte_count) bytes from app_private.stored_objects
   where bucket in ('paper-assets','paper-uploads','podcast-assets') group by bucket,state) r),'[]'),
  'reservations',coalesce((select jsonb_agg(r) from (select 'paper' scope,kind,count(*) holds,sum(bytes) bytes,sum(objects) objects from app_private.paper_asset_holds group by kind
   union all select 'upload' scope,kind,count(*) holds,sum(bytes) bytes,sum(objects) objects from app_private.pdf_upload_holds group by kind
   union all select 'podcast' scope,'job' kind,count(*) holds,sum(bytes) bytes,sum(objects) objects from app_private.podcast_asset_holds having count(*)>0) r),'[]'),
  'uploads',jsonb_build_object('policy',(select to_jsonb(p) from app_private.pdf_upload_policy p where singleton),
   'sessions',coalesce((select jsonb_agg(r) from (select state,count(*) sessions,min(created_at) oldest from app_private.pdf_uploads group by state) r),'[]'),
   'unresolved_writes',(select jsonb_build_object('count',count(*),'bytes',coalesce(sum(o.byte_count),0),'oldest',min(w.started_at))
    from app_private.pdf_upload_write_attempts w join app_private.stored_objects o on o.id=w.object_id where w.finished_at is null),
   'reads',(select jsonb_build_object('count',count(*),'unobserved',count(*) filter(where observed_at is null),'authorized_bytes',coalesce(sum(bytes),0),
    'observed_bytes',coalesce(sum(observed_bytes),0)) from app_private.pdf_upload_reads)),
  'podcasts',jsonb_build_object(
   'unresolved_writes',(select jsonb_build_object('count',count(*),'bytes',coalesce(sum(o.byte_count),0),'oldest',min(w.started_at))
    from app_private.podcast_asset_writes w join app_private.stored_objects o on o.id=w.object_id where w.finished_at is null),
   'transfers',coalesce((select jsonb_agg(r) from (select * from app_private.reader_transfer_months where kind='podcast' and scope_id='environment' order by period desc limit 12) r),'[]')))
$$;

-- Bounded delivery shares 035's transfer table with a separate audio kind.
alter table app_private.reader_transfer_months drop constraint reader_transfer_months_kind_check;
alter table app_private.reader_transfer_months add constraint reader_transfer_months_kind_check check(kind in ('reader','backend','podcast'));

create table app_private.podcast_delivery_grants (
 id uuid primary key default gen_random_uuid(),
 token_sha256 bytea not null unique check(octet_length(token_sha256)=32),
 account_id uuid not null references app_private.accounts(id),
 release_id uuid not null references app_private.podcast_releases(id),
 rights_revision bigint,
 epoch uuid not null,
 period date not null,
 byte_ceiling bigint not null check(byte_ceiling between 1 and 20971520),
 remaining_bytes bigint not null check(remaining_bytes>=0),
 created_at timestamptz not null default clock_timestamp(), expires_at timestamptz not null, expired_at timestamptz,
 check(remaining_bytes<=byte_ceiling)
);
create index podcast_delivery_expiry on app_private.podcast_delivery_grants(expires_at) where expired_at is null;
create index podcast_delivery_account on app_private.podcast_delivery_grants(account_id);
create table app_private.podcast_delivery_redemptions (
 grant_id uuid not null references app_private.podcast_delivery_grants(id), object_id uuid not null references app_private.stored_objects(id),
 byte_ceiling bigint not null check(byte_ceiling>0), created_at timestamptz not null default clock_timestamp(),
 upstream_bytes bigint check(upstream_bytes>=0), response_bytes bigint check(response_bytes>=0),
 observation text check(observation in ('response_created','upstream_failed','integrity_failed','cancelled')),
 observed_at timestamptz, primary key(grant_id,object_id),
 check(upstream_bytes is null or upstream_bytes<=byte_ceiling), check(response_bytes is null or response_bytes<=byte_ceiling)
);

insert into app_private.api_rate_rules values('podcast-read',3600,600,6000),('podcast-generate',3600,20,200),('podcast-download',3600,60,1000)
 on conflict(route) do nothing;

-- ---------------------------------------------------------------------------
-- C. Provider admission for podcast routes
-- ---------------------------------------------------------------------------
-- 034's begin, extended with podcast routes. A podcast route is only granted
-- inside worker_podcast_attempt_begin (transaction-local token), which derives
-- the model, units and ceiling from the immutable profile: no caller-supplied
-- provider/model string can select a cheaper quote.
create or replace function public.worker_provider_attempt_begin(p_account_id uuid,p_operation_id uuid,p_attempt_id uuid,
 p_provider text,p_route text,p_model text,p_request_sha256 bytea,p_ceiling_microusd bigint,p_reserved_units jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare op app_private.metered_operations; pol app_private.provider_spending_policy; prior app_private.provider_attempts;
 allowance app_private.provider_allowance_periods; daily app_private.provider_allowance_days;
 reason text; used bigint; units bigint; v_bucket text; day_key date:=(now() at time zone 'UTC')::date; snapshot jsonb;
 podcast_route boolean:=p_route in ('podcast_script','podcast_review','podcast_speech');
begin
 if p_attempt_id is null or p_provider not in ('anthropic','tavily','mathpix','google') or p_provider is null
  or p_route is null or p_model is null or p_model !~ '^[a-zA-Z0-9./_-]{1,128}$'
  or octet_length(p_request_sha256) is distinct from 32 or p_ceiling_microusd is null or p_ceiling_microusd not between 0 and 30000000
  or not app_private.valid_provider_units(p_reserved_units) then raise exception 'invalid_provider_attempt'; end if;
 if not ((p_provider='anthropic' and p_route in ('chat','catalog_tags','podcast_script','podcast_review'))
  or (p_provider='tavily' and p_route in ('chat_search','ingest_lookup','reference_lookup'))
  or (p_provider='mathpix' and p_route='paper_ocr') or (p_provider='google' and p_route='podcast_speech')) then raise exception 'invalid_provider_route'; end if;
 if podcast_route and current_setting('app_private.podcast_attempt',true) is distinct from p_attempt_id::text then
  raise exception 'podcast_admission_required';
 end if;
 op:=app_private.provider_lock_operation(p_account_id,p_operation_id);
 if podcast_route<>(op.kind='podcast') then raise exception 'invalid_provider_route'; end if;
 select * into strict pol from app_private.provider_spending_policy where singleton;
 select * into prior from app_private.provider_attempts where id=p_attempt_id;
 if found then
  if (prior.account_id,prior.operation_id,prior.provider,prior.route,prior.model,prior.request_sha256,prior.ceiling_microusd,prior.reserved_units)
   is distinct from (p_account_id,p_operation_id,p_provider,p_route,p_model,p_request_sha256,p_ceiling_microusd,p_reserved_units)
  then raise exception 'provider_attempt_id_conflict'; end if;
  return jsonb_build_object('granted',false,'state',prior.state,'reason','attempt_replayed');
 end if;
 if (select count(*) from app_private.provider_attempts)>=pol.attempt_limit
  or (select count(*) from app_private.provider_attempts where account_id=p_account_id)>=pol.account_attempt_limit
  or (select count(*) from app_private.provider_attempts where account_id=p_account_id and operation_id=p_operation_id)>=pol.operation_attempt_limit
 then return jsonb_build_object('granted',false,'state','denied','reason','attempt_capacity'); end if;
 if not exists(select 1 from app_private.accounts where id=p_account_id and closed_at is null and not spending_suspended) then reason:='account_unavailable';
 elsif not pol.enabled or not exists(select 1 from app_private.platform_budgets where period=op.period and work_enabled) then reason:='platform_paused';
 elsif not op.attempt_accounting and op.created_at<(select coverage_started_at from app_private.provider_spending_policy where singleton) then reason:='legacy_operation';
 elsif p_provider='anthropic' and coalesce((p_reserved_units->>'web_searches')::bigint,0)>0 then reason:='native_search_unbounded';
 elsif op.state='settled' and not (p_provider='tavily' and p_route='ingest_lookup' and p_ceiling_microusd=0 and op.created_at>now()-interval '15 minutes')
 then reason:='operation_settled'; end if;
 select coalesce(sum(case when state in ('admitted','unknown') then ceiling_microusd else coalesce(actual_microusd,0) end),0)
  into used from app_private.provider_attempts where account_id=p_account_id and operation_id=p_operation_id;
 if reason is null and used+p_ceiling_microusd>op.spend_ceiling_microusd then reason:='operation_ceiling'; end if;
 if p_provider='tavily' then
  if p_reserved_units<>jsonb_build_object('credits',1) or p_ceiling_microusd<>0 or p_model<>'search-basic' then raise exception 'invalid_search_reservation'; end if;
  units:=1; v_bucket:=case when p_route='chat_search' then 'chat' else 'lookup' end;
  if reason is null then
   select * into allowance from app_private.provider_allowance_periods
    where provider='tavily' and starts_at<=now() and ends_at>now() and enabled for update;
   if not found then reason:='provider_allowance_unverified';
   elsif allowance.baseline_units+allowance.spent_units+allowance.reserved_units+units>allowance.limit_units then reason:='provider_allowance_exhausted'; end if;
  end if;
  if reason is null then
   insert into app_private.provider_allowance_days(account_id,day,bucket) values(p_account_id,day_key,v_bucket) on conflict do nothing;
   select * into strict daily from app_private.provider_allowance_days where account_id=p_account_id and day=day_key and provider_allowance_days.bucket=v_bucket for update;
   if daily.spent_units+daily.reserved_units+units>(case when v_bucket='chat' then pol.chat_search_daily else pol.lookup_search_daily end)
   then reason:='account_provider_allowance'; end if;
  end if;
 end if;
 snapshot:=case when podcast_route then jsonb_build_object('version','provider-bounds-20261008-podcast-v1','credit_rate_version',op.rate_version,
   'ceiling_microusd',p_ceiling_microusd,'profile',current_setting('app_private.podcast_profile',true),
   'tariff',case p_provider when 'google' then 'vertex-gemini-3.8-flash-tts-list-20270101' else 'anthropic-token-rates-20261007' end,
   'rates_microusd',case p_provider when 'google' then jsonb_build_object('text_input',1,'audio_output',18)
    else jsonb_build_object('sonnet',jsonb_build_object('input',2,'output',10)) end)
  else jsonb_build_object('version','provider-bounds-20261007-v1','credit_rate_version',op.rate_version,
  'ceiling_microusd',p_ceiling_microusd,'tariff',case p_provider when 'tavily' then 'prepaid-basic-one-credit-no-overage'
   when 'mathpix' then 'pdf-page-cap-5000-microusd' else 'anthropic-token-rates-20261007' end,
  'rates_microusd',case p_provider when 'mathpix' then jsonb_build_object('page',5000) when 'tavily' then jsonb_build_object('prepaid_credit',0,'customer_list_credit',8000)
   else jsonb_build_object('sonnet',jsonb_build_object('input',2,'output',10,'cache_write_5m',2.5,'cache_write_1h',4,'cache_read',0.2),
    'haiku',jsonb_build_object('input',1,'output',5,'cache_write_5m',1.25,'cache_read',0.1),
    'fallback',jsonb_build_object('input',4,'output',20,'cache_write_5m',5,'cache_write_1h',8,'cache_read',0.4)) end) end;
 insert into app_private.provider_attempts(id,account_id,operation_id,provider,route,model,request_sha256,ceiling_microusd,reserved_units,
  state,failure_code,pricing_snapshot,allowance_period_id,allowance_day,allowance_bucket)
 values(p_attempt_id,p_account_id,p_operation_id,p_provider,p_route,p_model,p_request_sha256,p_ceiling_microusd,p_reserved_units,
  case when reason is null then 'admitted' else 'denied' end,reason,snapshot,
  case when reason is null then allowance.id end,case when reason is null and allowance.id is not null then day_key end,
  case when reason is null and allowance.id is not null then v_bucket end);
 insert into app_private.provider_attempt_events(attempt_id,state,details) values(p_attempt_id,
  case when reason is null then 'admitted' else 'denied' end,jsonb_build_object('reason',reason,'ceiling_microusd',p_ceiling_microusd,'reserved_units',p_reserved_units));
 if reason is null then
  update app_private.metered_operations set attempt_accounting=true where account_id=p_account_id and id=p_operation_id;
 end if;
 if reason is null and allowance.id is not null then
  update app_private.provider_allowance_periods set reserved_units=reserved_units+units where id=allowance.id;
  update app_private.provider_allowance_days set reserved_units=reserved_units+units where account_id=p_account_id and day=day_key and provider_allowance_days.bucket=v_bucket;
 end if;
 return jsonb_build_object('granted',reason is null,'state',case when reason is null then 'admitted' else 'denied' end,'reason',reason);
end $$;

-- ---------------------------------------------------------------------------
-- D. Internal helpers
-- ---------------------------------------------------------------------------
create function app_private.podcast_spec() returns jsonb
language sql stable security definer set search_path='' as $$
 select pr.spec from app_private.podcast_policy p join app_private.podcast_profiles pr on (pr.id,pr.version)=(p.profile_id,p.profile_version) where p.singleton
$$;

-- A length the reader may choose: its allowlisted version, or the default (five
-- minutes) when the caller names none. Anything else is podcast_profile_unavailable.
create function app_private.podcast_allowed_spec(p_profile text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare pol app_private.podcast_policy; entry text; spec jsonb;
begin
 select * into strict pol from app_private.podcast_policy where singleton;
 if p_profile is not null and p_profile !~ '^[a-z][a-z0-9-]{2,47}$' then raise exception 'podcast_profile_unavailable'; end if;
 select e into entry from unnest(pol.allowed_profiles) e where split_part(e,':',1)=coalesce(p_profile,pol.profile_id);
 if entry is null then raise exception 'podcast_profile_unavailable'; end if;
 select pr.spec into spec from app_private.podcast_profiles pr where pr.id=split_part(entry,':',1) and pr.version=split_part(entry,':',2)::integer;
 if spec is null then raise exception 'podcast_profile_unavailable'; end if;
 return spec;
end $$;

create function app_private.podcast_label(p_spec jsonb) returns text language sql immutable set search_path='' as $$
 select coalesce(p_spec->>'label',round((p_spec->>'target_seconds')::numeric/60)::text||' min')
$$;

-- The lengths offered for private generation, shortest first, with each one's maximum.
create function app_private.podcast_lengths() returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('profile',pr.id,'label',app_private.podcast_label(pr.spec),
   'target_seconds',(pr.spec->>'target_seconds')::integer,'max_credits',(pr.spec->>'max_credits')::integer,
   'estimate','Estimate — you''re charged actual usage, maximum '||(pr.spec->>'max_credits')||' credits')
  order by (pr.spec->>'target_seconds')::integer),'[]'::jsonb)
 from app_private.podcast_policy p cross join unnest(p.allowed_profiles) e
  join app_private.podcast_profiles pr on pr.id=split_part(e,':',1) and pr.version=split_part(e,':',2)::integer
 where p.singleton
$$;

create function app_private.podcast_month() returns date language sql stable set search_path='' as $$
 select date_trunc('month',now() at time zone 'UTC')::date
$$;

create function app_private.podcast_event(p_job uuid,p_kind text,p_details jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path='' as $$
begin
 -- Bounded per job: stage/claim/attempt records, never content or raw errors.
 if (select count(*) from app_private.podcast_job_events where job_id=p_job)>=128 then return; end if;
 insert into app_private.podcast_job_events(job_id,kind,details) values(p_job,p_kind,coalesce(p_details,'{}'::jsonb));
end $$;

-- Financial locks first (034's provider_lock_operation), then the podcast
-- policy (shared, so quarantine's update serializes), then the job row.
create function app_private.podcast_lock_job(p_job uuid) returns app_private.podcast_jobs
language plpgsql security definer set search_path='' as $$
declare j app_private.podcast_jobs; locked app_private.podcast_jobs;
begin
 select * into j from app_private.podcast_jobs where id=p_job;
 if not found then raise exception 'podcast_job_unavailable'; end if;
 if j.operation_id is not null then perform app_private.provider_lock_operation(j.operation_account_id,j.operation_id);
 elsif j.actor_id is not null then perform 1 from app_private.accounts where id=j.actor_id for update; end if;
 perform 1 from app_private.podcast_policy where singleton for share;
 select * into strict locked from app_private.podcast_jobs where id=p_job for update;
 if (locked.operation_account_id,locked.operation_id) is distinct from (j.operation_account_id,j.operation_id) then raise exception 'podcast_job_changed'; end if;
 return locked;
end $$;

create function app_private.podcast_fenced(p_job uuid,p_claim uuid,p_generation bigint) returns app_private.podcast_jobs
language plpgsql security definer set search_path='' as $$
declare j app_private.podcast_jobs;
begin
 j:=app_private.podcast_lock_job(p_job);
 if j.claim_id is distinct from p_claim or j.claim_generation is distinct from p_generation or j.lease_until<=clock_timestamp()
 then raise exception 'stale_podcast_claim'; end if;
 if j.epoch<>(select epoch from app_private.podcast_policy where singleton) then raise exception 'podcast_epoch_changed'; end if;
 return j;
end $$;

-- Shared rights: current, active, and pinned to the job's captured revision.
create function app_private.podcast_rights_current(p_episode uuid,p_revision bigint) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.podcast_rights r where r.episode_id=p_episode and r.state='active'
  and (p_revision is null or r.rights_revision=p_revision))
$$;

-- Committed seed spend for a period: unsettled operations hold their whole
-- ceiling; settled ones hold known expense plus every unresolved attempt ceiling.
create function app_private.podcast_seed_committed(p_period date) returns bigint
language sql stable security definer set search_path='' as $$
 select coalesce(sum(case when op.state<>'settled' then op.spend_ceiling_microusd else
   (select coalesce(sum(case when a.state in ('admitted','unknown') then a.ceiling_microusd else coalesce(a.actual_microusd,0) end),0)
    from app_private.provider_attempts a where (a.account_id,a.operation_id)=(op.account_id,op.id)) end),0)::bigint
 from app_private.podcast_jobs j join app_private.metered_operations op on (op.account_id,op.id)=(j.operation_account_id,j.operation_id)
 where j.funding_kind='platform_seed' and j.seed_period=p_period
$$;

-- Seed episodes counted against the period's episode cap: every admitted seed
-- job except one that ended without any admitted provider call.
create function app_private.podcast_seed_episodes(p_period date) returns integer
language sql stable security definer set search_path='' as $$
 select count(*)::integer from app_private.podcast_jobs j
 where j.funding_kind='platform_seed' and j.seed_period=p_period
  and (j.finished_at is null or j.state='ready' or exists(select 1 from app_private.podcast_job_attempts ja
   join app_private.provider_attempts pa on pa.id=ja.attempt_id where ja.job_id=j.id and pa.state<>'denied'))
$$;

-- Server-side pin resolution for an account's library item. The caller cannot
-- assemble individually valid IDs: every relation is joined here.
create function app_private.podcast_item_pin(p_account uuid,p_item uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r record;
begin
 select li.document_id,d.sha256 doc_sha,d.scope doc_scope,li.approval_id,ca.version_id,ca.metadata_id,ra.id artifact_id,
  o.id ocr_run_id,mo.id raw_manifest_id,mo.sha256 raw_manifest_sha,t.id text_id,t.sha256 text_sha,t.byte_count text_bytes
 into r from app_private.library_items li join app_private.documents d on d.id=li.document_id
  join app_private.render_artifacts ra on ra.id=li.artifact_id join app_private.ocr_runs o on o.id=ra.ocr_run_id and o.document_id=li.document_id
  join app_private.stored_objects mo on mo.id=o.raw_bundle_object_id and mo.state='verified' and mo.document_id=li.document_id
  join app_private.paper_asset_manifest_members m on m.manifest_object_id=mo.id and m.relative_path='standalone.mmd'
  join app_private.stored_objects t on t.id=m.object_id and t.state='verified' and t.document_id=li.document_id
  left join app_private.catalog_asset_approvals ca on ca.id=li.approval_id and ca.document_id=li.document_id
 where li.account_id=p_account and li.id=p_item and li.removed_at is null and (d.scope='shared_catalog' or d.owner_id=p_account);
 if not found then return null; end if;
 return jsonb_build_object('document_id',r.document_id,'document_sha256',encode(r.doc_sha,'hex'),'document_scope',r.doc_scope,
  'approval_id',r.approval_id,'version_id',r.version_id,'metadata_id',r.metadata_id,'artifact_id',r.artifact_id,'ocr_run_id',r.ocr_run_id,
  'raw_manifest_object_id',r.raw_manifest_id,'raw_manifest_sha256',encode(r.raw_manifest_sha,'hex'),
  'text_object_id',r.text_id,'text_sha256',encode(r.text_sha,'hex'),'text_bytes',r.text_bytes,'normalization_version','mathpix-standalone-mmd-v1');
end $$;

-- Shared seed pin: a current CC BY 4.0 / CC0 approval and its exact converted text.
create function app_private.podcast_approval_pin(p_approval uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r record;
begin
 select ca.document_id,d.sha256 doc_sha,ca.id approval_id,ca.version_id,ca.metadata_id,ca.license_uri,ra.id artifact_id,o.id ocr_run_id,
  mo.id raw_manifest_id,mo.sha256 raw_manifest_sha,t.id text_id,t.sha256 text_sha,t.byte_count text_bytes
 into r from app_private.catalog_asset_approvals ca join app_private.documents d on d.id=ca.document_id and d.scope='shared_catalog'
  join app_private.ocr_runs o on o.document_id=ca.document_id
  join app_private.stored_objects mo on mo.id=o.raw_bundle_object_id and mo.state='verified' and mo.document_id=ca.document_id
  join app_private.paper_asset_manifest_members m on m.manifest_object_id=mo.id and m.relative_path='standalone.mmd'
  join app_private.stored_objects t on t.id=m.object_id and t.state='verified' and t.document_id=ca.document_id
  join app_private.render_artifacts ra on ra.ocr_run_id=o.id
  join app_private.stored_objects ro on ro.id=ra.manifest_object_id and ro.state='verified'
 where ca.id=p_approval order by ra.ready_at desc limit 1;
 if not found then return null; end if;
 return jsonb_build_object('document_id',r.document_id,'document_sha256',encode(r.doc_sha,'hex'),'document_scope','shared_catalog',
  'approval_id',r.approval_id,'version_id',r.version_id,'metadata_id',r.metadata_id,'license_uri',r.license_uri,'artifact_id',r.artifact_id,
  'ocr_run_id',r.ocr_run_id,'raw_manifest_object_id',r.raw_manifest_id,'raw_manifest_sha256',encode(r.raw_manifest_sha,'hex'),
  'text_object_id',r.text_id,'text_sha256',encode(r.text_sha,'hex'),'text_bytes',r.text_bytes,'normalization_version','mathpix-standalone-mmd-v1');
end $$;

-- Domain-separated work key: ordered source pins, scope/owner, profile and voices.
create function app_private.podcast_work_key(p_scope text,p_owner uuid,p_spec jsonb,p_pin jsonb) returns bytea
language sql immutable set search_path='' as $$
 select sha256(convert_to(jsonb_build_array('gradstep/podcast-work/v1',p_scope,p_owner,p_spec->>'id',(p_spec->>'version')::integer,
  p_spec->>'language',(p_spec->>'target_seconds')::integer,p_spec->'speech'->>'model',p_spec->'speech'->'voices',
  -- Labeled synthetic fixtures never share a work key with a generated episode.
  coalesce(p_spec->'fixture','false'::jsonb),
  jsonb_build_array(jsonb_build_array(p_pin->>'document_id',p_pin->>'document_sha256',p_pin->>'approval_id',p_pin->>'version_id',
   p_pin->>'metadata_id',p_pin->>'ocr_run_id',p_pin->>'raw_manifest_sha256',p_pin->>'text_sha256',p_pin->>'artifact_id',
   p_pin->>'normalization_version')))::text,'UTF8'))
$$;

create function app_private.podcast_insert_episode(p_scope text,p_owner uuid,p_spec jsonb,p_pin jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare key bytea:=app_private.podcast_work_key(p_scope,p_owner,p_spec,p_pin); episode uuid;
begin
 if p_scope='shared' then
  insert into app_private.podcast_episode_keys(scope,owner_id,work_sha256,profile_id,profile_version)
   values('shared',null,key,p_spec->>'id',(p_spec->>'version')::integer) on conflict do nothing;
  select id into strict episode from app_private.podcast_episode_keys where scope='shared' and work_sha256=key;
 else
  insert into app_private.podcast_episode_keys(scope,owner_id,work_sha256,profile_id,profile_version)
   values('private',p_owner,key,p_spec->>'id',(p_spec->>'version')::integer) on conflict do nothing;
  select id into strict episode from app_private.podcast_episode_keys where scope='private' and owner_id=p_owner and work_sha256=key;
 end if;
 insert into app_private.podcast_sources(episode_id,ordinal,document_id,document_sha256,approval_id,version_id,metadata_id,ocr_run_id,
  raw_manifest_object_id,raw_manifest_sha256,text_object_id,text_sha256,text_bytes,artifact_id,normalization_version)
 values(episode,0,(p_pin->>'document_id')::uuid,decode(p_pin->>'document_sha256','hex'),(p_pin->>'approval_id')::uuid,(p_pin->>'version_id')::uuid,
  (p_pin->>'metadata_id')::uuid,(p_pin->>'ocr_run_id')::uuid,(p_pin->>'raw_manifest_object_id')::uuid,decode(p_pin->>'raw_manifest_sha256','hex'),
  (p_pin->>'text_object_id')::uuid,decode(p_pin->>'text_sha256','hex'),(p_pin->>'text_bytes')::bigint,(p_pin->>'artifact_id')::uuid,p_pin->>'normalization_version')
 on conflict do nothing;
 return episode;
end $$;

-- Optional immediate wake-up through pg_net, as the paper pipeline does. The
-- worker serves /podcast separately; absence of pg_net/Vault is a no-op.
create function app_private.podcast_kick() returns void language plpgsql security definer set search_path='' as $$
declare url text; secret text;
begin
 if to_regnamespace('net') is null or to_regnamespace('vault') is null then return; end if;
 begin
  execute 'select decrypted_secret from vault.decrypted_secrets where name=$1' into url using 'science_reader_pipeline_url';
  execute 'select decrypted_secret from vault.decrypted_secrets where name=$1' into secret using 'science_reader_pipeline_secret';
  if url is null or secret is null then return; end if;
  execute 'select net.http_post(url:=$1,body:=$2,headers:=$3,timeout_milliseconds:=1000)'
   using rtrim(url,'/')||'/podcast','{"reason":"podcast"}'::jsonb,jsonb_build_object('content-type','application/json','x-pipeline-secret',secret);
 exception when others then null;
 end;
end $$;

-- Terminal financial outcome, applied once while the caller holds the job lock
-- (and therefore the budget/account/operation locks before it).
create function app_private.podcast_settle(j app_private.podcast_jobs,p_state text,p_failure text,p_quality boolean default false) returns app_private.podcast_jobs
language plpgsql security definer set search_path='' as $$
declare known bigint:=0; credits bigint:=0; op app_private.metered_operations; result app_private.podcast_jobs;
begin
 if p_state not in ('ready','canceled','failed','unknown_provider','quarantined') then raise exception 'invalid_podcast_outcome'; end if;
 if j.operation_id is not null then
  select * into strict op from app_private.metered_operations where account_id=j.operation_account_id and id=j.operation_id;
  select coalesce(sum(actual_microusd) filter(where state in ('succeeded','rejected','reconciled')),0) into known
   from app_private.provider_attempts where account_id=j.operation_account_id and operation_id=j.operation_id;
  -- Customers pay known usage for a delivered or a deliberately canceled job,
  -- capped by the disclosed maximum; quality failures and our own interruptions
  -- charge zero and the retained expense stays platform-funded.
  if j.funding_kind='customer' and p_state in ('ready','canceled') then credits:=least(op.credit_ceiling,ceil(known/5000.0)::bigint); end if;
  if op.state<>'settled' then perform public.worker_settle_operation(j.operation_account_id,j.operation_id,credits,known); end if;
 end if;
 update app_private.podcast_jobs set state=p_state,stage_entered_at=clock_timestamp(),failure_code=p_failure,
  claim_id=null,lease_until=null,charged_credits=case when j.funding_kind='customer' then credits end,
  quality_loss_microusd=case when j.funding_kind='customer' and p_quality then known else 0 end,
  platform_loss_microusd=case when j.funding_kind='customer' and credits=0 then known else 0 end,
  finished_at=case when p_state in ('ready','canceled','failed') then clock_timestamp() end
 where id=j.id returning * into result;
 -- Future storage reservations are returned; planned/pending objects stay inventoried.
 delete from app_private.podcast_asset_holds where job_id=j.id;
 -- Working drafts never outlive the job.
 delete from app_private.podcast_job_checkpoints where job_id=j.id;
 perform app_private.podcast_event(j.id,'settled',jsonb_build_object('state',p_state,'failure',p_failure,'known_microusd',known,'credits',credits,'quality',p_quality));
 return result;
end $$;

create function app_private.podcast_job_public(j app_private.podcast_jobs,p_request uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('request_id',p_request,'state',j.state,'stage_entered_at',j.stage_entered_at,
  'release_id',(select r.id from app_private.podcast_releases r where r.job_id=j.id and r.state in ('ready','pending_review')),
  'held_credits',case when op.state='settled' then 0 else op.credit_ceiling end,
  'charged_credits',case when op.state='settled' then op.actual_credits end,
  'released_credits',case when op.state='settled' then op.credit_ceiling-op.actual_credits end,
  'failure',j.failure_code,'cancel_requested',j.cancel_requested,
  'profile',(select k.profile_id from app_private.podcast_episode_keys k where k.id=j.episode_id))
 from app_private.metered_operations op where (op.account_id,op.id)=(j.operation_account_id,j.operation_id)
$$;

-- Public, cross-user-safe release metadata (shared) or owner-only fields (private).
create function app_private.podcast_episode_public(r app_private.podcast_releases) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('release_id',r.id,'scope',r.scope,'state',r.state,'fixture',r.origin='fixture','ai_audio',true,'language','en',
  'duration_ms',r.duration_ms,'published_at',r.published_at,
  'document_id',(select s.document_id from app_private.podcast_sources s where s.episode_id=r.episode_id and s.ordinal=0),
  'title',r.public_metadata->>'title','year',(r.public_metadata->>'year')::integer,'authors',coalesce(r.public_metadata->'authors','[]'::jsonb),
  'topic',r.public_metadata->>'topic','source',coalesce(r.public_metadata->'source',jsonb_build_object('arxiv_id',null,'version',null,'url',null,'license',null)),
  'audio',(select jsonb_build_object('bytes',o.byte_count,'sha256',encode(o.sha256,'hex'),'media_type',o.media_type)
   from app_private.podcast_release_objects ro join app_private.stored_objects o on o.id=ro.object_id where ro.release_id=r.id and ro.role='audio'),
  'replacement_id',r.replacement_id,
  'profile',(select k.profile_id from app_private.podcast_episode_keys k where k.id=r.episode_id),
  'label',(select app_private.podcast_label(pr.spec) from app_private.podcast_episode_keys k join app_private.podcast_profiles pr
    on (pr.id,pr.version)=(k.profile_id,k.profile_version) where k.id=r.episode_id),
  'target_seconds',(select (pr.spec->>'target_seconds')::integer from app_private.podcast_episode_keys k join app_private.podcast_profiles pr
    on (pr.id,pr.version)=(k.profile_id,k.profile_version) where k.id=r.episode_id))
$$;

-- Platform-funded losses of customer jobs this month: known costs charged zero
-- credits plus every unresolved provider ceiling still held for such jobs.
create function app_private.podcast_customer_losses(p_month date) returns bigint
language sql stable security definer set search_path='' as $$
 select coalesce(sum(j.platform_loss_microusd+coalesce((select sum(a.ceiling_microusd) from app_private.provider_attempts a
   where (a.account_id,a.operation_id)=(j.operation_account_id,j.operation_id) and a.state in ('admitted','unknown')),0)),0)::bigint
 from app_private.podcast_jobs j where j.funding_kind='customer' and j.created_at>=p_month
  and (j.finished_at is not null or j.state in ('unknown_provider','quarantined'))
$$;

-- An account whose earlier private job still holds an unknown provider outcome
-- cannot start another until it is reconciled (no overlapping unknown work).
create function app_private.podcast_account_unresolved(p_account uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.podcast_jobs j join app_private.provider_attempts a
   on (a.account_id,a.operation_id)=(j.operation_account_id,j.operation_id)
  where j.funding_kind='customer' and j.operation_account_id=p_account and j.state='unknown_provider' and a.state in ('admitted','unknown'))
$$;

-- Whether an account can play this release now (rights, scope, policy).
create function app_private.podcast_release_visible(p_account uuid,r app_private.podcast_releases) returns boolean
language sql stable security definer set search_path='' as $$
 select r.state='ready' and case when r.scope='private' then r.owner_id=p_account
  else (select catalog_enabled from app_private.podcast_policy where singleton) and app_private.podcast_rights_current(r.episode_id,null) end
$$;

-- Podcast enablement needs a scope-3 certified, enforced, reconciled inventory.
create function app_private.podcast_inventory_certified() returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.paper_asset_policy where enforced and inventory_scope=3 and inventory_verified_at is not null
  and inventory_discrepancies=0 and reconciliation_id is null)
$$;

-- Bounded audio transfer: separate podcast counters per account and
-- environment, also charged to 035's shared reader environment capacity.
create function app_private.podcast_transfer_adjust(p_account uuid,p_period date,p_reserved bigint,p_authorized bigint,
 p_upstream bigint default 0,p_response bigint default 0,p_environment_only boolean default false) returns void
language plpgsql security definer set search_path='' as $$
declare pol app_private.podcast_policy; rpol app_private.reader_delivery_policy; r app_private.reader_transfer_months; maximum bigint; s text;
begin
 select * into strict rpol from app_private.reader_delivery_policy where singleton for update;
 select * into strict pol from app_private.podcast_policy where singleton;
 -- Account deletion has already erased the account's own counters: only the
 -- environment totals are released then (never a re-created negative row).
 foreach s in array case when p_environment_only then array['environment'] else array['environment',p_account::text] end loop
  maximum:=case when s='environment' then pol.environment_transfer_bytes_month
   when exists(select 1 from app_private.entitlements e where e.account_id=p_account and e.state in ('active','grace') and e.expires_at>now())
    then pol.paid_account_transfer_bytes_month else pol.account_transfer_bytes_month end;
  insert into app_private.reader_transfer_months(period,scope_id,kind) values(p_period,s,'podcast') on conflict do nothing;
  update app_private.reader_transfer_months set reserved_bytes=reserved_bytes+p_reserved,authorized_bytes=authorized_bytes+p_authorized,
   upstream_bytes=upstream_bytes+p_upstream,response_bytes=response_bytes+p_response where (period,scope_id,kind)=(p_period,s,'podcast') returning * into r;
  if p_reserved+p_authorized>0 and r.reserved_bytes+r.authorized_bytes>maximum then raise exception 'podcast_transfer_limit'; end if;
 end loop;
 insert into app_private.reader_transfer_months(period,scope_id,kind) values(p_period,'environment','reader') on conflict do nothing;
 update app_private.reader_transfer_months set reserved_bytes=reserved_bytes+p_reserved,authorized_bytes=authorized_bytes+p_authorized,
  upstream_bytes=upstream_bytes+p_upstream,response_bytes=response_bytes+p_response where (period,scope_id,kind)=(p_period,'environment','reader') returning * into r;
 if p_reserved+p_authorized>0 and r.reserved_bytes+r.authorized_bytes>rpol.environment_bytes_month then raise exception 'podcast_transfer_limit'; end if;
end $$;

create function app_private.podcast_transfer_remaining(p_account uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 with pol as (select * from app_private.podcast_policy where singleton),
 lim as (select case when exists(select 1 from app_private.entitlements e where e.account_id=p_account and e.state in ('active','grace') and e.expires_at>now())
   then pol.paid_account_transfer_bytes_month else pol.account_transfer_bytes_month end v from pol),
 used as (select coalesce(sum(reserved_bytes+authorized_bytes),0) v from app_private.reader_transfer_months
   where period=app_private.podcast_month() and scope_id=p_account::text and kind='podcast')
 select jsonb_build_object('limit_bytes',lim.v,'remaining_bytes',greatest(0,lim.v-used.v)) from lim,used
$$;

-- Snapshot of public source attribution for a shared release (no requester data).
create function app_private.podcast_public_metadata(p_episode uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('title',left(cm.metadata->>'title',500),
  'year',case when cm.metadata->>'published_at' ~ '^[0-9]{4}' then substr(cm.metadata->>'published_at',1,4)::integer end,
  'authors',coalesce((select jsonb_agg(a) from (select left(value,200) a from jsonb_array_elements_text(case when jsonb_typeof(cm.metadata->'authors')='array'
    then cm.metadata->'authors' else '[]'::jsonb end) limit 20) x),'[]'::jsonb),
  'topic',coalesce((select t.tags[1] from app_private.catalog_tags t where t.version_id=s.version_id and cardinality(t.tags)>0),
   cm.metadata->'categories'->>0),
  'source',jsonb_build_object('arxiv_id',case when cm.source_id ~ '^([0-9]{4}\.[0-9]{4,5}|[a-z-]+(\.[A-Z]{2})?/[0-9]{7})$' then cm.source_id end,
   'version',cm.source_revision,
   'url',case when cm.source_id ~ '^([0-9]{4}\.[0-9]{4,5}|[a-z-]+(\.[A-Z]{2})?/[0-9]{7})$' then 'https://arxiv.org/abs/'||cm.source_id||'v'||cm.source_revision end,
   'license',r.license_uri))
 from app_private.podcast_sources s join app_private.catalog_metadata cm on cm.id=s.metadata_id
  join app_private.podcast_rights r on r.episode_id=s.episode_id
 where s.episode_id=p_episode and s.ordinal=0
$$;

-- ---------------------------------------------------------------------------
-- E. Operator controls (owner account; MFA is enforced by the admin Edge path)
-- ---------------------------------------------------------------------------
create function public.worker_podcast_policy_set(p_actor uuid,p_request_id uuid,p_changes jsonb,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.podcast_policy; prior app_private.podcast_policy_events; item record; enabling boolean:=false;
begin
 perform app_private.require_owner_account(p_actor);
 if p_request_id is null or p_changes is null or jsonb_typeof(p_changes)<>'object' or p_changes='{}'::jsonb or octet_length(p_changes::text)>2048
  or p_reason is null or length(trim(p_reason)) not between 3 and 500 then raise exception 'invalid_podcast_policy'; end if;
 -- Podcast policy before storage capacity, as every other podcast path.
 select * into strict pol from app_private.podcast_policy where singleton for update;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 select * into prior from app_private.podcast_policy_events where id=p_request_id;
 if found then
  if prior.changes<>p_changes or prior.actor_id<>p_actor then raise exception 'podcast_policy_id_conflict'; end if;
  return to_jsonb(pol)||jsonb_build_object('replayed',true);
 end if;
 for item in select key,value from jsonb_each(p_changes) loop
  if item.key in ('catalog_enabled','delivery_enabled','generation_enabled','seed_enabled','fixtures_enabled') then
   if jsonb_typeof(item.value)<>'boolean' then raise exception 'invalid_podcast_policy'; end if;
   enabling:=enabling or (item.value::text='true' and item.key<>'catalog_enabled');
  elsif item.key in ('max_active_private_per_account','max_active_environment','max_jobs_day_environment','quality_allocation_microusd',
   'account_transfer_bytes_month','paid_account_transfer_bytes_month','environment_transfer_bytes_month') then
   if jsonb_typeof(item.value)<>'number' or item.value::text !~ '^[0-9]{1,12}$' then raise exception 'invalid_podcast_policy'; end if;
  elsif item.key='allowed_profiles' then
   -- Lengths offered for private generation ('id:version'); the trigger checks each names a profile.
   if jsonb_typeof(item.value)<>'array' or jsonb_array_length(item.value) not between 1 and 8
    or exists(select 1 from jsonb_array_elements(item.value) e where jsonb_typeof(e)<>'string') then raise exception 'invalid_podcast_policy'; end if;
  else raise exception 'invalid_podcast_policy'; end if;
 end loop;
 if enabling and not app_private.podcast_inventory_certified() then raise exception 'asset_inventory_incomplete'; end if;
 update app_private.podcast_policy set
  catalog_enabled=coalesce((p_changes->>'catalog_enabled')::boolean,catalog_enabled),
  delivery_enabled=coalesce((p_changes->>'delivery_enabled')::boolean,delivery_enabled),
  generation_enabled=coalesce((p_changes->>'generation_enabled')::boolean,generation_enabled),
  seed_enabled=coalesce((p_changes->>'seed_enabled')::boolean,seed_enabled),
  fixtures_enabled=coalesce((p_changes->>'fixtures_enabled')::boolean,fixtures_enabled),
  max_active_private_per_account=coalesce((p_changes->>'max_active_private_per_account')::integer,max_active_private_per_account),
  max_active_environment=coalesce((p_changes->>'max_active_environment')::integer,max_active_environment),
  max_jobs_day_environment=coalesce((p_changes->>'max_jobs_day_environment')::integer,max_jobs_day_environment),
  quality_allocation_microusd=coalesce((p_changes->>'quality_allocation_microusd')::bigint,quality_allocation_microusd),
  account_transfer_bytes_month=coalesce((p_changes->>'account_transfer_bytes_month')::bigint,account_transfer_bytes_month),
  paid_account_transfer_bytes_month=coalesce((p_changes->>'paid_account_transfer_bytes_month')::bigint,paid_account_transfer_bytes_month),
  environment_transfer_bytes_month=coalesce((p_changes->>'environment_transfer_bytes_month')::bigint,environment_transfer_bytes_month),
  allowed_profiles=coalesce((select array_agg(e order by n) from jsonb_array_elements_text(p_changes->'allowed_profiles') with ordinality x(e,n)),allowed_profiles),
  revision=revision+1,updated_at=now()
 where singleton returning * into pol;
 insert into app_private.podcast_policy_events(id,actor_id,changes,reason,revision) values(p_request_id,p_actor,p_changes,trim(p_reason),pol.revision);
 return to_jsonb(pol)||jsonb_build_object('replayed',false);
end $$;

-- A dated seed allowance. The approved v1 ceiling is $2 per period at most.
create function public.worker_podcast_seed_period(p_actor uuid,p_request_id uuid,p_period date,p_limit_microusd bigint,p_enabled boolean,p_evidence text,
 p_max_episodes integer default 2) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s app_private.podcast_seed_periods; changes jsonb; prior app_private.podcast_policy_events;
begin
 perform app_private.require_owner_account(p_actor);
 if p_request_id is null or p_period is null or extract(day from p_period)<>1 or p_limit_microusd is null or p_limit_microusd not between 0 and 2000000
  or p_enabled is null or p_evidence is null or length(p_evidence) not between 3 and 256 or p_evidence !~ '^[a-zA-Z0-9._:/ -]+$'
  or p_max_episodes is null or p_max_episodes not between 0 and 2
 then raise exception 'invalid_seed_period'; end if;
 perform 1 from app_private.platform_budgets where period=p_period for update;
 if not found then raise exception 'platform_budget_unavailable'; end if;
 perform 1 from app_private.podcast_policy where singleton for update;
 changes:=jsonb_build_object('seed_period',p_period,'limit_microusd',p_limit_microusd,'enabled',p_enabled,'evidence',p_evidence,'max_episodes',p_max_episodes);
 select * into prior from app_private.podcast_policy_events where id=p_request_id;
 if found then
  if prior.changes<>changes or prior.actor_id<>p_actor then raise exception 'podcast_policy_id_conflict'; end if;
  select * into strict s from app_private.podcast_seed_periods where period=p_period;
  return to_jsonb(s)||jsonb_build_object('committed_microusd',app_private.podcast_seed_committed(p_period),'replayed',true);
 end if;
 if p_enabled and not app_private.podcast_inventory_certified() then raise exception 'asset_inventory_incomplete'; end if;
 insert into app_private.podcast_seed_periods(period,limit_microusd,max_episodes,enabled,evidence_reference,configured_by)
  values(p_period,p_limit_microusd,p_max_episodes,p_enabled,p_evidence,p_actor)
  on conflict(period) do update set limit_microusd=excluded.limit_microusd,max_episodes=excluded.max_episodes,enabled=excluded.enabled,
   evidence_reference=excluded.evidence_reference,configured_by=excluded.configured_by,configured_at=now()
  returning * into s;
 insert into app_private.podcast_policy_events(id,actor_id,changes,reason,revision)
  values(p_request_id,p_actor,changes,'Seed allowance '||p_evidence,(select revision from app_private.podcast_policy where singleton));
 return to_jsonb(s)||jsonb_build_object('committed_microusd',app_private.podcast_seed_committed(p_period),'replayed',false);
end $$;

-- Operator-approved shared episode funded from the seed allowance and the
-- operator's own account with zero customer credits. Also records the revocable
-- publication approval pinned to the exact source bytes.
create function public.worker_podcast_seed_admit(p_actor uuid,p_request_id uuid,p_approval_id uuid,p_reason text,p_fixture boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare month date:=app_private.podcast_month(); pol app_private.podcast_policy; seed app_private.podcast_seed_periods; spec jsonb; pin jsonb;
 episode uuid; j app_private.podcast_jobs; op uuid; digest bytea; rights app_private.podcast_rights;
begin
 perform app_private.require_owner_account(p_actor);
 if p_request_id is null or p_approval_id is null or p_reason is null or length(trim(p_reason)) not between 3 and 500 or p_fixture is null
 then raise exception 'invalid_podcast_seed'; end if;
 select * into j from app_private.podcast_jobs where id=p_request_id;
 if found then
  if j.actor_id<>p_actor or j.origin<>(case when p_fixture then 'fixture' else 'generated' end)
   or not exists(select 1 from app_private.podcast_sources s where s.episode_id=j.episode_id and s.approval_id=p_approval_id)
  then raise exception 'podcast_seed_id_conflict'; end if;
  return to_jsonb(j)||jsonb_build_object('replayed',true);
 end if;
 -- Budget -> account -> provider policy -> podcast policy -> seed period.
 perform 1 from app_private.platform_budgets where period=month for update;
 perform 1 from app_private.accounts where id=p_actor and closed_at is null and not spending_suspended for update;
 if not found then raise exception 'account_unavailable'; end if;
 perform 1 from app_private.provider_spending_policy where singleton for update;
 select * into strict pol from app_private.podcast_policy where singleton for update;
 if not app_private.podcast_inventory_certified() then raise exception 'asset_inventory_incomplete'; end if;
 if (not p_fixture and not pol.seed_enabled) or (p_fixture and not pol.fixtures_enabled) then raise exception 'podcast_unavailable'; end if;
 spec:=app_private.podcast_spec();
 -- Decision 2: seeds are the approved five-minute episodes only; other lengths are private generation.
 if spec->>'id' !~ '^podcast-5min-v[0-9]+$' or (spec->>'target_seconds')::integer<>300 then raise exception 'seed_profile_unavailable'; end if;
 if p_fixture then spec:=spec||jsonb_build_object('fixture',true); end if;
 pin:=app_private.podcast_approval_pin(p_approval_id);
 if pin is null then raise exception 'source_unavailable'; end if;
 if (pin->>'text_bytes')::bigint>(spec->>'max_source_bytes')::bigint then raise exception 'source_too_large'; end if;
 if (select count(*) from app_private.podcast_jobs where state in ('queued','scripting','checking','synthesizing','verifying','publishing'))>=pol.max_active_environment
  then raise exception 'podcast_busy'; end if;
 if (select count(*) from app_private.podcast_jobs where created_at>now()-interval '1 day')>=pol.max_jobs_day_environment then raise exception 'podcast_daily_limit'; end if;
 if not p_fixture then
  select * into seed from app_private.podcast_seed_periods where period=month for update;
  if not found or not seed.enabled then raise exception 'seed_allowance_unavailable'; end if;
  if app_private.podcast_seed_committed(month)+(spec->>'hold_microusd')::bigint>seed.limit_microusd then raise exception 'seed_allowance_exhausted'; end if;
  if app_private.podcast_seed_episodes(month)>=seed.max_episodes then raise exception 'seed_episode_limit'; end if;
 end if;
 episode:=app_private.podcast_insert_episode('shared',null,spec,pin);
 if exists(select 1 from app_private.podcast_releases where episode_id=episode and state in ('ready','pending_review')) then raise exception 'podcast_already_published'; end if;
 if exists(select 1 from app_private.podcast_jobs where episode_id=episode and state in ('queued','scripting','checking','synthesizing','verifying','publishing','capacity_wait'))
  then raise exception 'podcast_job_active'; end if;
 select * into rights from app_private.podcast_rights where episode_id=episode for update;
 if not found then
  insert into app_private.podcast_rights(episode_id,state,approval_id,license_uri,evidence_sha256,reviewer_id)
   values(episode,'active',p_approval_id,pin->>'license_uri',
    sha256(convert_to(jsonb_build_array('gradstep/podcast-rights/v1',p_approval_id,pin->>'document_sha256',trim(p_reason))::text,'UTF8')),p_actor)
   returning * into rights;
  insert into app_private.podcast_rights_events(id,episode_id,actor_id,state,rights_revision,reason)
   values(p_request_id,episode,p_actor,'active',rights.rights_revision,trim(p_reason));
 elsif rights.state<>'active' then raise exception 'rights_unavailable'; end if;
 if not p_fixture then
  op:=gen_random_uuid();
  digest:=sha256(convert_to(jsonb_build_array('gradstep/podcast-seed/v1',p_request_id,encode(app_private.podcast_work_key('shared',null,spec,pin),'hex'))::text,'UTF8'));
  perform public.worker_reserve_operation(p_actor,op,'podcast',digest,'beta-credits-v1',0,(spec->>'hold_microusd')::bigint);
 end if;
 insert into app_private.podcast_jobs(id,episode_id,origin,funding_kind,operation_account_id,operation_id,actor_id,reason,seed_period,epoch,rights_revision)
  values(p_request_id,episode,case when p_fixture then 'fixture' else 'generated' end,case when p_fixture then 'fixture' else 'platform_seed' end,
   case when op is not null then p_actor end,op,p_actor,trim(p_reason),case when p_fixture then null else month end,pol.epoch,rights.rights_revision)
  returning * into j;
 insert into app_private.podcast_asset_holds(job_id,owner_id,bytes,objects)
  values(j.id,null,(spec->'storage'->>'bytes')::bigint,(spec->'storage'->>'objects')::integer);
 begin perform app_private.paper_asset_check_capacity(null);
 exception when raise_exception then
  if sqlerrm='paper_storage_capacity' then raise exception 'storage_full'; end if; raise;
 end;
 perform app_private.podcast_event(j.id,'admitted',jsonb_build_object('funding',j.funding_kind,'hold_microusd',case when p_fixture then 0 else (spec->>'hold_microusd')::bigint end));
 perform app_private.podcast_kick();
 return to_jsonb(j)||jsonb_build_object('replayed',false,'seed_committed_microusd',case when p_fixture then null else app_private.podcast_seed_committed(month) end);
end $$;

-- Curated releases need an operator's review record before the catalog shows them.
create function public.worker_podcast_review(p_actor uuid,p_request_id uuid,p_release_id uuid,p_decision text,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r app_private.podcast_releases;
begin
 perform app_private.require_owner_account(p_actor);
 if p_request_id is null or p_decision is null or p_decision not in ('publish','reject') or p_reason is null or length(trim(p_reason)) not between 3 and 500
 then raise exception 'invalid_podcast_review'; end if;
 select * into r from app_private.podcast_releases where id=p_release_id for update;
 if not found or r.scope<>'shared' then raise exception 'podcast_release_unavailable'; end if;
 if (p_decision='publish' and r.state='ready') or (p_decision='reject' and r.state='withdrawn') then
  return app_private.podcast_episode_public(r)||jsonb_build_object('replayed',true);
 end if;
 if r.state<>'pending_review' then raise exception 'podcast_release_state'; end if;
 perform 1 from app_private.podcast_policy where singleton for share;
 if p_decision='publish' and (select epoch from app_private.podcast_jobs where id=r.job_id)<>(select epoch from app_private.podcast_policy where singleton)
 then raise exception 'podcast_epoch_changed'; end if;
 if p_decision='publish' then
  if not app_private.podcast_rights_current(r.episode_id,null) then raise exception 'rights_unavailable'; end if;
  update app_private.podcast_releases set state='ready',published_seq=nextval('app_private.podcast_publication_seq'),published_at=now(),reviewed_by=p_actor
   where id=r.id returning * into r;
 else
  update app_private.podcast_releases set state='withdrawn',reviewed_by=p_actor where id=r.id returning * into r;
 end if;
 perform app_private.podcast_event(r.job_id,'reviewed',jsonb_build_object('decision',p_decision,'actor_id',p_actor,'request_id',p_request_id));
 return app_private.podcast_episode_public(r)||jsonb_build_object('replayed',false);
end $$;

-- Takedown/quarantine without rewriting financial history or the immutable approval.
create function public.worker_podcast_rights(p_actor uuid,p_request_id uuid,p_episode_id uuid,p_state text,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r app_private.podcast_rights; prior app_private.podcast_rights_events;
begin
 perform app_private.require_owner_account(p_actor);
 if p_request_id is null or p_state is null or p_state not in ('active','quarantined','withdrawn') or p_reason is null or length(trim(p_reason)) not between 3 and 500
 then raise exception 'invalid_podcast_rights'; end if;
 select * into r from app_private.podcast_rights where episode_id=p_episode_id for update;
 if not found then raise exception 'podcast_release_unavailable'; end if;
 select * into prior from app_private.podcast_rights_events where id=p_request_id;
 if found then
  if prior.episode_id<>p_episode_id or prior.state<>p_state then raise exception 'podcast_rights_id_conflict'; end if;
  return to_jsonb(r)||jsonb_build_object('replayed',true);
 end if;
 if r.state='withdrawn' and p_state<>'withdrawn' then raise exception 'rights_withdrawn'; end if;
 update app_private.podcast_rights set state=p_state,rights_revision=rights_revision+1,updated_at=now() where episode_id=p_episode_id returning * into r;
 insert into app_private.podcast_rights_events(id,episode_id,actor_id,state,rights_revision,reason) values(p_request_id,p_episode_id,p_actor,p_state,r.rights_revision,trim(p_reason));
 return to_jsonb(r)||jsonb_build_object('replayed',false);
end $$;

-- ---------------------------------------------------------------------------
-- F. Customer API (authenticated; public metadata only)
-- ---------------------------------------------------------------------------
create function app_private.podcast_capabilities(a uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('catalog',p.catalog_enabled,'delivery',p.delivery_enabled,
  'generation',p.generation_enabled and app_private.podcast_inventory_certified()
   and exists(select 1 from app_private.accounts x where x.id=a and x.closed_at is null and not x.spending_suspended),
  'max_credits',(app_private.podcast_spec()->>'max_credits')::integer,'target_seconds',(app_private.podcast_spec()->>'target_seconds')::integer,
  'lengths',app_private.podcast_lengths(),
  'transfer',app_private.podcast_transfer_remaining(a))
 from app_private.podcast_policy p where p.singleton
$$;

create function public.v1_podcast_capabilities() returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor();
begin
 perform public.worker_consume_request(a,'podcast-read');
 return app_private.podcast_capabilities(a);
end $$;

create function public.v1_podcast_catalog(p_after text default null,p_limit integer default 20) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); after_seq bigint; rows jsonb;
begin
 perform public.worker_consume_request(a,'podcast-read');
 if p_limit is null or p_limit not between 1 and 50 or (p_after is not null and p_after !~ '^[1-9][0-9]{0,17}$') then raise exception 'invalid_podcast_cursor'; end if;
 after_seq:=coalesce(p_after::bigint,9223372036854775807);
 if not (select catalog_enabled from app_private.podcast_policy where singleton) then
  return jsonb_build_object('episodes','[]'::jsonb,'next',null,'capabilities',app_private.podcast_capabilities(a));
 end if;
 select coalesce(jsonb_agg(app_private.podcast_episode_public(r) order by r.published_seq desc),'[]'::jsonb) into rows from (
  select x.* from app_private.podcast_releases x where x.scope='shared' and x.state='ready' and x.published_seq<after_seq
   and app_private.podcast_rights_current(x.episode_id,null) order by x.published_seq desc limit p_limit) r;
 return jsonb_build_object('episodes',rows,
  'next',case when jsonb_array_length(rows)=p_limit then (select min(x.published_seq)::text from app_private.podcast_releases x
   where x.id in (select (e->>'release_id')::uuid from jsonb_array_elements(rows) e)) end,
  'capabilities',app_private.podcast_capabilities(a));
end $$;

-- The best playable episode for one library item: the account's own private
-- release, else a ready shared release of the exact same document bytes.
create function public.v1_podcast_paper(p_item_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); doc uuid; r app_private.podcast_releases; j app_private.podcast_jobs; req uuid; lengths jsonb;
begin
 perform public.worker_consume_request(a,'podcast-read');
 select document_id into doc from app_private.library_items where account_id=a and id=p_item_id and removed_at is null;
 if not found then raise exception 'source_unavailable'; end if;
 select x.* into r from app_private.podcast_releases x join app_private.podcast_sources s on s.episode_id=x.episode_id and s.ordinal=0
  where s.document_id=doc and x.scope='private' and x.owner_id=a and x.state='ready' order by x.published_seq desc limit 1;
 if not found then
  select x.* into r from app_private.podcast_releases x join app_private.podcast_sources s on s.episode_id=x.episode_id and s.ordinal=0
   where s.document_id=doc and x.scope='shared' and x.state='ready' and app_private.podcast_rights_current(x.episode_id,null)
    and (select catalog_enabled from app_private.podcast_policy where singleton)
   order by x.published_seq desc limit 1;
 end if;
 select x.* into j from app_private.podcast_jobs x join app_private.podcast_episode_keys k on k.id=x.episode_id and k.scope='private' and k.owner_id=a
  join app_private.podcast_sources s on s.episode_id=x.episode_id and s.ordinal=0
  where s.document_id=doc and x.funding_kind='customer' and x.finished_at is null order by x.created_at desc limit 1;
 if j.id is not null then select request_id into req from app_private.podcast_requests where account_id=a and job_id=j.id order by created_at limit 1; end if;
 -- Every playable length for this paper (each length is its own work key): the
 -- account's newest private release per length, else the newest shared one.
 select coalesce(jsonb_agg(app_private.podcast_episode_public(z.release) order by z.seconds),'[]'::jsonb) into lengths
  from (select distinct on (k.profile_id) x as release,(pr.spec->>'target_seconds')::integer seconds from app_private.podcast_releases x
    join app_private.podcast_episode_keys k on k.id=x.episode_id join app_private.podcast_sources s on s.episode_id=x.episode_id and s.ordinal=0
    join app_private.podcast_profiles pr on (pr.id,pr.version)=(k.profile_id,k.profile_version)
   where s.document_id=doc and x.state='ready' and ((x.scope='private' and x.owner_id=a)
    or (x.scope='shared' and app_private.podcast_rights_current(x.episode_id,null) and (select catalog_enabled from app_private.podcast_policy where singleton)))
   order by k.profile_id,(x.scope='private') desc,x.published_seq desc) z;
 return jsonb_build_object('episode',case when r.id is not null then app_private.podcast_episode_public(r) end,'episodes',lengths,
  'job',case when j.id is not null then app_private.podcast_job_public(j,req) end,'capabilities',app_private.podcast_capabilities(a));
end $$;

-- p_profile names a length (podcast-short-v1, podcast-5min-v1, podcast-10min-v1,
-- podcast-20min-v1); omitted means five minutes (older clients). Each length is its
-- own work key: a ready episode of another length is never reused for this one.
create function public.v1_podcast_quote(p_item_id uuid,p_request_id uuid,p_profile text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); pol app_private.podcast_policy; spec jsonb; pin jsonb; key bytea; q app_private.podcast_quotes;
 r app_private.podcast_releases; j app_private.podcast_jobs; req uuid; qspec jsonb;
begin
 perform public.worker_consume_request(a,'podcast-generate');
 if p_item_id is null or p_request_id is null then raise exception 'invalid_podcast_request'; end if;
 select * into strict pol from app_private.podcast_policy where singleton;
 if not pol.generation_enabled or not app_private.podcast_inventory_certified() then raise exception 'podcast_unavailable'; end if;
 if not exists(select 1 from app_private.accounts where id=a and closed_at is null and not spending_suspended) then raise exception 'account_unavailable'; end if;
 spec:=app_private.podcast_allowed_spec(p_profile);
 select * into q from app_private.podcast_quotes where account_id=a and request_id=p_request_id;
 if found then
  if q.item_id<>p_item_id or q.profile_id<>spec->>'id' then raise exception 'podcast_request_conflict'; end if;
  if q.expires_at<=now() then raise exception 'quote_expired'; end if;
 else
  pin:=app_private.podcast_item_pin(a,p_item_id);
  if pin is null then raise exception 'source_unavailable'; end if;
  if (pin->>'text_bytes')::bigint>(spec->>'max_source_bytes')::bigint then raise exception 'source_too_large'; end if;
  key:=app_private.podcast_work_key('private',a,spec,pin);
  select x.* into r from app_private.podcast_releases x join app_private.podcast_episode_keys k on k.id=x.episode_id
   where k.scope='private' and k.owner_id=a and k.work_sha256=key and x.state='ready' limit 1;
  if found then return jsonb_build_object('reuse',jsonb_build_object('release_id',r.id)); end if;
  select x.* into j from app_private.podcast_jobs x join app_private.podcast_episode_keys k on k.id=x.episode_id
   where k.scope='private' and k.owner_id=a and k.work_sha256=key and x.finished_at is null and x.state not in ('unknown_provider','quarantined') limit 1;
  if found then
   select request_id into req from app_private.podcast_requests where account_id=a and job_id=j.id order by created_at limit 1;
   return jsonb_build_object('join',jsonb_build_object('request_id',req));
  end if;
  if app_private.podcast_account_unresolved(a) then raise exception 'podcast_outcome_pending'; end if;
  if (select count(*) from app_private.podcast_quotes where account_id=a and created_at>now()-interval '1 day')>=50 then raise exception 'request_rate_limit'; end if;
  insert into app_private.podcast_quotes(account_id,request_id,item_id,work_sha256,pin,profile_id,profile_version,max_credits,max_microusd,epoch,consent_version,expires_at)
   values(a,p_request_id,p_item_id,key,pin,spec->>'id',(spec->>'version')::integer,(spec->>'max_credits')::bigint,(spec->>'hold_microusd')::bigint,
    pol.epoch,spec->>'consent_version',now()+interval '15 minutes') returning * into q;
 end if;
 select pr.spec into strict qspec from app_private.podcast_profiles pr where (pr.id,pr.version)=(q.profile_id,q.profile_version);
 return jsonb_build_object('quote',jsonb_build_object('id',q.id,'expires_at',q.expires_at,'max_credits',q.max_credits,
  'estimate','Estimate — you''re charged actual usage, maximum '||q.max_credits||' credits',
  'providers',jsonb_build_array('Anthropic (script)','Google Vertex AI (speech)'),'consent_version',q.consent_version,
  'target_seconds',(qspec->>'target_seconds')::integer,'profile',q.profile_id,'label',app_private.podcast_label(qspec)),
  'options',app_private.podcast_lengths());
end $$;

create function public.v1_podcast_start(p_quote_id uuid,p_request_id uuid,p_consent_version text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); month date:=app_private.podcast_month(); pol app_private.podcast_policy; q app_private.podcast_quotes;
 prior app_private.podcast_requests; spec jsonb; pin jsonb; episode uuid; r app_private.podcast_releases; j app_private.podcast_jobs; op uuid; req uuid;
begin
 perform public.worker_consume_request(a,'podcast-generate');
 if p_quote_id is null or p_request_id is null then raise exception 'invalid_podcast_request'; end if;
 select * into prior from app_private.podcast_requests where account_id=a and request_id=p_request_id;
 if found then
  if prior.quote_id<>p_quote_id then raise exception 'podcast_request_conflict'; end if;
  if prior.outcome='reused' then return jsonb_build_object('reuse',jsonb_build_object('release_id',prior.release_id)); end if;
  select * into strict j from app_private.podcast_jobs where id=prior.job_id;
  return jsonb_build_object('job',app_private.podcast_job_public(j,p_request_id));
 end if;
 if p_consent_version is distinct from 'podcast-private-v1' then raise exception 'consent_required'; end if;
 -- Budget -> account -> provider policy -> podcast policy, as every financial path.
 perform 1 from app_private.platform_budgets where period=month for update;
 perform 1 from app_private.accounts where id=a and closed_at is null and not spending_suspended for update;
 if not found then raise exception 'account_unavailable'; end if;
 perform 1 from app_private.provider_spending_policy where singleton for update;
 select * into strict pol from app_private.podcast_policy where singleton for update;
 if not pol.generation_enabled or not app_private.podcast_inventory_certified() then raise exception 'podcast_unavailable'; end if;
 select * into q from app_private.podcast_quotes where id=p_quote_id and account_id=a;
 if not found then raise exception 'quote_unavailable'; end if;
 if q.expires_at<=now() or q.epoch<>pol.epoch then raise exception 'quote_expired'; end if;
 -- The quoted length, still offered (an operator may have withdrawn it since).
 spec:=app_private.podcast_allowed_spec(q.profile_id);
 -- The quote never authorizes later changes to its source or options.
 pin:=app_private.podcast_item_pin(a,q.item_id);
 if pin is distinct from q.pin or app_private.podcast_work_key('private',a,spec,pin)<>q.work_sha256
  or (spec->>'id',(spec->>'version')::integer)<>(q.profile_id,q.profile_version) then raise exception 'quote_expired'; end if;
 select x.* into r from app_private.podcast_releases x join app_private.podcast_episode_keys k on k.id=x.episode_id
  where k.scope='private' and k.owner_id=a and k.work_sha256=q.work_sha256 and x.state='ready' limit 1;
 if found then
  insert into app_private.podcast_requests(account_id,request_id,quote_id,release_id,outcome) values(a,p_request_id,q.id,r.id,'reused');
  return jsonb_build_object('reuse',jsonb_build_object('release_id',r.id));
 end if;
 select x.* into j from app_private.podcast_jobs x join app_private.podcast_episode_keys k on k.id=x.episode_id
  where k.scope='private' and k.owner_id=a and k.work_sha256=q.work_sha256 and x.finished_at is null and x.state not in ('unknown_provider','quarantined') for update of x;
 if found then
  insert into app_private.podcast_requests(account_id,request_id,quote_id,job_id,outcome) values(a,p_request_id,q.id,j.id,'joined');
  return jsonb_build_object('job',app_private.podcast_job_public(j,p_request_id));
 end if;
 if (select count(*) from app_private.podcast_jobs x join app_private.podcast_episode_keys k on k.id=x.episode_id
   where k.owner_id=a and x.funding_kind='customer' and x.state in ('queued','scripting','checking','synthesizing','verifying','publishing','capacity_wait'))>=pol.max_active_private_per_account
  then raise exception 'active_generation_limit'; end if;
 if (select count(*) from app_private.podcast_jobs where state in ('queued','scripting','checking','synthesizing','verifying','publishing'))>=pol.max_active_environment
  then raise exception 'podcast_busy'; end if;
 if (select count(*) from app_private.podcast_jobs where created_at>now()-interval '1 day')>=pol.max_jobs_day_environment then raise exception 'podcast_daily_limit'; end if;
 if app_private.podcast_customer_losses(month)>=pol.quality_allocation_microusd then raise exception 'podcast_paused'; end if;
 if app_private.podcast_account_unresolved(a) then raise exception 'podcast_outcome_pending'; end if;
 op:=gen_random_uuid();
 perform public.worker_reserve_operation(a,op,'podcast',sha256(convert_to(jsonb_build_array('gradstep/podcast-private/v1',a,p_request_id,q.id,encode(q.work_sha256,'hex'))::text,'UTF8')),
  'beta-credits-v1',q.max_credits,q.max_microusd);
 episode:=app_private.podcast_insert_episode('private',a,spec,pin);
 insert into app_private.podcast_jobs(episode_id,origin,funding_kind,operation_account_id,operation_id,epoch)
  values(episode,'generated','customer',a,op,pol.epoch) returning * into j;
 update app_private.podcast_jobs set kicked_at=clock_timestamp() where id=j.id returning * into j;
 insert into app_private.podcast_asset_holds(job_id,owner_id,bytes,objects)
  values(j.id,a,(spec->'storage'->>'bytes')::bigint,(spec->'storage'->>'objects')::integer);
 begin perform app_private.paper_asset_check_capacity(a);
 exception when raise_exception then
  if sqlerrm in ('paper_storage_capacity','paper_owner_storage_capacity') then raise exception 'storage_full'; end if; raise;
 end;
 insert into app_private.podcast_requests(account_id,request_id,quote_id,job_id,outcome) values(a,p_request_id,q.id,j.id,'started');
 perform app_private.podcast_event(j.id,'admitted',jsonb_build_object('funding','customer','hold_credits',q.max_credits,'hold_microusd',q.max_microusd));
 perform app_private.podcast_kick();
 return jsonb_build_object('job',app_private.podcast_job_public(j,p_request_id));
end $$;

create function public.v1_podcast_status(p_request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); req app_private.podcast_requests; j app_private.podcast_jobs;
begin
 perform public.worker_consume_request(a,'podcast-read');
 select * into req from app_private.podcast_requests where account_id=a and request_id=p_request_id;
 if not found then raise exception 'podcast_request_unavailable'; end if;
 if req.outcome='reused' then return jsonb_build_object('reuse',jsonb_build_object('release_id',req.release_id)); end if;
 select * into strict j from app_private.podcast_jobs where id=req.job_id;
 -- Polling is the recovery wake-up (no always-on loop): a queued job or an
 -- expired lease asks the worker again, at most once a minute.
 if j.finished_at is null and ((j.claim_id is null and j.state in ('queued','checking','synthesizing')) or j.lease_until<=clock_timestamp())
  and (j.kicked_at is null or j.kicked_at<clock_timestamp()-interval '60 seconds') then
  perform 1 from app_private.podcast_jobs where id=j.id for update skip locked;
  if found then
   update app_private.podcast_jobs set kicked_at=clock_timestamp() where id=j.id and (kicked_at is null or kicked_at<clock_timestamp()-interval '60 seconds');
   if found then perform app_private.podcast_kick(); end if;
  end if;
 end if;
 return jsonb_build_object('job',app_private.podcast_job_public(j,p_request_id));
end $$;

-- Operator/maintenance wake-up for queued or expired work (seed pilot, lost kicks).
create function public.worker_podcast_kick_due() returns jsonb
language plpgsql security definer set search_path='' as $$
declare due integer;
begin
 select count(*) into due from app_private.podcast_jobs where finished_at is null
  and ((claim_id is null and state in ('queued','checking','synthesizing')) or (claim_id is not null and lease_until<=clock_timestamp()));
 if due>0 then perform app_private.podcast_kick(); end if;
 return jsonb_build_object('due',due);
end $$;

create function public.v1_podcast_cancel(p_request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); req app_private.podcast_requests; j app_private.podcast_jobs;
begin
 perform public.worker_consume_request(a,'podcast-generate');
 select * into req from app_private.podcast_requests where account_id=a and request_id=p_request_id;
 if not found or req.job_id is null then raise exception 'podcast_request_unavailable'; end if;
 j:=app_private.podcast_lock_job(req.job_id);
 if j.finished_at is null and j.state not in ('unknown_provider','quarantined') then
  if j.state='queued' and j.claim_id is null and not exists(select 1 from app_private.podcast_job_attempts where job_id=j.id) then
   -- Before submission: release the whole hold and detach.
   j:=app_private.podcast_settle(j,'canceled','canceled_by_owner');
  elsif j.claim_id is null and j.state in ('checking','synthesizing') then
   -- Parked between stages (nothing in flight): stop now; recorded usage is charged within the maximum.
   j:=app_private.podcast_settle(j,'canceled','canceled_by_owner');
  elsif not j.cancel_requested then
   -- During work: stop future paid calls; known usage settles within the maximum.
   update app_private.podcast_jobs set cancel_requested=true where id=j.id returning * into j;
   perform app_private.podcast_event(j.id,'cancel_requested',jsonb_build_object('request_id',p_request_id));
  end if;
 end if;
 return jsonb_build_object('job',app_private.podcast_job_public(j,p_request_id));
end $$;

-- Revocation/correction status for cached releases. Unknown or other owners'
-- private releases are indistinguishable ("unavailable").
create function public.v1_podcast_states(p_release_ids uuid[]) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb:='{}'::jsonb; rid uuid; r app_private.podcast_releases; rights app_private.podcast_rights;
begin
 perform public.worker_consume_request(a,'podcast-read');
 if p_release_ids is null or cardinality(p_release_ids) not between 1 and 100 then raise exception 'invalid_podcast_request'; end if;
 foreach rid in array p_release_ids loop
  select * into r from app_private.podcast_releases x where x.id=rid;
  if not found or (r.scope='private' and r.owner_id<>a) or r.state='pending_review' then
   result:=result||jsonb_build_object(rid::text,jsonb_build_object('state','unavailable','replacement_id',null)); continue;
  end if;
  select * into rights from app_private.podcast_rights x where x.episode_id=r.episode_id;
  result:=result||jsonb_build_object(rid::text,jsonb_build_object('state',
   case when r.scope='shared' and rights.state<>'active' then rights.state
    when r.scope='shared' and r.state='ready' and not (select catalog_enabled from app_private.podcast_policy where singleton) then 'unavailable'
    else r.state end,'replacement_id',r.replacement_id));
 end loop;
 return jsonb_build_object('states',result);
end $$;

-- ---------------------------------------------------------------------------
-- G. Worker lifecycle (service role; one job row locked per transaction)
-- ---------------------------------------------------------------------------
create function app_private.podcast_job_spec(j app_private.podcast_jobs) returns jsonb
language sql stable security definer set search_path='' as $$
 select pr.spec from app_private.podcast_episode_keys k join app_private.podcast_profiles pr on (pr.id,pr.version)=(k.profile_id,k.profile_version)
 where k.id=j.episode_id
$$;

-- Speech succeeds only when every planned chunk did (speech_calls is fixed at the first speech grant).
create function app_private.podcast_route_succeeded(p_job uuid,p_route text) returns boolean
language sql stable security definer set search_path='' as $$
 select case when p_route='podcast_speech' then
   coalesce((select j.speech_calls from app_private.podcast_jobs j where j.id=p_job),0)>0
   and (select count(*) from app_private.podcast_job_attempts ja join app_private.provider_attempts pa on pa.id=ja.attempt_id
     where ja.job_id=p_job and ja.route='podcast_speech' and pa.state in ('succeeded','reconciled'))
    =(select j.speech_calls from app_private.podcast_jobs j where j.id=p_job)
  else exists(select 1 from app_private.podcast_job_attempts ja join app_private.provider_attempts pa on pa.id=ja.attempt_id
  where ja.job_id=p_job and ja.route=p_route and pa.state in ('succeeded','reconciled')) end
$$;

-- Where an unclaimed job can safely continue: 'queued' when no paid call was ever
-- admitted; for a staged job, the stage after its newest checkpoint when every
-- admitted call succeeded and its output is in that checkpoint; otherwise null
-- (a paid result that was never checkpointed is lost, never re-bought).
create function app_private.podcast_resume_state(j app_private.podcast_jobs) returns text
language plpgsql stable security definer set search_path='' as $$
begin
 if not exists(select 1 from app_private.podcast_job_attempts ja join app_private.provider_attempts pa on pa.id=ja.attempt_id
  where ja.job_id=j.id and pa.state<>'denied') then return 'queued'; end if;
 if j.origin<>'generated' or not coalesce((app_private.podcast_job_spec(j)->>'staged')::boolean,false)
  or exists(select 1 from app_private.podcast_job_attempts ja join app_private.provider_attempts pa on pa.id=ja.attempt_id
   where ja.job_id=j.id and pa.state not in ('denied','succeeded','reconciled'))
  or exists(select 1 from app_private.podcast_job_attempts ja join app_private.provider_attempts pa on pa.id=ja.attempt_id
   where ja.job_id=j.id and ja.route='podcast_speech' and pa.state<>'denied') then return null; end if;
 if exists(select 1 from app_private.podcast_job_checkpoints c where c.job_id=j.id and c.stage='script')
  and app_private.podcast_route_succeeded(j.id,'podcast_review') then return 'synthesizing'; end if;
 if exists(select 1 from app_private.podcast_job_checkpoints c where c.job_id=j.id and c.stage='draft')
  and app_private.podcast_route_succeeded(j.id,'podcast_script')
  and not exists(select 1 from app_private.podcast_job_attempts ja join app_private.provider_attempts pa on pa.id=ja.attempt_id
   where ja.job_id=j.id and ja.route='podcast_review' and pa.state<>'denied') then return 'checking'; end if;
 return null;
end $$;

-- Releases the claim and parks the job where it can continue (a later worker
-- request claims it again). Caller holds the job lock.
create function app_private.podcast_park(j app_private.podcast_jobs,p_state text,p_reason text) returns app_private.podcast_jobs
language plpgsql security definer set search_path='' as $$
begin
 if p_state not in ('queued','checking','synthesizing') then raise exception 'invalid_podcast_stage'; end if;
 update app_private.podcast_jobs set state=p_state,stage_entered_at=clock_timestamp(),claim_id=null,lease_until=null where id=j.id returning * into j;
 perform app_private.podcast_event(j.id,case when p_state='queued' then 'requeued' else 'parked' end,jsonb_build_object('reason',p_reason,'state',p_state));
 return j;
end $$;

-- An expired lease is not evidence that a vendor did no work. Admitted attempts
-- become unknown liabilities; nothing paid is ever re-sent automatically. A staged
-- job resumes from its last checkpoint; anything else that already paid ends.
create function app_private.podcast_recover(j app_private.podcast_jobs) returns app_private.podcast_jobs
language plpgsql security definer set search_path='' as $$
declare a record; resume text;
begin
 for a in select pa.* from app_private.podcast_job_attempts ja join app_private.provider_attempts pa on pa.id=ja.attempt_id
  where ja.job_id=j.id and pa.state='admitted' order by pa.id loop
  perform public.worker_provider_attempt_finish(a.account_id,a.operation_id,a.id,'unknown',null,null,'{}','worker_interrupted');
 end loop;
 if exists(select 1 from app_private.podcast_job_attempts ja join app_private.provider_attempts pa on pa.id=ja.attempt_id
  where ja.job_id=j.id and pa.state='unknown') then
  return app_private.podcast_settle(j,'unknown_provider','provider_outcome_unknown');
 end if;
 resume:=app_private.podcast_resume_state(j);
 if resume is null then return app_private.podcast_settle(j,'failed','worker_interrupted'); end if;
 if resume<>'queued' and j.cancel_requested then return app_private.podcast_settle(j,'canceled','canceled_by_owner'); end if;
 return app_private.podcast_park(j,resume,case when resume='queued' then 'lease_expired_before_paid_work' else 'lease_expired_after_checkpoint' end);
end $$;

create function public.worker_podcast_recover() returns jsonb
language plpgsql security definer set search_path='' as $$
declare candidate uuid; j app_private.podcast_jobs;
begin
 select id into candidate from app_private.podcast_jobs where claim_id is not null and lease_until<=clock_timestamp() order by lease_until,id limit 1;
 if candidate is null then return jsonb_build_object('recovered',false); end if;
 j:=app_private.podcast_lock_job(candidate);
 if j.claim_id is null or j.lease_until>clock_timestamp() then return jsonb_build_object('recovered',false,'more',true); end if;
 j:=app_private.podcast_recover(j);
 return jsonb_build_object('recovered',true,'job_id',j.id,'state',j.state,'more',true);
end $$;

create function public.worker_podcast_claim(p_claim_id uuid,p_generated boolean default true) returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.podcast_policy; candidate uuid; j app_private.podcast_jobs; spec jsonb; src app_private.podcast_sources; t app_private.stored_objects;
 meta jsonb; resumed boolean; resume jsonb;
begin
 if p_claim_id is null then raise exception 'invalid_podcast_claim'; end if;
 select * into strict pol from app_private.podcast_policy where singleton;
 -- Queued work, or a staged job parked after a checkpoint (oldest first, so work in flight finishes first).
 select x.id into candidate from app_private.podcast_jobs x where x.claim_id is null
  and (x.state='queued' or (x.state in ('checking','synthesizing') and exists(select 1 from app_private.podcast_job_checkpoints c where c.job_id=x.id)))
  and ((x.funding_kind='customer' and pol.generation_enabled) or (x.funding_kind='platform_seed' and pol.seed_enabled) or (x.funding_kind='fixture' and pol.fixtures_enabled))
  and (x.origin='fixture' or coalesce(p_generated,false))
  order by x.created_at,x.id limit 1;
 if candidate is null then return jsonb_build_object('claimed',false); end if;
 j:=app_private.podcast_lock_job(candidate);
 if j.claim_id is not null or j.finished_at is not null or j.state not in ('queued','checking','synthesizing') then return jsonb_build_object('claimed',false,'more',true); end if;
 resumed:=j.state<>'queued';
 -- A scan in progress would refuse this job's uploads after its paid calls.
 if (select reconciliation_id is not null from app_private.paper_asset_policy where singleton for share) then
  return jsonb_build_object('claimed',false,'reason','asset_inventory_reconciling');
 end if;
 if j.epoch<>(select epoch from app_private.podcast_policy where singleton) then
  j:=app_private.podcast_settle(j,'failed','podcast_epoch_changed'); return jsonb_build_object('claimed',false,'more',true);
 end if;
 if j.cancel_requested then j:=app_private.podcast_settle(j,'canceled','canceled_by_owner'); return jsonb_build_object('claimed',false,'more',true); end if;
 if exists(select 1 from app_private.podcast_episode_keys k where k.id=j.episode_id and k.scope='shared')
  and not app_private.podcast_rights_current(j.episode_id,j.rights_revision) then
  j:=app_private.podcast_settle(j,'failed','rights_changed'); return jsonb_build_object('claimed',false,'more',true);
 end if;
 if j.operation_id is not null and not exists(select 1 from app_private.accounts where id=j.operation_account_id and closed_at is null and not spending_suspended) then
  j:=app_private.podcast_settle(j,'failed','account_unavailable'); return jsonb_build_object('claimed',false,'more',true);
 end if;
 select * into strict src from app_private.podcast_sources where episode_id=j.episode_id and ordinal=0;
 select * into t from app_private.stored_objects where id=src.text_object_id and state='verified' and sha256=src.text_sha256 and byte_count=src.text_bytes;
 if not found then j:=app_private.podcast_settle(j,'failed','source_unavailable'); return jsonb_build_object('claimed',false,'more',true); end if;
 if resumed then
  -- Only the exact stage its checkpoint covers; anything else already ended the job.
  if app_private.podcast_resume_state(j) is distinct from j.state then
   j:=app_private.podcast_settle(j,'failed','checkpoint_unavailable'); return jsonb_build_object('claimed',false,'more',true);
  end if;
  select jsonb_build_object('stage',case when j.state='checking' then 'review' else 'speech' end,'document',c.document) into strict resume
   from app_private.podcast_job_checkpoints c where c.job_id=j.id and c.stage=case when j.state='checking' then 'draft' else 'script' end;
 end if;
 update app_private.podcast_jobs set claim_id=p_claim_id,claim_generation=claim_generation+1,lease_until=clock_timestamp()+interval '15 minutes',
  state=case when resumed then j.state else 'scripting' end,stage_entered_at=clock_timestamp() where id=j.id returning * into j;
 perform app_private.podcast_event(j.id,'claimed',jsonb_build_object('claim_id',p_claim_id,'generation',j.claim_generation,'resumed',resumed));
 spec:=app_private.podcast_job_spec(j);
 select jsonb_build_object('title',left(cm.metadata->>'title',500),'authors',cm.metadata->'authors') into meta
  from app_private.catalog_metadata cm where cm.id=src.metadata_id;
 return jsonb_build_object('claimed',true,'job_id',j.id,'claim_id',p_claim_id,'generation',j.claim_generation,'origin',j.origin,
  'funding_kind',j.funding_kind,'scope',(select scope from app_private.podcast_episode_keys where id=j.episode_id),
  'owner_id',(select owner_id from app_private.podcast_episode_keys where id=j.episode_id),'episode_id',j.episode_id,
  'lease_until',j.lease_until,'spec',spec,'metadata',meta,'resume',resume,
  'source',jsonb_build_object('document_id',src.document_id,'bucket',t.bucket,'path',t.path,'sha256',encode(t.sha256,'hex'),'bytes',t.byte_count,
   'normalization_version',src.normalization_version));
end $$;

create function public.worker_podcast_advance(p_job uuid,p_claim uuid,p_generation bigint,p_state text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.podcast_jobs; ok boolean;
begin
 j:=app_private.podcast_fenced(p_job,p_claim,p_generation);
 if j.cancel_requested then
  j:=app_private.podcast_settle(j,'canceled','canceled_by_owner'); return jsonb_build_object('state',j.state,'canceled',true);
 end if;
 ok:=case p_state
  when 'checking' then j.state='scripting' and (j.origin='fixture' or app_private.podcast_route_succeeded(j.id,'podcast_script'))
  when 'synthesizing' then j.state='checking' and (j.origin='fixture' or app_private.podcast_route_succeeded(j.id,'podcast_review'))
  when 'verifying' then j.state='synthesizing' and (j.origin='fixture' or app_private.podcast_route_succeeded(j.id,'podcast_speech'))
  when 'publishing' then j.state='verifying'
  else false end;
 if not coalesce(ok,false) then raise exception 'invalid_podcast_stage'; end if;
 update app_private.podcast_jobs set state=p_state,stage_entered_at=clock_timestamp(),lease_until=clock_timestamp()+interval '15 minutes'
  where id=j.id returning * into j;
 perform app_private.podcast_event(j.id,'stage',jsonb_build_object('state',p_state));
 return jsonb_build_object('state',j.state,'canceled',false,'lease_until',j.lease_until);
end $$;

-- One durable grant per profile call: two script passes, then the planned speech
-- chunks (no repair). Units, model and ceiling come from the job's immutable profile;
-- a speech chunk's audio cap is the worker's plan, bounded per call by the serving
-- limit and in total by the profile (max_calls, max_audio_tokens). Caller holds the
-- fenced job lock and has checked stage, cancellation and rights.
create function app_private.podcast_grant(j app_private.podcast_jobs,p_spec jsonb,p_attempt_id uuid,p_route text,p_request_sha256 bytea,
 p_ordinal integer,p_audio_tokens bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare call jsonb; provider text; model text; ceiling bigint; units jsonb; admission jsonb;
begin
 if p_route='podcast_speech' then
  provider:='google'; model:=p_spec->'speech'->>'model';
  units:=jsonb_build_object('text_input_tokens',(p_spec->'speech'->>'max_input_tokens')::bigint,'audio_output_tokens',p_audio_tokens);
  ceiling:=(p_spec->'speech'->>'max_input_tokens')::bigint*(p_spec->'speech'->'rates_microusd_per_token'->>'text_input')::bigint
   +p_audio_tokens*(p_spec->'speech'->'rates_microusd_per_token'->>'audio_output')::bigint;
 else
  select c into strict call from jsonb_array_elements(p_spec->'script'->'calls') c where c->>'route'=p_route;
  provider:='anthropic'; model:=p_spec->'script'->>'model'; ceiling:=(call->>'ceiling_microusd')::bigint;
  units:=jsonb_build_object('input_tokens',(call->>'max_input_tokens')::bigint,'output_tokens',(call->>'max_output_tokens')::bigint);
 end if;
 perform set_config('app_private.podcast_attempt',p_attempt_id::text,true);
 perform set_config('app_private.podcast_profile',(p_spec->>'id')||':'||(p_spec->>'version'),true);
 admission:=public.worker_provider_attempt_begin(j.operation_account_id,j.operation_id,p_attempt_id,provider,p_route,model,p_request_sha256,ceiling,units);
 perform set_config('app_private.podcast_attempt','',true);
 if exists(select 1 from app_private.provider_attempts where id=p_attempt_id) then
  insert into app_private.podcast_job_attempts(job_id,route,ordinal,attempt_id) values(j.id,p_route,p_ordinal,p_attempt_id);
 end if;
 perform app_private.podcast_event(j.id,'attempt',jsonb_build_object('route',p_route,'ordinal',p_ordinal,'attempt_id',p_attempt_id,
  'granted',admission->'granted','reason',admission->'reason'));
 return admission||jsonb_build_object('attempt_id',p_attempt_id,'provider',provider,'model',model,'ceiling_microusd',ceiling,'units',units,
  'ordinal',p_ordinal,'account_id',j.operation_account_id,'operation_id',j.operation_id);
end $$;

-- Stage, cancellation and rights checks shared by every grant. Returns null when
-- the job may proceed, else the refusal (the job is settled for cancel/rights).
create function app_private.podcast_grant_gate(j app_private.podcast_jobs,p_route text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare need text; previous text;
begin
 if j.cancel_requested then
  j:=app_private.podcast_settle(j,'canceled','canceled_by_owner'); return jsonb_build_object('granted',false,'reason','canceled');
 end if;
 need:=case p_route when 'podcast_script' then 'scripting' when 'podcast_review' then 'checking' else 'synthesizing' end;
 previous:=case p_route when 'podcast_review' then 'podcast_script' when 'podcast_speech' then 'podcast_review' end;
 if j.state<>need or (previous is not null and not app_private.podcast_route_succeeded(j.id,previous)) then raise exception 'invalid_podcast_stage'; end if;
 if exists(select 1 from app_private.podcast_episode_keys k where k.id=j.episode_id and k.scope='shared')
  and not app_private.podcast_rights_current(j.episode_id,j.rights_revision) then
  j:=app_private.podcast_settle(j,'failed','rights_changed'); return jsonb_build_object('granted',false,'reason','rights_changed');
 end if;
 return null;
end $$;

-- A script pass, or a single-call speech plan at the full per-call cap (the five-minute profile).
create function public.worker_podcast_attempt_begin(p_job uuid,p_claim uuid,p_generation bigint,p_attempt_id uuid,p_route text,p_request_sha256 bytea) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.podcast_jobs; spec jsonb; admission jsonb; prior app_private.podcast_job_attempts; refused jsonb;
begin
 if p_attempt_id is null or p_route is null or p_route not in ('podcast_script','podcast_review','podcast_speech')
  or octet_length(p_request_sha256) is distinct from 32 then raise exception 'invalid_provider_attempt'; end if;
 j:=app_private.podcast_fenced(p_job,p_claim,p_generation);
 if j.origin<>'generated' then raise exception 'invalid_provider_route'; end if;
 select * into prior from app_private.podcast_job_attempts where job_id=j.id and route=p_route order by ordinal limit 1;
 if found then
  -- A lost acknowledgement never becomes permission for another POST.
  return jsonb_build_object('granted',false,'reason',case when prior.attempt_id=p_attempt_id then 'attempt_replayed' else 'route_used' end);
 end if;
 refused:=app_private.podcast_grant_gate(j,p_route);
 if refused is not null then return refused; end if;
 spec:=app_private.podcast_job_spec(j);
 if p_route='podcast_speech' then update app_private.podcast_jobs set speech_calls=1 where id=j.id returning * into j; end if;
 admission:=app_private.podcast_grant(j,spec,p_attempt_id,p_route,p_request_sha256,0,
  case when p_route='podcast_speech' then least((spec->'speech'->>'max_output_tokens')::bigint,
   coalesce((spec->'speech'->>'max_audio_tokens')::bigint,(spec->'speech'->>'max_output_tokens')::bigint)) end);
 update app_private.podcast_jobs set lease_until=clock_timestamp()+interval '15 minutes' where id=j.id;
 if not (admission->>'granted')::boolean then
  j:=app_private.podcast_settle(j,'failed','provider_admission_refused');
 end if;
 return admission;
end $$;

-- The speech plan's chunks, granted together or not at all: [{attempt_id,
-- request_sha256, audio_tokens}] in chunk order. If any grant is refused, the
-- chunks granted before it in this same transaction were never sent and close at
-- zero cost; the job then fails without any speech spend.
create function public.worker_podcast_speech_begin(p_job uuid,p_claim uuid,p_generation bigint,p_chunks jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.podcast_jobs; spec jsonb; refused jsonb; chunk jsonb; n integer; i integer:=0; total bigint:=0; audio bigint;
 granted jsonb:='[]'::jsonb; admission jsonb; prior_ids uuid[]; given uuid[]; g jsonb;
begin
 if p_chunks is null or jsonb_typeof(p_chunks)<>'array' or jsonb_array_length(p_chunks) not between 1 and 8 or octet_length(p_chunks::text)>4096
 then raise exception 'invalid_provider_attempt'; end if;
 j:=app_private.podcast_fenced(p_job,p_claim,p_generation);
 if j.origin<>'generated' then raise exception 'invalid_provider_route'; end if;
 select coalesce(array_agg((c->>'attempt_id')::uuid order by o),'{}') into given from jsonb_array_elements(p_chunks) with ordinality x(c,o);
 select coalesce(array_agg(attempt_id order by ordinal),'{}') into prior_ids from app_private.podcast_job_attempts where job_id=j.id and route='podcast_speech';
 if cardinality(prior_ids)>0 then
  return jsonb_build_object('granted',false,'reason',case when prior_ids=given then 'attempt_replayed' else 'route_used' end);
 end if;
 refused:=app_private.podcast_grant_gate(j,'podcast_speech');
 if refused is not null then return refused; end if;
 spec:=app_private.podcast_job_spec(j);
 n:=jsonb_array_length(p_chunks);
 if n>coalesce((spec->'speech'->>'max_calls')::integer,1) or (select count(distinct x) from unnest(given) x)<>n then raise exception 'invalid_provider_attempt'; end if;
 for chunk in select c from jsonb_array_elements(p_chunks) c loop
  if jsonb_typeof(chunk)<>'object' or chunk->>'attempt_id' !~ '^[0-9a-f-]{36}$' or chunk->>'request_sha256' !~ '^[0-9a-f]{64}$'
   or jsonb_typeof(chunk->'audio_tokens')<>'number' or (chunk->>'audio_tokens') !~ '^[1-9][0-9]{0,5}$'
   or (chunk->>'audio_tokens')::bigint>(spec->'speech'->>'max_output_tokens')::bigint then raise exception 'invalid_provider_attempt'; end if;
  total:=total+(chunk->>'audio_tokens')::bigint;
 end loop;
 if total>coalesce((spec->'speech'->>'max_audio_tokens')::bigint,(spec->'speech'->>'max_output_tokens')::bigint) then raise exception 'invalid_provider_attempt'; end if;
 update app_private.podcast_jobs set speech_calls=n,lease_until=clock_timestamp()+interval '15 minutes' where id=j.id returning * into j;
 for chunk in select c from jsonb_array_elements(p_chunks) c loop
  admission:=app_private.podcast_grant(j,spec,(chunk->>'attempt_id')::uuid,'podcast_speech',decode(chunk->>'request_sha256','hex'),i,(chunk->>'audio_tokens')::bigint);
  if not (admission->>'granted')::boolean then
   for g in select value from jsonb_array_elements(granted) loop
    perform public.worker_provider_attempt_finish((g->>'account_id')::uuid,(g->>'operation_id')::uuid,(g->>'attempt_id')::uuid,'rejected',null,0,'{}','speech_batch_refused');
   end loop;
   j:=app_private.podcast_settle(j,'failed','provider_admission_refused');
   return jsonb_build_object('granted',false,'reason',admission->'reason','ordinal',i);
  end if;
  granted:=granted||jsonb_build_array(admission);
  i:=i+1;
 end loop;
 return jsonb_build_object('granted',true,'attempts',granted);
end $$;

-- Staged jobs: after a paid script pass whose result was recorded, keep its output
-- (the draft, or the reviewed script the checker accepted) and release the claim so
-- the next stage runs in a fresh worker request with its full time budget.
create function public.worker_podcast_checkpoint(p_job uuid,p_claim uuid,p_generation bigint,p_stage text,p_document jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.podcast_jobs; next_state text;
begin
 if p_stage is null or p_stage not in ('draft','script') or p_document is null or jsonb_typeof(p_document)<>'object'
  or octet_length(p_document::text)>1048576 then raise exception 'invalid_podcast_checkpoint'; end if;
 j:=app_private.podcast_fenced(p_job,p_claim,p_generation);
 if j.cancel_requested then
  j:=app_private.podcast_settle(j,'canceled','canceled_by_owner'); return jsonb_build_object('state',j.state,'canceled',true);
 end if;
 if j.origin<>'generated' or not coalesce((app_private.podcast_job_spec(j)->>'staged')::boolean,false) then raise exception 'invalid_podcast_stage'; end if;
 if p_stage='draft' then
  if j.state<>'scripting' or not app_private.podcast_route_succeeded(j.id,'podcast_script')
   or exists(select 1 from app_private.podcast_job_attempts where job_id=j.id and route<>'podcast_script') then raise exception 'invalid_podcast_stage'; end if;
  next_state:='checking';
 else
  if j.state<>'checking' or not app_private.podcast_route_succeeded(j.id,'podcast_review')
   or not exists(select 1 from app_private.podcast_job_checkpoints where job_id=j.id and stage='draft')
   or exists(select 1 from app_private.podcast_job_attempts where job_id=j.id and route='podcast_speech') then raise exception 'invalid_podcast_stage'; end if;
  next_state:='synthesizing';
 end if;
 insert into app_private.podcast_job_checkpoints(job_id,stage,document,sha256)
  values(j.id,p_stage,p_document,sha256(convert_to(p_document::text,'UTF8')));
 j:=app_private.podcast_park(j,next_state,'checkpoint_'||p_stage);
 update app_private.podcast_jobs set kicked_at=clock_timestamp() where id=j.id;
 perform app_private.podcast_kick();
 return jsonb_build_object('state',next_state,'canceled',false);
end $$;

-- A worker that cannot fit the next paid call in what remains of its request hands
-- the job back at the last safe point instead of failing it (only where no paid
-- result would be lost).
create function public.worker_podcast_yield(p_job uuid,p_claim uuid,p_generation bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.podcast_jobs; resume text;
begin
 j:=app_private.podcast_fenced(p_job,p_claim,p_generation);
 if j.cancel_requested then
  j:=app_private.podcast_settle(j,'canceled','canceled_by_owner'); return jsonb_build_object('state',j.state,'canceled',true);
 end if;
 if exists(select 1 from app_private.podcast_job_attempts ja join app_private.provider_attempts pa on pa.id=ja.attempt_id
  where ja.job_id=j.id and pa.state='admitted') then raise exception 'invalid_podcast_stage'; end if;
 resume:=app_private.podcast_resume_state(j);
 if resume is null or (resume<>'queued' and resume<>j.state) then raise exception 'invalid_podcast_stage'; end if;
 j:=app_private.podcast_park(j,resume,'request_deadline');
 update app_private.podcast_jobs set kicked_at=clock_timestamp() where id=j.id;
 perform app_private.podcast_kick();
 return jsonb_build_object('state',j.state,'canceled',false);
end $$;

-- Terminal failure. Unrecorded attempts become unknown liabilities first.
create function public.worker_podcast_fail(p_job uuid,p_claim uuid,p_generation bigint,p_failure text,p_quality boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.podcast_jobs; a record; outcome text:='failed';
begin
 if p_failure is null or p_failure !~ '^[a-z][a-z0-9_]{0,63}$' or p_quality is null then raise exception 'invalid_podcast_failure'; end if;
 j:=app_private.podcast_fenced(p_job,p_claim,p_generation);
 for a in select pa.* from app_private.podcast_job_attempts ja join app_private.provider_attempts pa on pa.id=ja.attempt_id
  where ja.job_id=j.id and pa.state='admitted' order by pa.id loop
  perform public.worker_provider_attempt_finish(a.account_id,a.operation_id,a.id,'unknown',null,null,'{}','result_unrecorded');
 end loop;
 if exists(select 1 from app_private.podcast_job_attempts ja join app_private.provider_attempts pa on pa.id=ja.attempt_id
  where ja.job_id=j.id and pa.state='unknown') then outcome:='unknown_provider'; end if;
 j:=app_private.podcast_settle(j,outcome,p_failure,p_quality and outcome='failed');
 return jsonb_build_object('state',j.state,'failure',j.failure_code,'charged_credits',j.charged_credits);
end $$;

-- Exact immutable inventory (audio, transcript, manifest) precedes every write.
create function public.worker_podcast_asset_plan(p_job uuid,p_claim uuid,p_generation bigint,p_upload_id uuid,p_objects jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.podcast_jobs; k app_private.podcast_episode_keys; spec jsonb; u app_private.podcast_asset_uploads; row jsonb; o app_private.stored_objects;
 digest bytea; prefix text; release_key text; role text; name text; total bigint:=0; doc uuid; media text; limit_bytes bigint;
begin
 j:=app_private.podcast_fenced(p_job,p_claim,p_generation);
 if j.state<>'publishing' then raise exception 'invalid_podcast_stage'; end if;
 if p_upload_id is null or p_objects is null or jsonb_typeof(p_objects)<>'array' or jsonb_array_length(p_objects)<>3 or octet_length(p_objects::text)>8192
 then raise exception 'invalid_asset_plan'; end if;
 digest:=sha256(convert_to(jsonb_build_array(p_job,p_claim,p_generation,p_objects)::text,'UTF8'));
 select * into u from app_private.podcast_asset_uploads where id=p_upload_id;
 if found then
  if u.request_sha256<>digest or u.job_id<>j.id then raise exception 'operation_id_conflict'; end if;
  return jsonb_build_object('upload_id',u.id,'objects',(select jsonb_agg(jsonb_build_object('role',m.role,'id',s.id,'path',s.path,'verified',s.state='verified') order by m.role)
   from app_private.podcast_asset_upload_members m join app_private.stored_objects s on s.id=m.object_id where m.upload_id=u.id));
 end if;
 select * into strict k from app_private.podcast_episode_keys where id=j.episode_id;
 spec:=app_private.podcast_job_spec(j);
 select document_id into strict doc from app_private.podcast_sources where episode_id=j.episode_id and ordinal=0;
 release_key:=split_part(regexp_replace(p_objects->0->>'path','^(shared/|private/[0-9a-f-]{36}/)',''),'/',1);
 if release_key !~ '^[0-9a-f]{64}$' then raise exception 'invalid_asset_plan'; end if;
 prefix:=case when k.scope='shared' then 'shared/' else 'private/'||k.owner_id::text||'/' end||release_key||'/';
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if (select reconciliation_id is not null from app_private.paper_asset_policy where singleton) then raise exception 'asset_inventory_reconciling'; end if;
 insert into app_private.podcast_asset_uploads(id,job_id,claim_id,claim_generation,request_sha256,release_key)
  values(p_upload_id,j.id,p_claim,p_generation,digest,release_key);
 for row in select value from jsonb_array_elements(p_objects) loop
  role:=row->>'role';
  name:=case role when 'audio' then 'audio.m4a' when 'transcript' then 'transcript.json' when 'manifest' then 'manifest.json' end;
  media:=case role when 'audio' then 'audio/mp4' else 'application/json' end;
  limit_bytes:=case role when 'audio' then (spec->'storage'->>'audio_bytes')::bigint when 'transcript' then (spec->'storage'->>'transcript_bytes')::bigint
   else (spec->'storage'->>'manifest_bytes')::bigint end;
  if name is null or row->>'path' is distinct from prefix||name or (row->>'sha256') !~ '^[0-9a-f]{64}$'
   or coalesce((row->>'bytes')::bigint,0) not between 1 and limit_bytes or row->>'media_type' is distinct from media then raise exception 'invalid_asset_plan'; end if;
  total:=total+(row->>'bytes')::bigint;
  select * into o from app_private.stored_objects where path=prefix||name for update;
  if not found then
   insert into app_private.stored_objects(bucket,path,document_id,owner_id,sha256,byte_count,media_type)
    values('podcast-assets',prefix||name,case when k.scope='shared' then doc end,k.owner_id,decode(row->>'sha256','hex'),(row->>'bytes')::bigint,media) returning * into o;
  elsif o.bucket<>'podcast-assets' or o.sha256<>decode(row->>'sha256','hex') or o.byte_count<>(row->>'bytes')::bigint or o.media_type<>media
   or o.owner_id is distinct from k.owner_id or o.state not in ('pending','verified') then raise exception 'asset_identity_conflict'; end if;
  insert into app_private.podcast_asset_upload_members(upload_id,role,object_id) values(p_upload_id,role,o.id);
 end loop;
 if total>(spec->'storage'->>'bytes')::bigint then raise exception 'invalid_asset_plan'; end if;
 delete from app_private.podcast_asset_holds where job_id=j.id;
 begin perform app_private.paper_asset_check_capacity(k.owner_id);
 exception when raise_exception then
  if sqlerrm in ('paper_storage_capacity','paper_owner_storage_capacity') then raise exception 'storage_full'; end if; raise;
 end;
 perform app_private.podcast_event(j.id,'planned',jsonb_build_object('upload_id',p_upload_id,'bytes',total));
 return jsonb_build_object('upload_id',p_upload_id,'objects',(select jsonb_agg(jsonb_build_object('role',m.role,'id',s.id,'path',s.path,'verified',s.state='verified') order by m.role)
  from app_private.podcast_asset_upload_members m join app_private.stored_objects s on s.id=m.object_id where m.upload_id=p_upload_id));
end $$;

create function public.worker_podcast_asset_write(p_job uuid,p_claim uuid,p_generation bigint,p_upload_id uuid,p_object_id uuid,p_write_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.podcast_jobs; o app_private.stored_objects; u app_private.podcast_asset_uploads;
begin
 if p_write_id is null then raise exception 'invalid_asset_write'; end if;
 j:=app_private.podcast_fenced(p_job,p_claim,p_generation);
 if j.state<>'publishing' then raise exception 'invalid_podcast_stage'; end if;
 select * into strict u from app_private.podcast_asset_uploads where id=p_upload_id and job_id=j.id and claim_id=p_claim and claim_generation=p_generation;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if (select reconciliation_id is not null from app_private.paper_asset_policy where singleton) then raise exception 'asset_inventory_reconciling'; end if;
 select s.* into strict o from app_private.stored_objects s join app_private.podcast_asset_upload_members m on m.object_id=s.id
  where m.upload_id=u.id and s.id=p_object_id for update of s;
 if o.state='verified' then return jsonb_build_object('write',false,'verified',true); end if;
 if o.state<>'pending' then raise exception 'asset_unavailable'; end if;
 if exists(select 1 from app_private.podcast_asset_writes where object_id=o.id and finished_at is null)
 then return jsonb_build_object('write',false,'verified',false,'reason','asset_write_uncertain'); end if;
 insert into app_private.podcast_asset_writes(id,upload_id,object_id) values(p_write_id,u.id,o.id);
 return jsonb_build_object('write',true,'verified',false,'bucket',o.bucket,'path',o.path);
end $$;

-- A late response can reconcile its exact issued write, never publish a stale job.
create function public.worker_podcast_asset_written(p_write_id uuid,p_verified boolean) returns void
language plpgsql security definer set search_path='' as $$
declare w app_private.podcast_asset_writes; o app_private.stored_objects;
begin
 if p_verified is distinct from true then raise exception 'asset_write_proof_required'; end if;
 select * into strict w from app_private.podcast_asset_writes where id=p_write_id for update;
 if w.finished_at is not null then return; end if;
 select * into strict o from app_private.stored_objects where id=w.object_id for update;
 if o.state='pending' then update app_private.stored_objects set state='verified',verified_at=clock_timestamp() where id=o.id;
 elsif o.state not in ('verified','deleting') then raise exception 'asset_unavailable'; end if;
 update app_private.podcast_asset_writes set finished_at=clock_timestamp(),outcome='verified' where id=w.id;
end $$;

-- An unresolved write keeps its capacity and blocks inventory and the owner's
-- deletion until evidence settles it: the exact bytes present (verified) or a
-- definitive absence after the issuing worker has stopped (not_written). Owner
-- operator only; the evidence reference names a bucket listing/readback record.
create function public.worker_podcast_write_resolve(p_actor uuid,p_write_id uuid,p_outcome text,p_evidence text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare w app_private.podcast_asset_writes; o app_private.stored_objects; j app_private.podcast_jobs;
begin
 perform app_private.require_owner_account(p_actor);
 if p_write_id is null or p_outcome is null or p_outcome not in ('verified','not_written') or p_evidence is null
  or length(p_evidence) not between 3 and 256 or p_evidence !~ '^[a-zA-Z0-9._:/ -]+$' then raise exception 'invalid_write_resolution'; end if;
 select * into w from app_private.podcast_asset_writes where id=p_write_id;
 if not found then raise exception 'podcast_write_unavailable'; end if;
 select j2.* into strict j from app_private.podcast_asset_uploads u join app_private.podcast_jobs j2 on j2.id=u.job_id where u.id=w.upload_id;
 -- The issuing worker may still be writing while its job holds a live claim.
 if j.claim_id is not null and j.lease_until>clock_timestamp() then raise exception 'podcast_write_in_progress'; end if;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 select * into strict w from app_private.podcast_asset_writes where id=p_write_id for update;
 if w.finished_at is not null then
  if w.outcome<>p_outcome then raise exception 'podcast_write_conflict'; end if;
  return jsonb_build_object('write_id',w.id,'outcome',w.outcome,'replayed',true);
 end if;
 select * into strict o from app_private.stored_objects where id=w.object_id for update;
 if p_outcome='verified' and o.state='pending' then update app_private.stored_objects set state='verified',verified_at=clock_timestamp() where id=o.id; end if;
 update app_private.podcast_asset_writes set finished_at=clock_timestamp(),outcome=p_outcome,resolved_by=p_actor,resolution_evidence=p_evidence where id=w.id;
 perform app_private.podcast_event(j.id,'write_resolved',jsonb_build_object('write_id',w.id,'outcome',p_outcome,'actor_id',p_actor));
 return jsonb_build_object('write_id',w.id,'outcome',p_outcome,'replayed',false);
end $$;

-- Publication: verified complete objects, recorded provider usage for every call,
-- current rights. Shared releases wait for an operator review; private ones are ready.
create function public.worker_podcast_publish(p_job uuid,p_claim uuid,p_generation bigint,p_upload_id uuid,p_release jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.podcast_jobs; k app_private.podcast_episode_keys; spec jsonb; u app_private.podcast_asset_uploads; manifest app_private.stored_objects;
 s app_private.podcast_scripts; r app_private.podcast_releases; duration integer;
begin
 j:=app_private.podcast_fenced(p_job,p_claim,p_generation);
 if j.state<>'publishing' then raise exception 'invalid_podcast_stage'; end if;
 if j.cancel_requested then
  j:=app_private.podcast_settle(j,'canceled','canceled_by_owner'); return jsonb_build_object('state',j.state,'canceled',true);
 end if;
 if p_release is null or jsonb_typeof(p_release)<>'object' or octet_length(p_release::text)>4096
  or p_release->>'script_sha256' !~ '^[0-9a-f]{64}$' or p_release->>'manifest_sha256' !~ '^[0-9a-f]{64}$'
  or (p_release ? 'draft_sha256' and p_release->>'draft_sha256' !~ '^[0-9a-f]{64}$')
  or p_release->>'checker_version' !~ '^[a-z0-9.-]{1,64}$' or jsonb_typeof(p_release->'identity')<>'object'
  or coalesce((p_release->>'segments')::integer,0) not between 1 and 400 or coalesce((p_release->>'chapters')::integer,0) not between 1 and 40
 then raise exception 'invalid_podcast_release'; end if;
 select * into strict k from app_private.podcast_episode_keys where id=j.episode_id;
 spec:=app_private.podcast_job_spec(j);
 duration:=(p_release->>'duration_ms')::integer;
 if duration is null or duration>(spec->>'max_seconds')::integer*1000
  or (j.origin='generated' and duration<(spec->>'min_seconds')::integer*1000) or duration<1000 then raise exception 'invalid_podcast_release'; end if;
 select * into strict u from app_private.podcast_asset_uploads where id=p_upload_id and job_id=j.id and claim_id=p_claim and claim_generation=p_generation;
 if exists(select 1 from app_private.podcast_asset_upload_members m join app_private.stored_objects o on o.id=m.object_id
   where m.upload_id=u.id and o.state<>'verified')
  or exists(select 1 from app_private.podcast_asset_writes w where w.upload_id=u.id and w.finished_at is null)
  or (select count(*) from app_private.podcast_asset_upload_members where upload_id=u.id)<>3 then raise exception 'asset_inventory_incomplete'; end if;
 select o.* into strict manifest from app_private.podcast_asset_upload_members m join app_private.stored_objects o on o.id=m.object_id
  where m.upload_id=u.id and m.role='manifest';
 if encode(manifest.sha256,'hex')<>p_release->>'manifest_sha256' then raise exception 'invalid_podcast_release'; end if;
 if j.origin='generated' and not (app_private.podcast_route_succeeded(j.id,'podcast_script') and app_private.podcast_route_succeeded(j.id,'podcast_review')
   and app_private.podcast_route_succeeded(j.id,'podcast_speech')) then raise exception 'provider_usage_unrecorded'; end if;
 if k.scope='shared' and not app_private.podcast_rights_current(j.episode_id,j.rights_revision) then
  j:=app_private.podcast_settle(j,'failed','rights_changed'); return jsonb_build_object('state',j.state,'canceled',false);
 end if;
 insert into app_private.podcast_scripts(job_id,episode_id,script_sha256,draft_sha256,checker_version,decision,segments,chapters)
  values(j.id,j.episode_id,decode(p_release->>'script_sha256','hex'),decode(p_release->>'draft_sha256','hex'),p_release->>'checker_version','accepted',
   (p_release->>'segments')::integer,(p_release->>'chapters')::integer) returning * into s;
 insert into app_private.podcast_releases(episode_id,job_id,script_id,scope,owner_id,origin,identity,manifest_sha256,duration_ms,public_metadata,state,published_seq,published_at)
  values(j.episode_id,j.id,s.id,k.scope,k.owner_id,j.origin,p_release->'identity',manifest.sha256,duration,
   case when k.scope='shared' then app_private.podcast_public_metadata(j.episode_id)
     ||case when j.origin='fixture' then jsonb_build_object('title','Synthetic fixture: '||coalesce(app_private.podcast_public_metadata(j.episode_id)->>'title','paper')) else '{}'::jsonb end end,
   case when k.scope='shared' then 'pending_review' else 'ready' end,
   case when k.scope='private' then nextval('app_private.podcast_publication_seq') end,case when k.scope='private' then now() end)
  returning * into r;
 insert into app_private.podcast_release_objects(release_id,role,object_id)
  select r.id,m.role,m.object_id from app_private.podcast_asset_upload_members m where m.upload_id=u.id;
 j:=app_private.podcast_settle(j,'ready',null);
 perform app_private.podcast_event(j.id,'published',jsonb_build_object('release_id',r.id,'state',r.state,'duration_ms',duration));
 return jsonb_build_object('state',j.state,'canceled',false,'release',app_private.podcast_episode_public(r),'charged_credits',j.charged_credits);
end $$;

-- ---------------------------------------------------------------------------
-- H. Bounded authenticated delivery
-- ---------------------------------------------------------------------------
-- Episode details for the Edge function: public metadata plus the transcript
-- object, whose bytes are charged before the Edge function reads Storage.
create function public.worker_podcast_release(p_account_id uuid,p_release_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r app_private.podcast_releases; t app_private.stored_objects;
begin
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null for key share;
 if not found then raise exception 'account_unavailable'; end if;
 perform public.worker_consume_request(p_account_id,'podcast-read');
 if not (select delivery_enabled from app_private.podcast_policy where singleton) then raise exception 'podcast_unavailable'; end if;
 select * into r from app_private.podcast_releases where id=p_release_id;
 if not found or not app_private.podcast_release_visible(p_account_id,r) then raise exception 'podcast_release_unavailable'; end if;
 select o.* into strict t from app_private.podcast_release_objects ro join app_private.stored_objects o on o.id=ro.object_id
  where ro.release_id=r.id and ro.role='transcript' and o.state='verified';
 perform app_private.podcast_transfer_adjust(p_account_id,app_private.podcast_month(),0,t.byte_count);
 return jsonb_build_object('episode',app_private.podcast_episode_public(r),
  'transcript',jsonb_build_object('bucket',t.bucket,'path',t.path,'sha256',encode(t.sha256,'hex'),'bytes',t.byte_count));
end $$;

create function public.worker_podcast_delivery_expire(p_limit integer default 100) returns integer
language plpgsql security definer set search_path='' as $$
declare g app_private.podcast_delivery_grants; n integer:=0;
begin
 if p_limit is null or p_limit not between 1 and 1000 then raise exception 'invalid_limit'; end if;
 perform 1 from app_private.reader_delivery_policy where singleton for update;
 for g in select * from app_private.podcast_delivery_grants where expires_at<=clock_timestamp() and expired_at is null
  order by expires_at,id limit p_limit for update skip locked loop
  perform app_private.podcast_transfer_adjust(g.account_id,g.period,-g.remaining_bytes,0);
  update app_private.podcast_delivery_grants set remaining_bytes=0,expired_at=clock_timestamp() where id=g.id;
  n:=n+1;
 end loop;
 return n;
end $$;

create function public.worker_podcast_delivery_create(p_account_id uuid,p_release_id uuid,p_token_sha256 bytea) returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.podcast_policy; r app_private.podcast_releases; o app_private.stored_objects; g app_private.podcast_delivery_grants;
 month date:=date_trunc('month',clock_timestamp() at time zone 'UTC')::date; expiry timestamptz; rights_rev bigint;
begin
 -- Account before policy, matching deletion.
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null and not spending_suspended for key share;
 if not found then raise exception 'account_unavailable'; end if;
 if p_token_sha256 is null or octet_length(p_token_sha256)<>32 then raise exception 'invalid_podcast_grant'; end if;
 perform public.worker_consume_request(p_account_id,'podcast-download');
 perform 1 from app_private.reader_delivery_policy where singleton for update;
 select * into strict pol from app_private.podcast_policy where singleton;
 if not pol.delivery_enabled then raise exception 'podcast_unavailable'; end if;
 select * into r from app_private.podcast_releases where id=p_release_id;
 if not found or not app_private.podcast_release_visible(p_account_id,r) then raise exception 'podcast_release_unavailable'; end if;
 select o2.* into strict o from app_private.podcast_release_objects ro join app_private.stored_objects o2 on o2.id=ro.object_id
  where ro.release_id=r.id and ro.role='audio' and o2.state='verified';
 select rights_revision into rights_rev from app_private.podcast_rights where episode_id=r.episode_id;
 perform public.worker_podcast_delivery_expire(100);
 perform app_private.podcast_transfer_adjust(p_account_id,month,o.byte_count,0);
 expiry:=least(clock_timestamp()+interval '15 minutes',((month+interval '1 month')::timestamp at time zone 'UTC'));
 insert into app_private.podcast_delivery_grants(token_sha256,account_id,release_id,rights_revision,epoch,period,byte_ceiling,remaining_bytes,expires_at)
  values(p_token_sha256,p_account_id,r.id,rights_rev,pol.epoch,month,o.byte_count,o.byte_count,expiry) returning * into g;
 return jsonb_build_object('grant_id',g.id,'expires_at',g.expires_at,'members',jsonb_build_array(
  jsonb_build_object('role','audio','id',o.id,'bytes',o.byte_count,'sha256',encode(o.sha256,'hex'),'media_type',o.media_type)));
end $$;

-- Actual delivery consumes the one-use grant before Storage is read.
create function public.worker_podcast_delivery_redeem(p_account_id uuid,p_token_sha256 bytea,p_object_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare g app_private.podcast_delivery_grants; r app_private.podcast_releases; o app_private.stored_objects; pol app_private.podcast_policy;
begin
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null and not spending_suspended for key share;
 if not found then raise exception 'account_unavailable'; end if;
 perform 1 from app_private.reader_delivery_policy where singleton for update;
 select * into strict pol from app_private.podcast_policy where singleton;
 select * into g from app_private.podcast_delivery_grants where token_sha256=p_token_sha256 and account_id=p_account_id for update;
 if not found or g.expired_at is not null or g.expires_at<=clock_timestamp() or g.epoch<>pol.epoch or not pol.delivery_enabled then raise exception 'podcast_grant_unavailable'; end if;
 select * into strict r from app_private.podcast_releases where id=g.release_id;
 if not app_private.podcast_release_visible(p_account_id,r)
  or (r.scope='shared' and not app_private.podcast_rights_current(r.episode_id,g.rights_revision)) then raise exception 'podcast_grant_unavailable'; end if;
 select o2.* into o from app_private.podcast_release_objects ro join app_private.stored_objects o2 on o2.id=ro.object_id
  where ro.release_id=r.id and ro.role='audio' and o2.id=p_object_id and o2.state='verified';
 if not found then raise exception 'podcast_grant_unavailable'; end if;
 if exists(select 1 from app_private.podcast_delivery_redemptions where grant_id=g.id and object_id=o.id) then raise exception 'podcast_grant_consumed'; end if;
 perform app_private.podcast_transfer_adjust(p_account_id,g.period,-o.byte_count,o.byte_count);
 insert into app_private.podcast_delivery_redemptions(grant_id,object_id,byte_ceiling) values(g.id,o.id,o.byte_count);
 update app_private.podcast_delivery_grants set remaining_bytes=remaining_bytes-o.byte_count where id=g.id;
 return jsonb_build_object('grant_id',g.id,'bucket',o.bucket,'path',o.path,'bytes',o.byte_count,'sha256',encode(o.sha256,'hex'),'media_type',o.media_type);
end $$;

create function public.worker_podcast_delivery_observed(p_grant_id uuid,p_object_id uuid,p_upstream_bytes bigint,p_response_bytes bigint,p_observation text) returns void
language plpgsql security definer set search_path='' as $$
declare d app_private.podcast_delivery_redemptions; g app_private.podcast_delivery_grants;
begin
 perform 1 from app_private.reader_delivery_policy where singleton for update;
 select * into strict d from app_private.podcast_delivery_redemptions where (grant_id,object_id)=(p_grant_id,p_object_id) for update;
 if p_upstream_bytes is null or p_response_bytes is null or p_upstream_bytes not between 0 and d.byte_ceiling
  or p_response_bytes not between 0 and d.byte_ceiling or p_observation is null
  or p_observation not in ('response_created','upstream_failed','integrity_failed','cancelled') then raise exception 'invalid_delivery_observation'; end if;
 if d.observed_at is not null then
  if (d.upstream_bytes,d.response_bytes,d.observation) is distinct from (p_upstream_bytes,p_response_bytes,p_observation) then raise exception 'delivery_observation_conflict'; end if;
  return;
 end if;
 select * into strict g from app_private.podcast_delivery_grants where id=p_grant_id;
 perform app_private.podcast_transfer_adjust(g.account_id,g.period,0,0,p_upstream_bytes,p_response_bytes);
 update app_private.podcast_delivery_redemptions set upstream_bytes=p_upstream_bytes,response_bytes=p_response_bytes,
  observation=p_observation,observed_at=clock_timestamp() where (grant_id,object_id)=(p_grant_id,p_object_id);
end $$;

-- ---------------------------------------------------------------------------
-- I. Maintenance, cleanup, account deletion and operator status
-- ---------------------------------------------------------------------------
-- Objects of terminal jobs that never became a release are scheduled for
-- confirmed deletion. A pending object with an unresolved write is retained;
-- one that was never written is closed without touching Storage.
create function public.worker_podcast_cleanup(p_limit integer default 50) returns jsonb
language plpgsql security definer set search_path='' as $$
declare objects jsonb; quotes integer; expired integer; never integer;
begin
 if p_limit is null or p_limit not between 1 and 500 then raise exception 'invalid_limit'; end if;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if (select reconciliation_id is not null from app_private.paper_asset_policy where singleton) then raise exception 'asset_inventory_reconciling'; end if;
 with orphan as (
  select o.id,o.state from app_private.podcast_asset_upload_members m join app_private.podcast_asset_uploads u on u.id=m.upload_id
   join app_private.podcast_jobs j on j.id=u.job_id join app_private.stored_objects o on o.id=m.object_id
  where j.finished_at is not null and o.state in ('pending','verified')
   and not exists(select 1 from app_private.podcast_release_objects ro where ro.object_id=o.id)
   and not exists(select 1 from app_private.podcast_asset_writes w where w.object_id=o.id and w.finished_at is null)
  order by o.id limit p_limit)
 update app_private.stored_objects s set state=case when orphan.state='pending' and not exists(select 1 from app_private.podcast_asset_writes w where w.object_id=s.id)
   then 'deleted' else 'deleting' end from orphan where s.id=orphan.id;
 get diagnostics never=row_count;
 select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'bucket',o.bucket,'path',o.path) order by o.id),'[]'::jsonb) into objects
  from (select o.* from app_private.stored_objects o where o.bucket='podcast-assets' and o.state='deleting'
   and not exists(select 1 from app_private.podcast_release_objects ro where ro.object_id=o.id) order by o.id limit p_limit) o;
 delete from app_private.podcast_quotes where expires_at<now()-interval '1 day'
  and not exists(select 1 from app_private.podcast_requests r where (r.account_id,r.quote_id)=(podcast_quotes.account_id,podcast_quotes.id));
 get diagnostics quotes=row_count;
 expired:=public.worker_podcast_delivery_expire(100);
 return jsonb_build_object('objects',objects,'scheduled',never,'quotes_removed',quotes,'grants_expired',expired);
end $$;

create function public.worker_podcast_cleanup_confirm(p_object_ids uuid[]) returns integer
language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 if p_object_ids is null or cardinality(p_object_ids) not between 1 and 500 then raise exception 'invalid_limit'; end if;
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 update app_private.stored_objects set state='deleted' where id=any(p_object_ids) and bucket='podcast-assets' and state='deleting'
  and not exists(select 1 from app_private.podcast_release_objects ro where ro.object_id=stored_objects.id);
 get diagnostics n=row_count;
 return n;
end $$;

-- Account deletion first commits this step (the Edge function and the sweep call
-- it before worker_delete_account_begin, which refuses while any operation is
-- unsettled): queued jobs settle as canceled now, running ones stop at their next
-- fenced step. Repeatable; returns how many are still running.
create function public.worker_podcast_account_closing(p_account_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare period_key date; j app_private.podcast_jobs; canceled integer:=0; running integer:=0;
begin
 for period_key in select distinct period from (select app_private.podcast_month() period union all
  select op.period from app_private.podcast_jobs x join app_private.metered_operations op on (op.account_id,op.id)=(x.operation_account_id,x.operation_id)
  where x.operation_account_id=p_account_id and x.finished_at is null) p order by period loop
  perform 1 from app_private.platform_budgets where period=period_key for update;
 end loop;
 perform 1 from app_private.accounts where id=p_account_id for update;
 if not found then raise exception 'account_unavailable'; end if;
 perform 1 from app_private.provider_spending_policy where singleton for update;
 perform 1 from app_private.podcast_policy where singleton for share;
 for j in select x.* from app_private.podcast_jobs x where x.operation_account_id=p_account_id and x.finished_at is null
  and x.state not in ('unknown_provider','quarantined') order by x.id for update loop
  if (j.state='queued' and j.claim_id is null and not exists(select 1 from app_private.podcast_job_attempts where job_id=j.id))
   or (j.claim_id is null and j.state in ('checking','synthesizing')) then
   perform app_private.podcast_settle(j,'canceled','owner_deleted'); canceled:=canceled+1;
  else
   if not j.cancel_requested then update app_private.podcast_jobs set cancel_requested=true where id=j.id; end if;
   running:=running+1;
  end if;
 end loop;
 return jsonb_build_object('canceled',canceled,'running',running);
end $$;

alter function public.worker_delete_account_begin(uuid) rename to delete_account_begin_before_048;
alter function public.delete_account_begin_before_048(uuid) set schema app_private;
create function public.worker_delete_account_begin(p_account_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; period_key date; j app_private.podcast_jobs; g app_private.podcast_delivery_grants;
begin
 -- Budgets -> account -> provider policy -> podcast policy -> podcast jobs, then
 -- 039's account -> papers -> uploads -> capacity -> keyrings order.
 for period_key in select distinct period from (select app_private.podcast_month() period union all
  select op.period from app_private.podcast_jobs x join app_private.metered_operations op on (op.account_id,op.id)=(x.operation_account_id,x.operation_id)
  where x.operation_account_id=p_account_id and x.finished_at is null) p order by period loop
  perform 1 from app_private.platform_budgets where period=period_key for update;
 end loop;
 perform 1 from app_private.accounts where id=p_account_id for update;
 if not found then raise exception 'account_unavailable'; end if;
 perform 1 from app_private.provider_spending_policy where singleton for update;
 perform 1 from app_private.podcast_policy where singleton for share;
 for j in select x.* from app_private.podcast_jobs x where x.operation_account_id=p_account_id and x.finished_at is null order by x.id for update loop
  if (j.state='queued' and j.claim_id is null and not exists(select 1 from app_private.podcast_job_attempts where job_id=j.id))
   or (j.claim_id is null and j.state in ('checking','synthesizing')) then
   perform app_private.podcast_settle(j,'canceled','owner_deleted');
  elsif j.state not in ('unknown_provider','quarantined') then
   update app_private.podcast_jobs set cancel_requested=true where id=j.id;
  end if;
 end loop;
 result:=app_private.delete_account_begin_before_048(p_account_id);
 delete from app_private.podcast_requests where account_id=p_account_id;
 delete from app_private.podcast_quotes where account_id=p_account_id;
 update app_private.podcast_releases set state='withdrawn' where scope='private' and owner_id=p_account_id and state<>'withdrawn';
 delete from app_private.podcast_asset_holds where owner_id=p_account_id and job_id in (select id from app_private.podcast_jobs where finished_at is not null);
 perform 1 from app_private.reader_delivery_policy where singleton for update;
 for g in select * from app_private.podcast_delivery_grants where account_id=p_account_id for update loop
  if g.remaining_bytes>0 then perform app_private.podcast_transfer_adjust(p_account_id,g.period,-g.remaining_bytes,0,0,0,true); end if;
  delete from app_private.podcast_delivery_redemptions where grant_id=g.id;
 end loop;
 delete from app_private.podcast_delivery_grants where account_id=p_account_id;
 delete from app_private.reader_transfer_months where scope_id=p_account_id::text;
 if exists(select 1 from app_private.podcast_asset_writes w join app_private.stored_objects o on o.id=w.object_id
  where o.owner_id=p_account_id and w.finished_at is null) then
  return jsonb_build_object('account_id',p_account_id,'blocked','asset_write_uncertain','objects','[]'::jsonb,'prefixes','[]'::jsonb);
 end if;
 return result;
end $$;

alter function public.worker_delete_account_finish(uuid) rename to delete_account_finish_before_048;
alter function public.delete_account_finish_before_048(uuid) set schema app_private;
create function public.worker_delete_account_finish(p_account_id uuid) returns integer
language plpgsql security definer set search_path='' as $$
begin
 perform 1 from app_private.accounts where id=p_account_id and closed_at is not null for update;
 if not found then raise exception 'account_not_closed'; end if;
 if exists(select 1 from app_private.podcast_asset_writes w join app_private.stored_objects o on o.id=w.object_id
  where o.owner_id=p_account_id and w.finished_at is null) then raise exception 'asset_write_uncertain'; end if;
 return app_private.delete_account_finish_before_048(p_account_id);
end $$;

-- Seed pilot helper: eligible CC BY 4.0 / CC0 conversions with verified text
-- small enough for the profile. Public catalog metadata only.
create function public.worker_podcast_seed_candidates(p_limit integer default 20) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare spec jsonb:=app_private.podcast_spec();
begin
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'invalid_limit'; end if;
 return coalesce((select jsonb_agg(c order by c->>'recorded_at' desc) from (
  select jsonb_build_object('approval_id',ca.id,'title',left(cm.metadata->>'title',200),'source_id',cm.source_id,'license',ca.license_uri,
   'text_bytes',(pin->>'text_bytes')::bigint,'recorded_at',ca.recorded_at,
   'existing_release',exists(select 1 from app_private.podcast_sources s join app_private.podcast_releases r on r.episode_id=s.episode_id
     where s.approval_id=ca.id and r.scope='shared' and r.state in ('ready','pending_review'))) c
  from app_private.catalog_asset_approvals ca join app_private.catalog_metadata cm on cm.id=ca.metadata_id
   cross join lateral (select app_private.podcast_approval_pin(ca.id) pin) p
  where p.pin is not null and (p.pin->>'text_bytes')::bigint<=(spec->>'max_source_bytes')::bigint
  order by ca.recorded_at desc limit p_limit) x),'[]'::jsonb);
end $$;

-- Read-only operator view: ids and numeric units, never transcript contents.
create function public.worker_podcast_status() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('policy',(select to_jsonb(p) from app_private.podcast_policy p where singleton),
  'inventory_certified',app_private.podcast_inventory_certified(),
  'profile',app_private.podcast_spec(),
  'lengths',app_private.podcast_lengths(),
  'seed_periods',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('committed_microusd',app_private.podcast_seed_committed(s.period),
    'episodes',app_private.podcast_seed_episodes(s.period)) order by s.period desc)
   from app_private.podcast_seed_periods s),'[]'::jsonb),
  'jobs',coalesce((select jsonb_object_agg(state,n) from (select state,count(*) n from app_private.podcast_jobs group by state) x),'{}'::jsonb),
  'recent_jobs',coalesce((select jsonb_agg(jsonb_build_object('id',j.id,'state',j.state,'origin',j.origin,'funding',j.funding_kind,'failure',j.failure_code,
    'profile',(select k.profile_id from app_private.podcast_episode_keys k where k.id=j.episode_id),'speech_calls',j.speech_calls,
    'parked',j.claim_id is null and j.state in ('checking','synthesizing'),
    'created_at',j.created_at,'finished_at',j.finished_at,'charged_credits',j.charged_credits,'quality_loss_microusd',j.quality_loss_microusd,
    'release_id',(select r.id from app_private.podcast_releases r where r.job_id=j.id),
    'attempts',(select coalesce(jsonb_agg(jsonb_build_object('route',ja.route,'ordinal',ja.ordinal,'state',pa.state,'ceiling_microusd',pa.ceiling_microusd,
      'actual_microusd',pa.actual_microusd,'units',pa.actual_units,'model',pa.model,'provider_request_id',pa.provider_request_id) order by pa.created_at),'[]'::jsonb)
     from app_private.podcast_job_attempts ja join app_private.provider_attempts pa on pa.id=ja.attempt_id where ja.job_id=j.id)) order by j.created_at desc)
   from (select * from app_private.podcast_jobs order by created_at desc limit 20) j),'[]'::jsonb),
  'releases',coalesce((select jsonb_object_agg(scope||':'||state,n) from (select scope,state,count(*) n from app_private.podcast_releases group by scope,state) x),'{}'::jsonb),
  'objects',coalesce((select jsonb_agg(r) from (select state,count(*) objects,sum(byte_count) bytes from app_private.stored_objects where bucket='podcast-assets' group by state) r),'[]'::jsonb),
  'unresolved_writes',(select count(*) from app_private.podcast_asset_writes where finished_at is null),
  'holds',(select jsonb_build_object('count',count(*),'bytes',coalesce(sum(bytes),0)) from app_private.podcast_asset_holds))
$$;

-- ---------------------------------------------------------------------------
-- J. Row security and grants
-- ---------------------------------------------------------------------------
do $$
declare t text; f regprocedure;
begin
 foreach t in array array['podcast_profiles','podcast_policy','podcast_policy_events','podcast_seed_periods','podcast_episode_keys','podcast_sources',
  'podcast_rights','podcast_rights_events','podcast_quotes','podcast_jobs','podcast_requests','podcast_job_events','podcast_job_attempts','podcast_scripts',
  'podcast_releases','podcast_release_objects','podcast_asset_holds','podcast_asset_uploads','podcast_asset_upload_members','podcast_asset_writes',
  'podcast_delivery_grants','podcast_delivery_redemptions','podcast_job_checkpoints'] loop
  execute format('alter table app_private.%I enable row level security',t);
  execute format('revoke all on app_private.%I from public,anon,authenticated,service_role',t);
 end loop;
 revoke all on sequence app_private.podcast_publication_seq from public,anon,authenticated,service_role;
 for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
  and p.proname in ('worker_podcast_policy_set','worker_podcast_seed_period','worker_podcast_seed_admit','worker_podcast_review','worker_podcast_rights',
   'worker_podcast_recover','worker_podcast_claim','worker_podcast_advance','worker_podcast_attempt_begin','worker_podcast_speech_begin',
   'worker_podcast_checkpoint','worker_podcast_yield','worker_podcast_fail','worker_podcast_asset_plan',
   'worker_podcast_asset_write','worker_podcast_asset_written','worker_podcast_publish','worker_podcast_release','worker_podcast_delivery_expire',
   'worker_podcast_delivery_create','worker_podcast_delivery_redeem','worker_podcast_delivery_observed','worker_podcast_cleanup','worker_podcast_cleanup_confirm',
   'worker_podcast_status','worker_podcast_kick_due','worker_podcast_seed_candidates','worker_podcast_write_resolve','worker_podcast_account_closing','worker_delete_account_begin','worker_delete_account_finish','worker_provider_attempt_begin',
   'worker_asset_inventory_begin','worker_asset_inventory_page','worker_asset_inventory_finish','worker_pdf_upload_policy','worker_asset_spending_status') loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',f);
  execute format('grant execute on function %s to service_role',f);
 end loop;
 for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
  and p.proname in ('v1_podcast_capabilities','v1_podcast_catalog','v1_podcast_paper','v1_podcast_quote','v1_podcast_start','v1_podcast_status',
   'v1_podcast_cancel','v1_podcast_states','v1_reader_capabilities') loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',f);
  execute format('grant execute on function %s to authenticated',f);
 end loop;
end $$;
revoke all on all functions in schema app_private from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
commit;
