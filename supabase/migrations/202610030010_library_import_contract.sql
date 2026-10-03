-- Durable account library/import contract. No network
-- acquisition or paid-worker enablement. Applied migrations 001-009 are intact.
begin;
lock table app_private.library_items in share row exclusive mode;

create table app_private.library_policy (
 singleton boolean primary key default true check(singleton),
 account_items integer not null check(account_items>0), environment_items integer not null check(environment_items>=account_items),
 account_imports integer not null check(account_imports>0), environment_imports integer not null check(environment_imports>=account_imports),
 account_active_imports integer not null check(account_active_imports>0), environment_active_imports integer not null check(environment_active_imports>=account_active_imports),
 account_receipts integer not null check(account_receipts>0), environment_receipts integer not null check(environment_receipts>=account_receipts),
 account_journal_bytes bigint not null check(account_journal_bytes>=131072), environment_journal_bytes bigint not null check(environment_journal_bytes>=account_journal_bytes),
 account_journal_events integer not null check(account_journal_events>0), environment_journal_events integer not null check(environment_journal_events>=account_journal_events),
 metadata_rows integer not null check(metadata_rows>0), metadata_bytes bigint not null check(metadata_bytes>0),
 approval_rows integer not null check(approval_rows>0), approval_bytes bigint not null check(approval_bytes>0),
 account_transfer_bytes bigint not null check(account_transfer_bytes>0), environment_transfer_bytes bigint not null check(environment_transfer_bytes>=account_transfer_bytes),
 compatible_renderers text[] not null default '{}'
);
insert into app_private.library_policy values(true,2000,20000,2000,20000,10,100,12000,120000,
 8388608,67108864,10000,100000,10000,33554432,10000,16777216,268435456,2147483648,'{}');
create table app_private.library_sync_state (
 -- Derived bookkeeping may disappear with a pristine/deletable account.
 -- Memberships, imports and immutable receipts independently gate deletion.
 account_id uuid primary key references app_private.accounts(id) on delete cascade,
 last_seq bigint not null default 0 check(last_seq>=0),
 retained_after bigint not null default 0 check(retained_after>=0 and retained_after<=last_seq),
 v2_writes_started boolean not null default false
);
insert into app_private.library_sync_state(account_id,last_seq,retained_after)
 select a.id,case when exists(select 1 from app_private.library_items li where li.account_id=a.id) then 1 else 0 end,
 case when exists(select 1 from app_private.library_items li where li.account_id=a.id) then 1 else 0 end from app_private.accounts a;
create function app_private.initialize_library_account() returns trigger language plpgsql security definer set search_path='' as $$
begin insert into app_private.library_sync_state(account_id) values(new.id); return new; end $$;
create trigger science_reader_library_account after insert on app_private.accounts
 for each row execute function app_private.initialize_library_account();

create table app_private.catalog_metadata (
 id uuid primary key default gen_random_uuid(),
 version_id uuid not null references app_private.publication_versions(id),
 source_id text not null check(length(source_id) between 1 and 128),
 source_revision integer not null check(source_revision>0),
 metadata jsonb not null check(jsonb_typeof(metadata)='object' and octet_length(metadata::text)<=32768),
 metadata_sha256 bytea not null check(metadata_sha256=sha256(convert_to(metadata::text,'UTF8'))),
 recorded_at timestamptz not null default now(),
 unique(version_id,metadata_sha256), unique(id,version_id)
);
create table app_private.catalog_asset_approvals (
 id uuid primary key,
 version_id uuid not null,
 document_id uuid not null,
 metadata_id uuid not null,
 original_object_id uuid not null references app_private.stored_objects(id),
 license_uri text not null check(license_uri in ('https://creativecommons.org/licenses/by/4.0/','https://creativecommons.org/publicdomain/zero/1.0/')),
 policy_version text not null check(policy_version='arxiv-reuse-v1'),
 evidence jsonb not null check(jsonb_typeof(evidence)='object' and octet_length(evidence::text)<=8192),
 recorded_at timestamptz not null default now(),
 foreign key(metadata_id,version_id) references app_private.catalog_metadata(id,version_id),
 foreign key(version_id,document_id) references app_private.version_documents(version_id,document_id),
 unique(id,document_id), unique(metadata_id,document_id,policy_version)
);
create trigger catalog_metadata_immutable before update or delete on app_private.catalog_metadata
 for each row execute function app_private.immutable_record();
create trigger catalog_asset_approvals_immutable before update or delete on app_private.catalog_asset_approvals
 for each row execute function app_private.immutable_record();
-- Pins refer to immutable identities, not a mutable object at a stable UUID.
-- Storage deletion lifecycle remains available; rewriting bytes needs a new ID.
create function app_private.protect_paper_identity() returns trigger language plpgsql set search_path='' as $$
begin
 if TG_TABLE_NAME='documents' then
  if (new.id,new.sha256,new.scope,new.owner_id,new.byte_count,new.page_count,new.created_at) is distinct from
   (old.id,old.sha256,old.scope,old.owner_id,old.byte_count,old.page_count,old.created_at) then raise exception 'immutable_document_identity'; end if;
 elsif TG_TABLE_NAME='stored_objects' then
  if (new.id,new.bucket,new.path,new.document_id,new.owner_id,new.sha256,new.byte_count,new.media_type,new.created_at) is distinct from
   (old.id,old.bucket,old.path,old.document_id,old.owner_id,old.sha256,old.byte_count,old.media_type,old.created_at)
   or (old.verified_at is not null and new.verified_at is distinct from old.verified_at) then raise exception 'immutable_object_identity'; end if;
  if not (new.state=old.state or (old.state='pending' and new.state in ('verified','deleting'))
   or (old.state='verified' and new.state='deleting') or (old.state='deleting' and new.state='deleted')) then raise exception 'invalid_object_transition'; end if;
 end if;
 return new;
end $$;
create trigger document_identity_immutable before update on app_private.documents for each row execute function app_private.protect_paper_identity();
create trigger object_identity_immutable before update on app_private.stored_objects for each row execute function app_private.protect_paper_identity();
create trigger render_artifact_identity_immutable before update on app_private.render_artifacts for each row execute function app_private.immutable_record();

alter table app_private.library_items
 add column created_seq bigint not null default 1 check(created_seq>0),
 add column state_seq bigint not null default 1 check(state_seq>0),
 add column membership_revision bigint not null default 1 check(membership_revision>0),
 add column last_intent_seq bigint not null default 1 check(last_intent_seq>0),
 add column last_remove_seq bigint not null default 0 check(last_remove_seq>=0),
 add column membership_source text not null default 'explicit' check(membership_source in ('explicit','import')),
 add column approval_id uuid,
 add column artifact_id uuid references app_private.render_artifacts(id),
 add constraint library_approval_document foreign key(approval_id,document_id) references app_private.catalog_asset_approvals(id,document_id),
 add constraint library_account_item_document unique(account_id,id,document_id);
update app_private.library_items set last_remove_seq=1 where removed_at is not null;
-- Old rows deliberately keep approval_id null: nonempty legacy JSON is not a
-- license verification, and an arbitrary version association is not a pin.
create index library_account_created on app_private.library_items(account_id,created_seq,id);

create table app_private.import_requests (
 account_id uuid not null references app_private.accounts(id), id uuid not null,
 request_sha256 bytea not null check(octet_length(request_sha256)=32),
 source_id text not null check(length(source_id) between 1 and 128),
 requested_revision integer check(requested_revision>0),
 observed_cursor bigint not null check(observed_cursor>=0),
 created_seq bigint not null check(created_seq>0), state_seq bigint not null check(state_seq>0),
 intent_revision bigint not null default 1 check(intent_revision>0),
 desired_present boolean not null default true,
 phase text not null default 'accepted' check(phase in ('accepted','resolving','acquiring','failed','source_only','ready','cancelled','membership_conflict')),
 metadata_id uuid references app_private.catalog_metadata(id),
 approval_id uuid,
 document_id uuid,
 library_item_id uuid,
 artifact_id uuid references app_private.render_artifacts(id),
 resolution_sha256 bytea check(octet_length(resolution_sha256)=32),
 error_code text check(error_code in ('metadata_unavailable','download_failed','pdf_invalid','rate_limited','license_unverified','membership_conflict')),
 retryable boolean not null default false,
 created_at timestamptz not null default now(),
 primary key(account_id,id),
 foreign key(approval_id,document_id) references app_private.catalog_asset_approvals(id,document_id),
 foreign key(account_id,library_item_id,document_id) references app_private.library_items(account_id,id,document_id),
 check((library_item_id is null)=(document_id is null)),
 check((approval_id is null)=(document_id is null)),
 check(phase<>'ready' or (library_item_id is not null and desired_present)),
 check(phase<>'cancelled' or not desired_present),
 check(not retryable or phase='failed')
);
create index imports_account_created on app_private.import_requests(account_id,created_seq,id);
create table app_private.library_commands (
 account_id uuid not null references app_private.accounts(id), id uuid not null,
 request_sha256 bytea not null check(octet_length(request_sha256)=32),
 result jsonb not null check(jsonb_typeof(result)='object' and octet_length(result::text)<=2048),
 created_at timestamptz not null default now(), primary key(account_id,id)
);
create trigger library_commands_immutable before update or delete on app_private.library_commands
 for each row execute function app_private.immutable_record();
create table app_private.library_changes (
 account_id uuid not null references app_private.accounts(id), seq bigint not null check(seq>0),
 entries jsonb not null check(jsonb_typeof(entries)='array' and jsonb_array_length(entries) between 1 and 4 and octet_length(entries::text)<=131072),
 encoded_bytes integer generated always as (octet_length(entries::text)+128) stored,
 primary key(account_id,seq)
);
create trigger library_changes_immutable before update on app_private.library_changes
 for each row execute function app_private.immutable_record();
create table app_private.library_transfer_months (
 period date not null check(extract(day from period)=1), scope_id text not null,
 reserved_bytes bigint not null check(reserved_bytes>=0), primary key(period,scope_id)
);
insert into app_private.api_rate_rules values('library-read',3600,1000,10000),('library-write',3600,1000,10000);

-- Mutations acquire request windows, then account NO KEY UPDATE, then any
-- document KEY SHARE, then policy/state. Account comes before all account FKs.
-- Paid compatibility RPC additionally takes budget BEFORE account. It never
-- obtains budget after an account FK or after the library policy mutex.
create function app_private.lock_library_account(a uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 perform 1 from app_private.accounts where id=a and closed_at is null for no key update;
 if not found then raise exception 'account_unavailable' using errcode='42501'; end if;
end $$;
create function app_private.lock_library_state(a uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 perform 1 from app_private.library_policy where singleton for update;
 perform 1 from app_private.library_sync_state where account_id=a for update;
 if not found then raise exception 'account_unavailable'; end if;
end $$;
create function app_private.library_next_seq(a uuid) returns bigint language sql security definer set search_path='' as $$
 update app_private.library_sync_state set last_seq=last_seq+1 where account_id=a returning last_seq
$$;
create function app_private.library_check_receipt_capacity(a uuid,p_growth boolean,p_releases integer default 0) returns void language plpgsql security definer set search_path='' as $$
declare p app_private.library_policy; extra_a bigint:=0; extra_e bigint:=0;
begin
 select * into strict p from app_private.library_policy;
 -- Every receipt preserves one future removal/cancel slot per active entity.
 -- Only a validated transition may consume its own reserved slot. Conflicts
 -- and repeated removals/cancels cannot consume another entity's headroom.
 select count(*) into extra_a from app_private.library_items where account_id=a and removed_at is null;
 select count(*) into extra_e from app_private.library_items where removed_at is null;
 extra_a:=extra_a+(select count(*) from app_private.import_requests where account_id=a and desired_present and phase<>'ready');
 extra_e:=extra_e+(select count(*) from app_private.import_requests where desired_present and phase<>'ready');
 extra_a:=extra_a+case when p_growth then 1 else 0 end-p_releases;
 extra_e:=extra_e+case when p_growth then 1 else 0 end-p_releases;
 if (select count(*) from app_private.library_commands where account_id=a)+1+extra_a>p.account_receipts
 then raise exception 'library_account_receipt_limit'; end if;
 if (select count(*) from app_private.library_commands)+1+extra_e>p.environment_receipts
 then raise exception 'library_environment_receipt_limit'; end if;
end $$;

create function app_private.library_item_entry(a uuid,p_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('kind','item','id',li.id,'document_id',li.document_id,'created_seq',li.created_seq,'state_seq',li.state_seq,
  'membership_revision',li.membership_revision,'visible',li.removed_at is null,'added_at',li.added_at,
  'last_remove_seq',li.last_remove_seq,'approval_id',li.approval_id,'version_id',ca.version_id,'metadata_id',cm.id,
  'source',case when cm.id is not null then 'arxiv' end,'source_id',cm.source_id,'source_revision',cm.source_revision,
  'metadata',cm.metadata,'metadata_recorded_at',cm.recorded_at,'source_url',case when cm.id is not null then 'https://arxiv.org/abs/'||cm.source_id||'v'||cm.source_revision end,
  'scope',d.scope,'page_count',d.page_count,'original_object_id',ca.original_object_id,
  'artifact_id',li.artifact_id,'readiness',case when ca.id is null then 'unverified' when li.artifact_id is null then 'pdf_ready' else 'converted_ready' end)
 from app_private.library_items li join app_private.documents d on d.id=li.document_id
 left join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
 left join app_private.catalog_metadata cm on cm.id=ca.metadata_id where li.account_id=a and li.id=p_id
$$;
create function app_private.library_import_entry(a uuid,p_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('kind','import','id',i.id,'created_seq',i.created_seq,'state_seq',i.state_seq,'intent_revision',i.intent_revision,
  'visible',i.desired_present and i.phase<>'ready','phase',i.phase,'source','arxiv','source_id',i.source_id,
  'requested_revision',i.requested_revision,'source_revision',cm.source_revision,'metadata_id',cm.id,'version_id',cm.version_id,
  'metadata',cm.metadata,'metadata_recorded_at',cm.recorded_at,'source_url','https://arxiv.org/abs/'||i.source_id||coalesce('v'||coalesce(cm.source_revision,i.requested_revision),''),
  'document_id',i.document_id,'library_item_id',i.library_item_id,
  'error_code',i.error_code,'retryable',i.retryable)
 from app_private.import_requests i left join app_private.catalog_metadata cm on cm.id=i.metadata_id where i.account_id=a and i.id=p_id
$$;
create function app_private.library_command_response(a uuid,r jsonb,p_replayed boolean) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('result',r,'replayed',p_replayed,'entry',case r->>'kind'
 when 'item' then app_private.library_item_entry(a,(r->>'id')::uuid)
 when 'import' then app_private.library_import_entry(a,(r->>'id')::uuid) end)
$$;
create function app_private.library_replay(a uuid,p_id uuid,p_digest bytea) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c app_private.library_commands;
begin
 if p_id is null then raise exception 'invalid_operation_id'; end if;
 select * into c from app_private.library_commands where account_id=a and id=p_id;
 if not found then return null; end if;
 if c.request_sha256 is distinct from p_digest then raise exception 'operation_id_conflict'; end if;
 return app_private.library_command_response(a,c.result,true);
end $$;
create function app_private.library_receipt(a uuid,p_id uuid,p_digest bytea,r jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
begin
 update app_private.library_sync_state set v2_writes_started=true where account_id=a;
 insert into app_private.library_commands(account_id,id,request_sha256,result) values(a,p_id,p_digest,r);
 return app_private.library_command_response(a,r,false); end $$;
create function app_private.library_emit(a uuid,s bigint,e jsonb) returns void language plpgsql security definer set search_path='' as $$
declare p app_private.library_policy; bytes bigint:=octet_length(e::text)+128;
begin
 select * into strict p from app_private.library_policy;
 if e is null or jsonb_typeof(e)<>'array' or jsonb_array_length(e) not between 1 and 4 or bytes>131072 then raise exception 'library_change_too_large'; end if;
 if (select last_seq from app_private.library_sync_state where account_id=a)<>s then raise exception 'library_sequence_mismatch'; end if;
 if (select coalesce(sum(encoded_bytes),0) from app_private.library_changes where account_id=a)+bytes>p.account_journal_bytes
  or (select count(*) from app_private.library_changes where account_id=a)+1>p.account_journal_events then
  delete from app_private.library_changes where account_id=a;
  update app_private.library_sync_state set retained_after=s-1 where account_id=a;
 end if;
 if (select coalesce(sum(encoded_bytes),0) from app_private.library_changes)+bytes>p.environment_journal_bytes
  or (select count(*) from app_private.library_changes)+1>p.environment_journal_events then
  -- Explicit bounded-log reset, serialized by the policy mutex. Current rows,
  -- receipts, identities and remove fences survive. Old cursors must resync.
  delete from app_private.library_changes;
  update app_private.library_sync_state set retained_after=case when account_id=a then s-1 else last_seq end;
 end if;
 insert into app_private.library_changes values(a,s,e);
end $$;

create function app_private.validate_arxiv_id(p_source_id text) returns text language plpgsql immutable set search_path='' as $$
declare s text:=lower(btrim(p_source_id)); m text;
begin
 if s is null or length(s)>128 or not (s ~ '^[0-9]{4}\.[0-9]{4,5}$' or s ~ '^[a-z][a-z0-9.-]*/[0-9]{7}$') then raise exception 'invalid_arxiv_id'; end if;
 m:=case when position('/' in s)>0 then substring(split_part(s,'/',2),3,2) else substring(s,3,2) end;
 if m::integer not between 1 and 12 then raise exception 'invalid_arxiv_id'; end if;
 return s;
end $$;
create function public.worker_record_arxiv_metadata(p_source_id text,p_revision integer,p_metadata jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare src text:=app_private.validate_arxiv_id(p_source_id); pub uuid; ver uuid; result uuid; p app_private.library_policy; authors text[];
begin
 if p_revision is null or p_revision<1 or p_metadata is null or jsonb_typeof(p_metadata)<>'object' or octet_length(p_metadata::text)>32768
 or (p_metadata-'title'-'authors'-'abstract'-'published_at'-'updated_at'-'categories'-'venue')<>'{}'::jsonb
 or jsonb_typeof(p_metadata->'title') is distinct from 'string' or length(p_metadata->>'title') not between 1 and 2000
 or jsonb_typeof(p_metadata->'authors') is distinct from 'array' or jsonb_typeof(p_metadata->'categories') is distinct from 'array'
 then raise exception 'invalid_catalog_metadata'; end if;
 if jsonb_array_length(p_metadata->'authors')>512 or jsonb_array_length(p_metadata->'categories')>64
 or exists(select 1 from jsonb_array_elements(p_metadata->'authors') x where jsonb_typeof(x)<>'string' or length(x#>>'{}')>256)
 or exists(select 1 from jsonb_array_elements(p_metadata->'categories') x where jsonb_typeof(x)<>'string' or length(x#>>'{}')>64)
 or exists(select 1 from jsonb_each(p_metadata) e where e.key in ('abstract','venue','published_at','updated_at') and jsonb_typeof(e.value) not in ('string','null'))
 or length(coalesce(p_metadata->>'abstract',''))>24000 or length(coalesce(p_metadata->>'venue',''))>1024
 then raise exception 'invalid_catalog_metadata'; end if;
 if exists(select 1 from jsonb_each_text(p_metadata) e where e.key in ('published_at','updated_at') and e.value is not null and e.value !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') then raise exception 'invalid_catalog_metadata'; end if;
 if p_metadata->>'published_at' is not null then perform (p_metadata->>'published_at')::date; end if;
 if p_metadata->>'updated_at' is not null then perform (p_metadata->>'updated_at')::date; end if;
 select * into strict p from app_private.library_policy where singleton for update;
 select publication_id into pub from app_private.publication_identifiers where namespace='arxiv' and identifier=src;
 if pub is null then
  select coalesce(array_agg(value),'{}') into authors from jsonb_array_elements_text(p_metadata->'authors');
  insert into app_private.publications(title,authors,abstract,venue) values(p_metadata->>'title',authors,p_metadata->>'abstract',p_metadata->>'venue') returning id into pub;
  insert into app_private.publication_identifiers values('arxiv',src,pub,now(),'arxiv-adapter-v1');
 end if;
 insert into app_private.publication_versions(publication_id,source,revision,published_at) values(pub,'arxiv','v'||p_revision,nullif(p_metadata->>'updated_at','')::date)
 on conflict(publication_id,source,revision) do nothing;
 select id into strict ver from app_private.publication_versions where publication_id=pub and source='arxiv' and revision='v'||p_revision;
 select id into result from app_private.catalog_metadata where version_id=ver and metadata_sha256=sha256(convert_to(p_metadata::text,'UTF8'));
 if result is not null then return result; end if;
 if (select count(*) from app_private.catalog_metadata)+1>p.metadata_rows
 or (select coalesce(sum(octet_length(metadata::text)),0) from app_private.catalog_metadata)+octet_length(p_metadata::text)>p.metadata_bytes
 then raise exception 'catalog_metadata_limit'; end if;
 insert into app_private.catalog_metadata(version_id,source_id,source_revision,metadata,metadata_sha256)
 values(ver,src,p_revision,p_metadata,sha256(convert_to(p_metadata::text,'UTF8'))) returning id into result;
 return result;
end $$;
create function public.worker_approve_arxiv_asset(p_id uuid,p_metadata_id uuid,p_document_id uuid,p_original_object_id uuid,p_license_uri text,p_evidence jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare m app_private.catalog_metadata; d app_private.documents; p app_private.library_policy; old app_private.catalog_asset_approvals; existing uuid;
begin
 if p_id is null then raise exception 'invalid_approval_id'; end if;
 select * into d from app_private.documents where id=p_document_id and scope='shared_catalog' for key share;
 if not found then raise exception 'document_unavailable'; end if;
 select * into strict m from app_private.catalog_metadata where id=p_metadata_id;
 if p_license_uri is null or p_license_uri not in ('https://creativecommons.org/licenses/by/4.0/','https://creativecommons.org/publicdomain/zero/1.0/')
 or p_evidence is null or jsonb_typeof(p_evidence)<>'object' or octet_length(p_evidence::text)>8192
 or p_evidence->>'source_id' is distinct from m.source_id or p_evidence->>'source_revision' is distinct from m.source_revision::text
 or p_evidence->>'source_url' is distinct from 'https://arxiv.org/abs/'||m.source_id||'v'||m.source_revision
 or p_evidence->>'license_uri' is distinct from p_license_uri
 or not coalesce(p_evidence->>'evidence_sha256' ~ '^[0-9a-f]{64}$',false)
 or not coalesce(p_evidence->>'observed_at' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T',false)
 then raise exception 'reuse_evidence_mismatch'; end if;
 perform (p_evidence->>'observed_at')::timestamptz;
 if not exists(select 1 from app_private.stored_objects where id=p_original_object_id and document_id=d.id and bucket='paper-assets'
 and state='verified' and media_type='application/pdf' and sha256=d.sha256 and byte_count=d.byte_count) then raise exception 'original_object_mismatch'; end if;
 select * into strict p from app_private.library_policy where singleton for update;
 select * into old from app_private.catalog_asset_approvals where id=p_id;
 if found then
  if (old.metadata_id,old.document_id,old.original_object_id,old.license_uri,old.evidence) is distinct from
   (p_metadata_id,p_document_id,p_original_object_id,p_license_uri,p_evidence) then raise exception 'approval_id_conflict'; end if;
  return old.id;
 end if;
 select id into existing from app_private.catalog_asset_approvals where metadata_id=p_metadata_id and document_id=p_document_id and policy_version='arxiv-reuse-v1';
 if existing is not null then return existing; end if;
 if (select count(*) from app_private.catalog_asset_approvals)+1>p.approval_rows
 or (select coalesce(sum(octet_length(evidence::text)),0) from app_private.catalog_asset_approvals)+octet_length(p_evidence::text)>p.approval_bytes
 then raise exception 'catalog_approval_limit'; end if;
 insert into app_private.version_documents values(m.version_id,d.id) on conflict do nothing;
 insert into app_private.catalog_asset_approvals values(p_id,m.version_id,d.id,m.id,p_original_object_id,p_license_uri,'arxiv-reuse-v1',p_evidence,now());
 return p_id;
end $$;

create function app_private.library_write_item(a uuid,doc uuid,p_present boolean,s bigint,p_approval uuid default null,p_artifact uuid default null,p_intent bigint default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare li app_private.library_items; p app_private.library_policy; result uuid;
begin
 select * into li from app_private.library_items where account_id=a and document_id=doc;
 if not found then
  select * into strict p from app_private.library_policy;
  if (select count(*) from app_private.library_items where account_id=a)+1>p.account_items then raise exception 'library_account_item_limit'; end if;
  if (select count(*) from app_private.library_items)+1>p.environment_items then raise exception 'library_environment_item_limit'; end if;
  insert into app_private.library_items(account_id,document_id,removed_at,created_seq,state_seq,last_intent_seq,last_remove_seq,approval_id,artifact_id,membership_source)
  values(a,doc,case when p_present then null else now() end,s,s,coalesce(p_intent,s),case when p_present then 0 else s end,p_approval,p_artifact,
   case when p_intent is null then 'explicit' else 'import' end) returning id into result;
 else
  update app_private.library_items set removed_at=case when p_present then null else now() end,state_seq=s,membership_revision=membership_revision+1,
   last_intent_seq=coalesce(p_intent,s),last_remove_seq=case when p_present then last_remove_seq else s end,
   membership_source=case when p_intent is null then 'explicit' when li.removed_at is null then li.membership_source else 'import' end,
   -- Duplicate source aliases do not replace an already pinned source/artifact
   -- beneath reading anchors. Explicit pin/renderer upgrades are a later API.
   approval_id=coalesce(approval_id,p_approval),artifact_id=coalesce(artifact_id,p_artifact)
  where id=li.id returning id into result;
 end if;
 return result;
end $$;
create function public.v2_set_library_item(p_operation_id uuid,p_document_id uuid,p_present boolean,p_expected_revision bigint,p_approval_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); digest bytea; replay jsonb; li app_private.library_items; item_id uuid; s bigint; r jsonb;
begin
 if p_present is null or p_expected_revision is null or p_expected_revision<0 then raise exception 'invalid_membership_command'; end if;
 digest:=sha256(convert_to(jsonb_build_array('membership-v2',p_document_id,p_present,p_expected_revision,p_approval_id)::text,'UTF8'));
 perform public.worker_consume_request(a,'library-write'); perform app_private.lock_library_account(a);
 perform 1 from app_private.documents where id=p_document_id and (scope='shared_catalog' or owner_id=a) for key share;
 if not found then raise exception 'document_unavailable' using errcode='42501'; end if;
 perform app_private.lock_library_state(a);
 replay:=app_private.library_replay(a,p_operation_id,digest); if replay is not null then return replay; end if;
 select * into li from app_private.library_items where account_id=a and document_id=p_document_id;
 perform app_private.library_check_receipt_capacity(a,p_present and (li.id is null or li.removed_at is not null),
  case when not p_present and li.id is not null and li.removed_at is null and li.membership_revision=p_expected_revision then 1 else 0 end);
 if coalesce(li.membership_revision,0)<>p_expected_revision then
  r:=jsonb_build_object('status','revision_conflict','kind','item','id',li.id,'revision',coalesce(li.membership_revision,0));
  return app_private.library_receipt(a,p_operation_id,digest,r);
 end if;
 if p_present and not exists(select 1 from app_private.catalog_asset_approvals where id=coalesce(p_approval_id,li.approval_id) and document_id=p_document_id)
 then raise exception 'document_not_verified'; end if;
 s:=app_private.library_next_seq(a);
 item_id:=app_private.library_write_item(a,p_document_id,p_present,s,p_approval_id);
 perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_item_entry(a,item_id)));
 return app_private.library_receipt(a,p_operation_id,digest,jsonb_build_object('status','applied','kind','item','id',item_id,'seq',s,'revision',p_expected_revision+1));
end $$;
create or replace function public.v1_set_library_item(p_document_id uuid,p_present boolean) returns uuid
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); item_id uuid; s bigint;
begin
 if p_present is null then raise exception 'invalid_presence'; end if;
 perform public.worker_consume_request(a,'library-write'); perform app_private.lock_library_account(a);
 perform 1 from app_private.documents where id=p_document_id and (scope='shared_catalog' or owner_id=a) for key share;
 if not found then raise exception 'document_unavailable' using errcode='42501'; end if;
 perform app_private.lock_library_state(a);
 if (select v2_writes_started from app_private.library_sync_state where account_id=a) then raise exception 'library_update_required'; end if;
 if p_present and exists(select 1 from app_private.library_items where account_id=a and document_id=p_document_id and last_remove_seq>0)
 then raise exception 'library_restore_requires_v2'; end if;
 if p_present then perform app_private.library_check_receipt_capacity(a,true); end if;
 s:=app_private.library_next_seq(a); item_id:=app_private.library_write_item(a,p_document_id,p_present,s);
 perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_item_entry(a,item_id))); return item_id;
end $$;

create function public.v2_begin_import(p_operation_id uuid,p_source_id text,p_observed_cursor bigint,p_requested_revision integer default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); src text:=app_private.validate_arxiv_id(p_source_id); digest bytea; replay jsonb; s bigint; p app_private.library_policy;
begin
 if p_observed_cursor is null or p_observed_cursor<0 or p_requested_revision<1 then raise exception 'invalid_import_request'; end if;
 digest:=sha256(convert_to(jsonb_build_array('arxiv-import-v1',src,p_requested_revision,p_observed_cursor)::text,'UTF8'));
 perform public.worker_consume_request(a,'library-write'); perform app_private.lock_library_account(a); perform app_private.lock_library_state(a);
 replay:=app_private.library_replay(a,p_operation_id,digest); if replay is not null then return replay; end if;
 if p_observed_cursor>(select last_seq from app_private.library_sync_state where account_id=a) then raise exception 'invalid_library_cursor'; end if;
 select * into strict p from app_private.library_policy;
 perform app_private.library_check_receipt_capacity(a,true);
 if (select count(*) from app_private.import_requests where account_id=a)+1>p.account_imports then raise exception 'library_account_import_limit'; end if;
 if (select count(*) from app_private.import_requests)+1>p.environment_imports then raise exception 'library_environment_import_limit'; end if;
 if (select count(*) from app_private.import_requests where account_id=a and desired_present and phase in ('accepted','resolving','acquiring'))+1>p.account_active_imports
 or (select count(*) from app_private.import_requests where desired_present and phase in ('accepted','resolving','acquiring'))+1>p.environment_active_imports
 then raise exception 'library_active_import_limit'; end if;
 s:=app_private.library_next_seq(a);
 insert into app_private.import_requests(account_id,id,request_sha256,source_id,requested_revision,observed_cursor,created_seq,state_seq)
 values(a,p_operation_id,digest,src,p_requested_revision,p_observed_cursor,s,s);
 perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_import_entry(a,p_operation_id)));
 return app_private.library_receipt(a,p_operation_id,digest,jsonb_build_object('status','applied','kind','import','id',p_operation_id,'seq',s,'revision',1));
end $$;

create function app_private.library_import_command(a uuid,p_operation_id uuid,p_import_id uuid,p_expected_revision bigint,p_retry boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare digest bytea; replay jsonb; i app_private.import_requests; li app_private.library_items; s bigint; e jsonb; p app_private.library_policy;
 releases integer:=0; withdraw boolean:=false;
begin
 if p_expected_revision is null or p_expected_revision<1 then raise exception 'invalid_import_revision'; end if;
 digest:=sha256(convert_to(jsonb_build_array(case when p_retry then 'retry-import-v1' else 'cancel-import-v1' end,p_import_id,p_expected_revision)::text,'UTF8'));
 perform public.worker_consume_request(a,'library-write'); perform app_private.lock_library_account(a);
 -- Imports cannot change their document after resolution. Read it before the
 -- policy mutex to keep document/FK locks in the common order.
 select * into i from app_private.import_requests where account_id=a and id=p_import_id;
 if not found then raise exception 'import_unavailable' using errcode='42501'; end if;
 if i.document_id is not null then perform 1 from app_private.documents where id=i.document_id for key share; end if;
 perform app_private.lock_library_state(a);
 replay:=app_private.library_replay(a,p_operation_id,digest); if replay is not null then return replay; end if;
 select * into strict i from app_private.import_requests where account_id=a and id=p_import_id;
 if i.library_item_id is not null then select * into li from app_private.library_items where account_id=a and id=i.library_item_id; end if;
 if not p_retry and i.intent_revision=p_expected_revision then
  if i.desired_present and i.phase<>'ready' then releases:=releases+1; end if;
  withdraw:=li.id is not null and li.removed_at is null and li.membership_source='import' and not exists(
   select 1 from app_private.import_requests other where other.account_id=a and other.library_item_id=li.id and other.id<>i.id
   and other.desired_present and other.phase='ready' and other.created_seq>li.last_remove_seq and other.observed_cursor>=li.last_remove_seq);
  if withdraw then releases:=releases+1; end if;
 end if;
 perform app_private.library_check_receipt_capacity(a,false,releases);
 if i.intent_revision<>p_expected_revision then
  return app_private.library_receipt(a,p_operation_id,digest,jsonb_build_object('status','revision_conflict','kind','import','id',i.id,'revision',i.intent_revision));
 end if;
 if p_retry then
  if i.phase<>'failed' or not i.retryable or not i.desired_present then raise exception 'import_not_retryable'; end if;
  select * into strict p from app_private.library_policy;
  if (select count(*) from app_private.import_requests where account_id=a and desired_present and phase in ('accepted','resolving','acquiring'))+1>p.account_active_imports
  or (select count(*) from app_private.import_requests where desired_present and phase in ('accepted','resolving','acquiring'))+1>p.environment_active_imports then raise exception 'library_active_import_limit'; end if;
 end if;
 s:=app_private.library_next_seq(a);
 update app_private.import_requests set phase=case when p_retry then case when metadata_id is null then 'accepted' else 'acquiring' end else 'cancelled' end,
  desired_present=p_retry,intent_revision=intent_revision+1,state_seq=s,error_code=null,retryable=false where account_id=a and id=i.id;
 e:=jsonb_build_array(app_private.library_import_entry(a,i.id));
 if withdraw then
  -- Cancelling one import withdraws its interest; it is not an explicit Remove
  -- of every alias. Preserve the document removal fence and other Add intents.
  update app_private.library_items set removed_at=now(),state_seq=s,membership_revision=membership_revision+1 where id=li.id;
  e:=e||jsonb_build_array(app_private.library_item_entry(a,li.id));
 end if;
 perform app_private.library_emit(a,s,e);
 return app_private.library_receipt(a,p_operation_id,digest,jsonb_build_object('status','applied','kind','import','id',i.id,'seq',s,'revision',i.intent_revision+1));
end $$;
create function public.v2_cancel_import(p_operation_id uuid,p_import_id uuid,p_expected_revision bigint) returns jsonb language sql security definer set search_path='' as $$
 select app_private.library_import_command(app_private.require_actor(),p_operation_id,p_import_id,p_expected_revision,false)
$$;
create function public.v2_retry_import(p_operation_id uuid,p_import_id uuid,p_expected_revision bigint) returns jsonb language sql security definer set search_path='' as $$
 select app_private.library_import_command(app_private.require_actor(),p_operation_id,p_import_id,p_expected_revision,true)
$$;

create function public.worker_checkpoint_import(p_account_id uuid,p_import_id uuid,p_expected_state_seq bigint,p_expected_intent_revision bigint,
 p_phase text,p_metadata_id uuid default null,p_error_code text default null,p_retryable boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare i app_private.import_requests; m app_private.catalog_metadata; s bigint;
begin
 perform public.worker_consume_request(p_account_id,'library-write'); perform app_private.lock_library_account(p_account_id); perform app_private.lock_library_state(p_account_id);
 select * into i from app_private.import_requests where account_id=p_account_id and id=p_import_id;
 if not found then raise exception 'import_unavailable'; end if;
 if i.state_seq is distinct from p_expected_state_seq or i.intent_revision is distinct from p_expected_intent_revision or not i.desired_present then raise exception 'stale_import_checkpoint'; end if;
 if i.phase not in ('accepted','resolving','acquiring') or p_phase is null or p_phase not in ('resolving','acquiring','failed','source_only')
 or p_retryable is null or (p_retryable and (p_phase<>'failed' or p_error_code not in ('metadata_unavailable','download_failed','rate_limited')))
 or (p_phase in ('failed','source_only') and p_error_code is null) or (p_phase in ('resolving','acquiring') and p_error_code is not null)
 then raise exception 'invalid_import_transition'; end if;
 if p_metadata_id is not null then
  select * into m from app_private.catalog_metadata where id=p_metadata_id;
  if not found or m.source_id<>i.source_id or (i.requested_revision is not null and m.source_revision<>i.requested_revision)
  or (i.metadata_id is not null and i.metadata_id<>m.id) then raise exception 'import_source_mismatch'; end if;
 end if;
 if p_phase='acquiring' and coalesce(p_metadata_id,i.metadata_id) is null then raise exception 'import_version_required'; end if;
 s:=app_private.library_next_seq(p_account_id);
 update app_private.import_requests set phase=p_phase,metadata_id=coalesce(metadata_id,p_metadata_id),state_seq=s,error_code=p_error_code,retryable=p_retryable
 where account_id=p_account_id and id=i.id;
 perform app_private.library_emit(p_account_id,s,jsonb_build_array(app_private.library_import_entry(p_account_id,i.id)));
 return app_private.library_import_entry(p_account_id,i.id);
end $$;
create function public.worker_resolve_import(p_account_id uuid,p_import_id uuid,p_expected_state_seq bigint,p_expected_intent_revision bigint,
 p_approval_id uuid,p_artifact_id uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare i app_private.import_requests; ca app_private.catalog_asset_approvals; m app_private.catalog_metadata; li app_private.library_items;
 s bigint; item_id uuid; digest bytea; conflict boolean; e jsonb; p app_private.library_policy;
begin
 digest:=sha256(convert_to(jsonb_build_array(p_expected_state_seq,p_expected_intent_revision,p_approval_id,p_artifact_id)::text,'UTF8'));
 perform public.worker_consume_request(p_account_id,'library-write'); perform app_private.lock_library_account(p_account_id);
 select * into ca from app_private.catalog_asset_approvals where id=p_approval_id;
 if not found then raise exception 'asset_approval_required'; end if;
 perform 1 from app_private.documents where id=ca.document_id and scope='shared_catalog' for key share;
 if not found then raise exception 'document_unavailable'; end if;
 perform app_private.lock_library_state(p_account_id);
 select * into strict p from app_private.library_policy;
 select * into i from app_private.import_requests where account_id=p_account_id and id=p_import_id;
 if not found then raise exception 'import_unavailable'; end if;
 if i.resolution_sha256=digest then return app_private.library_import_entry(p_account_id,i.id); end if;
 if i.state_seq is distinct from p_expected_state_seq or i.intent_revision is distinct from p_expected_intent_revision or not i.desired_present
 or i.phase not in ('accepted','resolving','acquiring') then raise exception 'stale_import_checkpoint'; end if;
 select * into strict m from app_private.catalog_metadata where id=ca.metadata_id;
 if m.source_id<>i.source_id or (i.requested_revision is not null and m.source_revision<>i.requested_revision)
 or (i.metadata_id is not null and i.metadata_id<>m.id) then raise exception 'import_source_mismatch'; end if;
 if not exists(select 1 from app_private.stored_objects o join app_private.documents d on d.id=o.document_id where o.id=ca.original_object_id
 and o.state='verified' and o.sha256=d.sha256 and o.byte_count=d.byte_count) then raise exception 'original_object_unavailable'; end if;
 if p_artifact_id is not null and not exists(select 1 from app_private.render_artifacts r join app_private.ocr_runs o on o.id=r.ocr_run_id
 join app_private.stored_objects so on so.id=r.manifest_object_id where r.id=p_artifact_id and o.document_id=ca.document_id
 and r.renderer_version=any(p.compatible_renderers) and so.state='verified' and so.document_id=ca.document_id)
 then raise exception 'artifact_incompatible'; end if;
 select * into li from app_private.library_items where account_id=p_account_id and document_id=ca.document_id;
 conflict:=li.id is not null and li.removed_at is not null and (li.last_remove_seq>i.observed_cursor or li.last_remove_seq>i.created_seq);
 s:=app_private.library_next_seq(p_account_id);
 item_id:=li.id;
 if not conflict and (li.id is null or li.removed_at is not null or (li.last_intent_seq<i.created_seq and li.last_remove_seq<=i.observed_cursor)) then
  -- This is the original accepted Add, never a new implicit Add at completion.
  item_id:=app_private.library_write_item(p_account_id,ca.document_id,true,s,ca.id,p_artifact_id,i.created_seq);
 end if;
 update app_private.import_requests set metadata_id=m.id,approval_id=case when item_id is not null then ca.id end,
 document_id=case when item_id is not null then ca.document_id end,library_item_id=item_id,artifact_id=p_artifact_id,resolution_sha256=digest,
 phase=case when conflict then 'membership_conflict' else 'ready' end,error_code=case when conflict then 'membership_conflict' end,state_seq=s,retryable=false
 where account_id=p_account_id and id=i.id;
 e:=jsonb_build_array(app_private.library_import_entry(p_account_id,i.id));
 if item_id is not null then e:=e||jsonb_build_array(app_private.library_item_entry(p_account_id,item_id)); end if;
 perform app_private.library_emit(p_account_id,s,e);
 return app_private.library_import_entry(p_account_id,i.id);
end $$;

-- No legacy worker may create or restore membership. A caller must first use
-- an explicit library/import command. Signature and result shape are retained.
-- Budget/account precede document/FK locks, removing the old FK/budget cycle.
create or replace function public.worker_request_ocr(p_account_id uuid,p_document_id uuid,p_provider text,p_options_sha256 bytea,
 p_operation_id uuid,p_request_sha256 bytea,p_rate_version text,p_credits bigint,p_microusd bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare d app_private.documents; o app_private.ocr_runs; j app_private.processing_jobs; artifact uuid;
begin
 perform 1 from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date for update;
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null for update;
 if not found then raise exception 'account_unavailable'; end if;
 select * into d from app_private.documents where id=p_document_id and (scope='shared_catalog' or owner_id=p_account_id) for update;
 if not found then raise exception 'document_unavailable' using errcode='42501'; end if;
 if not exists(select 1 from app_private.library_items where account_id=p_account_id and document_id=d.id and removed_at is null)
 then raise exception 'library_membership_required'; end if;
 insert into app_private.ocr_runs(document_id,provider,options_sha256) values(d.id,p_provider,p_options_sha256)
 on conflict(document_id,provider,options_sha256) do nothing;
 select * into strict o from app_private.ocr_runs where document_id=d.id and provider=p_provider and options_sha256=p_options_sha256;
 select ra.id into artifact from app_private.render_artifacts ra join app_private.stored_objects so on so.id=ra.manifest_object_id
 where ra.ocr_run_id=o.id and so.state='verified' and so.document_id=d.id
 and exists(select 1 from app_private.library_policy where singleton and ra.renderer_version=any(compatible_renderers)) order by ra.ready_at desc,ra.id limit 1;
 if found then return jsonb_build_object('state','ready','artifact_id',artifact,'funding_requester',false); end if;
 select * into j from app_private.processing_jobs where ocr_run_id=o.id;
 if found then
  if j.state='ready' then raise exception 'artifact_incompatible'; end if;
  insert into app_private.job_requests(job_id,account_id) values(j.id,p_account_id) on conflict do nothing;
  return jsonb_build_object('state',j.state,'job_id',j.id,'funding_requester',j.funding_account_id=p_account_id);
 end if;
 -- The old signature has no quote/consent or import-intent fence. New paid work
 -- requires the future reviewed API, even if another feature enables spending.
 raise exception 'ocr_authorization_required';
end $$;

create function app_private.library_baseline(a uuid,p_cursor jsonb,p_limit integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare high bigint; floor bigint; after_seq bigint:=0; after_id uuid:='00000000-0000-0000-0000-000000000000'; after_kind text:=''; result jsonb;
begin
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'invalid_library_page'; end if;
 select last_seq,retained_after into strict high,floor from app_private.library_sync_state where account_id=a;
 if p_cursor is not null then
  if jsonb_typeof(p_cursor)<>'object' or p_cursor->>'account_id' is distinct from a::text or p_cursor->>'format' is distinct from '2'
  or jsonb_typeof(p_cursor->'through') is distinct from 'number' or not coalesce(p_cursor->>'through' ~ '^[0-9]+$',false)
  or jsonb_typeof(p_cursor->'created_seq') is distinct from 'number' or not coalesce(p_cursor->>'created_seq' ~ '^[0-9]+$',false)
  or jsonb_typeof(p_cursor->'id') is distinct from 'string' or not coalesce(p_cursor->>'id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',false)
  or jsonb_typeof(p_cursor->'kind') is distinct from 'string' then raise exception 'invalid_library_cursor'; end if;
  if (p_cursor->>'through')::bigint>high or (p_cursor->>'through')::bigint<0 then raise exception 'invalid_library_cursor'; end if;
  high:=(p_cursor->>'through')::bigint; after_seq:=(p_cursor->>'created_seq')::bigint; after_id:=(p_cursor->>'id')::uuid; after_kind:=p_cursor->>'kind';
  if after_seq<0 or after_seq>high or after_kind not in ('item','import') then raise exception 'invalid_library_cursor'; end if;
 end if;
 if high<floor then raise exception 'library_resync_required'; end if;
 with entries as (
  select li.created_seq,li.id,'item'::text kind,app_private.library_item_entry(a,li.id) entry from app_private.library_items li where li.account_id=a and li.created_seq<=high
  union all select i.created_seq,i.id,'import',app_private.library_import_entry(a,i.id) from app_private.import_requests i where i.account_id=a and i.created_seq<=high
 ), candidates as materialized (
  select * from entries where (created_seq,id,kind)>(after_seq,after_id,after_kind) order by created_seq,id,kind limit p_limit
 ), sized as (
  select *,sum(octet_length(entry::text)+2) over(order by created_seq,id,kind) bytes from candidates
 ), selected as materialized (select * from sized where bytes<=1046528), last_row as (
  select created_seq,id,kind from selected order by created_seq desc,id desc,kind desc limit 1
 ) select jsonb_build_object('format',2,'account_id',a,'baseline_cursor',high,'retained_after',floor,
 'entries',coalesce((select jsonb_agg(entry order by created_seq,id,kind) from selected),'[]'::jsonb),
 'next_cursor',(select jsonb_build_object('format',2,'account_id',a,'through',high,'created_seq',created_seq,'id',id,'kind',kind) from last_row),
 'has_more',exists(select 1 from entries e where (e.created_seq,e.id,e.kind)>coalesce((select row(created_seq,id,kind) from last_row),row(after_seq,after_id,after_kind)))) into result;
 return result;
end $$;
create function app_private.library_delta(a uuid,p_after bigint,p_through bigint,p_limit integer) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare high bigint; floor bigint; result jsonb;
begin
 select last_seq,retained_after into strict high,floor from app_private.library_sync_state where account_id=a;
 if p_after is null or p_after<0 or p_limit is null or p_limit not between 1 and 100
 or p_after>high or p_through>high or p_through<p_after then raise exception 'invalid_library_cursor'; end if;
 if p_after<floor then raise exception 'library_resync_required'; end if;
 high:=coalesce(p_through,high);
 with candidates as materialized (select seq,entries,encoded_bytes from app_private.library_changes where account_id=a and seq>p_after and seq<=high order by seq limit p_limit),
 sized as (select *,sum(encoded_bytes) over(order by seq) bytes from candidates),
 selected as materialized (select seq,entries from sized where bytes<=1046528),
 page as (select coalesce(jsonb_agg(jsonb_build_object('seq',seq,'entries',entries) order by seq),'[]'::jsonb) changes,coalesce(max(seq),p_after) last from selected)
 select jsonb_build_object('format',2,'account_id',a,'through',high,'retained_after',floor,'changes',changes,
 'next_cursor',case when exists(select 1 from app_private.library_changes where account_id=a and seq>page.last and seq<=high) then page.last else high end,
 'has_more',exists(select 1 from app_private.library_changes where account_id=a and seq>page.last and seq<=high)) into result from page;
 return result;
end $$;
create function app_private.consume_library_transfer(a uuid,result jsonb) returns void language plpgsql security definer set search_path='' as $$
declare p app_private.library_policy; transfer_period date:=date_trunc('month',now() at time zone 'UTC')::date; bytes bigint:=octet_length(result::text)+1024; total bigint;
begin
 if result is null or octet_length(result::text)>1048576 then raise exception 'library_page_too_large'; end if;
 select * into strict p from app_private.library_policy;
 insert into app_private.library_transfer_months values(transfer_period,'environment',bytes) on conflict(period,scope_id)
 do update set reserved_bytes=app_private.library_transfer_months.reserved_bytes+excluded.reserved_bytes returning reserved_bytes into total;
 if total>p.environment_transfer_bytes then raise exception 'library_environment_transfer_limit'; end if;
 insert into app_private.library_transfer_months values(transfer_period,a::text,bytes) on conflict(period,scope_id)
 do update set reserved_bytes=app_private.library_transfer_months.reserved_bytes+excluded.reserved_bytes returning reserved_bytes into total;
 if total>p.account_transfer_bytes then raise exception 'library_account_transfer_limit'; end if;
end $$;
create function public.v2_library_page(p_cursor jsonb default null,p_limit integer default 100) returns jsonb language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin perform public.worker_consume_request(a,'library-read'); result:=app_private.library_baseline(a,p_cursor,p_limit);
 perform app_private.consume_library_transfer(a,result); return result; end $$;
create function public.v2_library_changes(p_after bigint,p_through bigint default null,p_limit integer default 100) returns jsonb language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin perform public.worker_consume_request(a,'library-read'); result:=app_private.library_delta(a,p_after,p_through,p_limit);
 perform app_private.consume_library_transfer(a,result); return result; end $$;
create function public.worker_prune_library_transfer() returns integer language plpgsql security definer set search_path='' as $$
declare n integer;
begin delete from app_private.library_transfer_months where period<(date_trunc('month',now() at time zone 'UTC')-interval '2 months')::date;
 get diagnostics n=row_count; return n; end $$;

do $$ declare t record; f record; begin
 for t in select tablename from pg_tables where schemaname='app_private' loop
  execute format('alter table app_private.%I enable row level security',t.tablename);
 end loop;
 for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
 and p.proname in ('v2_library_page','v2_library_changes','v2_set_library_item','v2_begin_import','v2_cancel_import','v2_retry_import',
 'worker_record_arxiv_metadata','worker_approve_arxiv_asset','worker_checkpoint_import','worker_resolve_import','worker_request_ocr','worker_prune_library_transfer') loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  execute format('grant execute on function %s to %I',f.signature,case when f.signature::text like '%worker_%' then 'service_role' else 'authenticated' end);
 end loop;
end $$;
revoke all on all functions in schema app_private from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
commit;
