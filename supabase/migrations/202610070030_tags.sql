-- Topic tags (owner request 2026-10-07: "a tagging system based on topics ... make it a first
-- class citizen"; docs/architecture/TAGS.md). Additive over 010/011/014/019/020.
--
-- Catalog tags: 3-7 names from Gradstep's curated vocabulary per paper version, chosen once by
-- the pipeline worker (Claude Haiku from title + abstract, arXiv categories as a fallback),
-- platform-funded under the platform budget and never charged to readers. Personal tags: a
-- reader's own added tags and hidden catalog tags per library item, synced with a replayable,
-- revision-checked command (v2_set_item_tags mirrors 020's v2_set_item_archived). Personal tags
-- are service-visible like membership and archive state; they are not end-to-end encrypted.
--
-- Wire: item entries gain top-level `tags` (catalog), `user_tags` and `hidden_tags` only while
-- visible and non-empty, so every other entry's JSON is unchanged. An entry only changes with
-- its state_seq: items carry a projected copy of their version's catalog tags, refreshed by
-- worker_tags_project in the same transaction as the new state_seq and journal entry (or on
-- insert/re-add/re-pin, which already advance state_seq).
begin;
set local lock_timeout='15s';

-- Tag text: trimmed, single spaces, 1-40 characters, no control characters, distinct ignoring case.
create function app_private.valid_tag_list(p text[],p_max integer) returns boolean language sql immutable set search_path='' as $$
 select p is not null and coalesce(array_ndims(p),1)=1 and cardinality(p)<=p_max
  and not exists(select 1 from unnest(p) t where t is null or t<>btrim(t) or char_length(t) not between 1 and 40
   or octet_length(t)>120 or t ~ '[[:cntrl:]]' or t ~ '\s\s')
  and (select count(distinct lower(t)) from unnest(p) t)=cardinality(p)
$$;

create table app_private.tag_policy (
 singleton boolean primary key default true check(singleton),
 enabled boolean not null default true,
 -- Per-paper provider hold (Haiku: ~3k input + <100 output tokens is ~$0.003).
 hold_microusd bigint not null default 10000 check(hold_microusd between 1000 and 100000),
 max_attempts integer not null default 6 check(max_attempts between 1 and 20),
 lease_seconds integer not null default 300 check(lease_seconds between 60 and 1800)
);
insert into app_private.tag_policy default values;

-- One row per publication version that a reader has or is adding. `revision` counts tag-list
-- changes (items project it). method: null = not yet tagged; 'categories' = arXiv fallback
-- (upgraded when the model is available); 'model' = chosen by the model.
create table app_private.catalog_tags (
 version_id uuid primary key references app_private.publication_versions(id),
 revision bigint not null default 0 check(revision>=0),
 tags text[] not null default '{}' check(app_private.valid_tag_list(tags,7)),
 method text check(method in ('model','categories')),
 vocabulary text check(vocabulary ~ '^[a-z0-9-]{1,64}$'),
 model text check(model ~ '^[a-z0-9.-]{1,64}$'),
 metadata_id uuid references app_private.catalog_metadata(id),
 input_sha256 bytea check(octet_length(input_sha256)=32),
 recorded_at timestamptz,
 attempts integer not null default 0 check(attempts>=0),
 next_attempt_at timestamptz not null default now(),
 claim_id uuid, lease_until timestamptz,
 -- The current claim's platform-funded hold (transient; cleared when recorded or expired).
 operation_account_id uuid, operation_id uuid,
 check((claim_id is null)=(lease_until is null)),
 check((operation_account_id is null)=(operation_id is null)),
 check(operation_id is null or claim_id is not null),
 check((method is null)=(recorded_at is null)),
 check(method is null or (vocabulary is not null and metadata_id is not null and input_sha256 is not null)),
 check(method is distinct from 'model' or model is not null),
 foreign key(operation_account_id,operation_id) references app_private.metered_operations(account_id,id)
);
create index catalog_tags_due on app_private.catalog_tags(next_attempt_at) where claim_id is null;

alter table app_private.library_items
 add column catalog_tags text[] not null default '{}' check(app_private.valid_tag_list(catalog_tags,7)),
 add column catalog_tags_revision bigint not null default 0 check(catalog_tags_revision>=0),
 add column user_tags text[] not null default '{}' check(app_private.valid_tag_list(user_tags,12)),
 add column hidden_tags text[] not null default '{}' check(app_private.valid_tag_list(hidden_tags,8));

-- Insert, re-add and re-pin already advance state_seq: they take the version's current tags.
-- Removal forgets the reader's own tags (a re-add starts from the catalog's).
create function app_private.library_item_tags() returns trigger language plpgsql security definer set search_path='' as $$
declare t app_private.catalog_tags;
begin
 if TG_OP='UPDATE' and new.removed_at is not null and old.removed_at is null then
  new.user_tags:='{}'; new.hidden_tags:='{}';
 end if;
 if new.removed_at is null and (TG_OP='INSERT' or old.removed_at is not null or new.approval_id is distinct from old.approval_id) then
  select x.* into t from app_private.catalog_asset_approvals ca join app_private.catalog_tags x on x.version_id=ca.version_id where ca.id=new.approval_id;
  if found then new.catalog_tags:=t.tags; new.catalog_tags_revision:=t.revision;
  else new.catalog_tags:='{}'; new.catalog_tags_revision:=0; end if;
 end if;
 return new;
end $$;
create trigger library_item_tags before insert or update of approval_id,removed_at on app_private.library_items
 for each row execute function app_private.library_item_tags();

-- 020's item entry, plus `tags`, `user_tags`, `hidden_tags` (each only while visible and non-empty).
create or replace function app_private.library_item_entry(a uuid,p_id uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('kind','item','id',li.id,'document_id',li.document_id,'created_seq',li.created_seq,'state_seq',li.state_seq,
  'membership_revision',li.membership_revision,'visible',li.removed_at is null,'added_at',li.added_at,
  'last_remove_seq',li.last_remove_seq,'approval_id',li.approval_id,'version_id',ca.version_id,'metadata_id',cm.id,
  'source',case when cm.id is null then null when cm.source_id like 'openalex:%' then 'web' else 'arxiv' end,'source_id',cm.source_id,'source_revision',cm.source_revision,
  'metadata',cm.metadata,'metadata_recorded_at',cm.recorded_at,
  'source_url',case when cm.id is null then null when cm.source_id like 'openalex:%' then ca.evidence->>'source_url'
   else 'https://arxiv.org/abs/'||cm.source_id||'v'||cm.source_revision end,
  'scope',d.scope,'page_count',d.page_count,'original_object_id',ca.original_object_id,'artifact_id',li.artifact_id,
  'original_availability',coalesce(ap.original_availability,'unverified'),'render_availability',coalesce(ap.render_availability,'unverified'),
  'original_availability_revision',coalesce(ap.original_availability_revision,0),'render_availability_revision',coalesce(ap.render_availability_revision,0),
  'readiness',case when ap.render_availability='available' then 'converted_ready' when ap.original_availability='available' then 'pdf_ready'
   when ca.id is not null or li.artifact_id is not null then 'unavailable' else 'unverified' end)
  ||case when li.archived_at is not null and li.removed_at is null then jsonb_build_object('archived',true) else '{}'::jsonb end
  ||case when li.removed_at is null and cardinality(li.catalog_tags)>0 then jsonb_build_object('tags',to_jsonb(li.catalog_tags)) else '{}'::jsonb end
  ||case when li.removed_at is null and cardinality(li.user_tags)>0 then jsonb_build_object('user_tags',to_jsonb(li.user_tags)) else '{}'::jsonb end
  ||case when li.removed_at is null and cardinality(li.hidden_tags)>0 then jsonb_build_object('hidden_tags',to_jsonb(li.hidden_tags)) else '{}'::jsonb end
 from app_private.library_items li join app_private.documents d on d.id=li.document_id
 left join app_private.catalog_asset_approvals ca on ca.id=li.approval_id left join app_private.catalog_metadata cm on cm.id=ca.metadata_id
 left join app_private.library_asset_projection ap on (ap.account_id,ap.item_id)=(li.account_id,li.id) where li.account_id=a and li.id=p_id
$$;

-- Personal tags. Mirrors v2_set_item_archived (020): replayable receipt, membership-revision
-- precondition, a membership change for revision purposes. p_tags are the reader's own tags,
-- p_hidden_tags the catalog tags they removed; both replace the item's current lists.
create function public.v2_set_item_tags(p_operation_id uuid,p_document_id uuid,p_tags text[],p_hidden_tags text[],p_expected_revision bigint) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); digest bytea; replay jsonb; li app_private.library_items; s bigint; r jsonb;
begin
 if p_document_id is null or p_expected_revision is null or p_expected_revision<1
  or not app_private.valid_tag_list(p_tags,12) or not app_private.valid_tag_list(p_hidden_tags,8) then raise exception 'invalid_tags_command'; end if;
 digest:=sha256(convert_to(jsonb_build_array('tags-v1',p_document_id,to_jsonb(p_tags),to_jsonb(p_hidden_tags),p_expected_revision)::text,'UTF8'));
 perform public.worker_consume_request(a,'library-write'); perform app_private.lock_library_account(a);
 perform 1 from app_private.documents where id=p_document_id and (scope='shared_catalog' or owner_id=a) for key share;
 if not found then raise exception 'document_unavailable' using errcode='42501'; end if;
 perform app_private.lock_library_state(a);
 replay:=app_private.library_replay(a,p_operation_id,digest); if replay is not null then return replay; end if;
 select * into li from app_private.library_items where account_id=a and document_id=p_document_id;
 perform app_private.library_check_receipt_capacity(a,false);
 if li.id is null or li.removed_at is not null or li.membership_revision<>p_expected_revision then
  r:=jsonb_build_object('status','revision_conflict','kind','item','id',li.id,'revision',coalesce(li.membership_revision,0));
  return app_private.library_receipt(a,p_operation_id,digest,r);
 end if;
 s:=app_private.library_next_seq(a);
 update app_private.library_items set user_tags=p_tags,hidden_tags=p_hidden_tags,state_seq=s,membership_revision=membership_revision+1 where id=li.id;
 perform app_private.library_emit(a,s,jsonb_build_array(app_private.library_item_entry(a,li.id)));
 return app_private.library_receipt(a,p_operation_id,digest,jsonb_build_object('status','applied','kind','item','id',li.id,'seq',s,'revision',p_expected_revision+1));
end $$;

-- Versions readers have (visible items) or are adding (imports with metadata), with the
-- account that first wanted each (the funder of record for its platform-paid tagging).
create function app_private.tag_wanted_versions() returns table(version_id uuid,account_id uuid) language sql stable security definer set search_path='' as $$
 select distinct on (w.version_id) w.version_id,w.account_id from (
  select ca.version_id,li.account_id,li.added_at at_time from app_private.library_items li
   join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
   join app_private.accounts acct on acct.id=li.account_id and acct.closed_at is null where li.removed_at is null
  union all
  select cm.version_id,i.account_id,i.created_at from app_private.import_requests i join app_private.catalog_metadata cm on cm.id=i.metadata_id
   join app_private.accounts acct on acct.id=i.account_id and acct.closed_at is null
   where i.desired_present and i.phase in ('accepted','resolving','acquiring')) w
 order by w.version_id,w.at_time,w.account_id
$$;

-- Claims up to p_limit versions to tag. With p_model, each claim reserves a platform-funded hold
-- (0 reader credits) through the ordinary reservation path, so the platform budget gates every
-- call; a version whose hold is refused (budget exhausted or paused) is returned with
-- model=false (the worker records the arXiv-category fallback). Expired claims are released
-- first; their unsettled holds are spent at the ceiling (the call may have been billed).
create function public.worker_tags_claim(p_claim_id uuid,p_limit integer,p_model boolean,p_vocabulary text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare pol app_private.tag_policy; r app_private.catalog_tags; m app_private.catalog_metadata; funder uuid; op uuid; result jsonb:='[]'::jsonb;
 refused text; ceiling bigint;
begin
 if p_claim_id is null or p_limit is null or p_limit not between 1 and 20 or p_model is null or p_vocabulary is null
  or p_vocabulary !~ '^[a-z0-9-]{1,64}$' then raise exception 'invalid_tag_claim'; end if;
 select * into strict pol from app_private.tag_policy;
 for r in select * from app_private.catalog_tags where claim_id is not null and lease_until<now() order by lease_until limit 20 for update skip locked loop
  if r.operation_id is not null then
   select spend_ceiling_microusd into ceiling from app_private.metered_operations
    where account_id=r.operation_account_id and id=r.operation_id and state<>'settled';
   if found then
    begin perform public.worker_settle_operation(r.operation_account_id,r.operation_id,0,ceiling); exception when others then null; end;
   end if;
  end if;
  update app_private.catalog_tags set claim_id=null,lease_until=null,operation_account_id=null,operation_id=null,
   attempts=attempts+1,next_attempt_at=now()+interval '10 minutes' where version_id=r.version_id;
 end loop;
 if not pol.enabled then return result; end if;
 insert into app_private.catalog_tags(version_id) select w.version_id from app_private.tag_wanted_versions() w on conflict(version_id) do nothing;
 for r in select t.* from app_private.catalog_tags t
  where t.claim_id is null and t.next_attempt_at<=now() and t.attempts<pol.max_attempts
   and (t.method is null or (p_model and (t.method='categories' or t.vocabulary<>p_vocabulary)))
   and t.version_id in (select w.version_id from app_private.tag_wanted_versions() w)
  order by (t.method is null) desc,t.next_attempt_at,t.version_id limit p_limit for update of t skip locked loop
  select w.account_id into funder from app_private.tag_wanted_versions() w where w.version_id=r.version_id;
  select * into m from app_private.catalog_metadata where version_id=r.version_id order by recorded_at desc,id limit 1;
  op:=null; refused:=null;
  if p_model then
   op:=gen_random_uuid();
   begin
    perform public.worker_reserve_operation(funder,op,'metadata',
     sha256(convert_to('gradstep-tags/v1'||chr(10)||r.version_id::text||chr(10)||m.id::text||chr(10)||p_vocabulary,'UTF8')),
     'beta-credits-v1',0,pol.hold_microusd);
   exception when others then
    refused:=case when sqlerrm ~ '^[a-z_]{1,64}$' then sqlerrm else 'budget_unavailable' end; op:=null;
   end;
   -- The funder already has three holds open (often this same batch): leave it for the next claim.
   continue when refused='too_many_active_operations';
  end if;
  update app_private.catalog_tags set claim_id=p_claim_id,lease_until=now()+make_interval(secs=>pol.lease_seconds),
   operation_account_id=case when op is null then null else funder end,operation_id=op where version_id=r.version_id;
  result:=result||jsonb_build_array(jsonb_build_object('version_id',r.version_id,'claim_id',p_claim_id,'metadata_id',m.id,
   'title',m.metadata->>'title','abstract',m.metadata->>'abstract',
   'categories',case when jsonb_typeof(m.metadata->'categories')='array' then m.metadata->'categories' else '[]'::jsonb end,
   'model',op is not null,'hold_microusd',case when op is null then 0 else pol.hold_microusd end,'model_refused',refused,
   'method',r.method,'tags',to_jsonb(r.tags)));
 end loop;
 return result;
end $$;

-- Records a claimed version's result and settles its hold at the actual provider cost (0 reader
-- credits). A fallback never replaces tags the model chose. Returns the visible items whose
-- projected tags are now stale (the worker projects each with worker_tags_project).
create function public.worker_tags_record(p_version_id uuid,p_claim_id uuid,p_metadata_id uuid,p_tags text[],p_method text,p_vocabulary text,
 p_model text,p_input_sha256 bytea,p_provider_event_id text,p_units jsonb,p_microusd bigint,p_model_attempted boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r app_private.catalog_tags; keep boolean; next_tags text[]; changed boolean; tries integer; items jsonb;
begin
 if p_version_id is null or p_claim_id is null or p_method not in ('model','categories') or not app_private.valid_tag_list(p_tags,7)
  or p_vocabulary is null or p_vocabulary !~ '^[a-z0-9-]{1,64}$' or (p_model is not null and p_model !~ '^[a-z0-9.-]{1,64}$')
  or (p_method='model' and p_model is null) or octet_length(p_input_sha256) is distinct from 32 or p_microusd is null or p_microusd<0
  or p_model_attempted is null or (p_provider_event_id is not null and length(p_provider_event_id) not between 1 and 256)
  or (p_units is not null and (jsonb_typeof(p_units)<>'object' or octet_length(p_units::text)>4096))
  or not exists(select 1 from app_private.catalog_metadata where id=p_metadata_id and version_id=p_version_id) then raise exception 'invalid_tag_result'; end if;
 select * into r from app_private.catalog_tags where version_id=p_version_id for update;
 if not found or r.claim_id is distinct from p_claim_id then raise exception 'stale_tag_claim'; end if;
 if r.operation_id is null and (p_method='model' or p_microusd>0 or p_provider_event_id is not null) then raise exception 'unfunded_tag_call'; end if;
 if r.operation_id is not null then
  perform public.worker_settle_operation(r.operation_account_id,r.operation_id,0,p_microusd);
  if p_provider_event_id is not null then
   perform public.worker_record_provider_usage(r.operation_account_id,r.operation_id,'anthropic',p_provider_event_id,p_model,coalesce(p_units,'{}'::jsonb),p_microusd);
  end if;
 end if;
 keep:=p_method='categories' and r.method='model';
 next_tags:=case when keep then r.tags else p_tags end;
 changed:=next_tags is distinct from r.tags;
 tries:=case when p_method='model' then 0 when p_model_attempted then r.attempts+1 else r.attempts end;
 update app_private.catalog_tags set tags=next_tags,revision=revision+case when changed then 1 else 0 end,
  method=case when keep then method else p_method end,vocabulary=case when keep then vocabulary else p_vocabulary end,
  model=case when keep then model when p_method='model' then p_model end,
  metadata_id=case when keep then metadata_id else p_metadata_id end,input_sha256=case when keep then input_sha256 else p_input_sha256 end,
  recorded_at=case when keep then recorded_at else now() end,attempts=tries,
  -- Upgrades from the fallback: backoff after model failures; an hour when the model was unavailable.
  next_attempt_at=case when p_method='model' then now() when p_model_attempted then now()+make_interval(mins=>least(1440,10*power(4,greatest(tries-1,0))::integer))
   else now()+interval '1 hour' end,
  claim_id=null,lease_until=null,operation_account_id=null,operation_id=null
 where version_id=p_version_id returning * into r;
 select coalesce(jsonb_agg(jsonb_build_object('account_id',x.account_id,'item_id',x.id)),'[]'::jsonb) into items from (
  select li.account_id,li.id from app_private.library_items li join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
   join app_private.accounts acct on acct.id=li.account_id and acct.closed_at is null
  where ca.version_id=p_version_id and li.removed_at is null and li.catalog_tags_revision<>r.revision order by li.account_id,li.id limit 1000) x;
 return jsonb_build_object('version_id',p_version_id,'revision',r.revision,'method',r.method,'tags',to_jsonb(r.tags),'changed',changed,'items',items);
end $$;

-- Brings one item's projected catalog tags up to date. Same lock order and journal discipline
-- as worker_project_library_availability (011): account -> document -> library state.
create function public.worker_tags_project(p_account_id uuid,p_item_id uuid) returns boolean
language plpgsql security definer set search_path='' as $$
declare li app_private.library_items; t app_private.catalog_tags; s bigint;
begin
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null for no key update;
 if not found then return false; end if;
 select * into li from app_private.library_items where account_id=p_account_id and id=p_item_id;
 if not found then return false; end if;
 perform 1 from app_private.documents where id=li.document_id for key share;
 perform app_private.lock_library_state(p_account_id);
 select * into strict li from app_private.library_items where account_id=p_account_id and id=p_item_id;
 select x.* into t from app_private.catalog_asset_approvals ca join app_private.catalog_tags x on x.version_id=ca.version_id where ca.id=li.approval_id;
 if not found or t.revision=li.catalog_tags_revision then return false; end if;
 if li.removed_at is null and li.catalog_tags is distinct from t.tags then
  s:=app_private.library_next_seq(p_account_id);
  update app_private.library_items set catalog_tags=t.tags,catalog_tags_revision=t.revision,state_seq=s where account_id=p_account_id and id=p_item_id;
  perform app_private.library_emit(p_account_id,s,jsonb_build_array(app_private.library_item_entry(p_account_id,p_item_id)));
  return true;
 end if;
 -- No visible change (a removed item shows no tags; or the same list): no new state.
 update app_private.library_items set catalog_tags=t.tags,catalog_tags_revision=t.revision where account_id=p_account_id and id=p_item_id;
 return false;
end $$;

-- Items whose projection lags their version's tags (a worker that stopped mid-projection).
create function public.worker_tags_pending_projection(p_limit integer) returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('account_id',x.account_id,'item_id',x.id)),'[]'::jsonb) from (
  select li.account_id,li.id from app_private.library_items li join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
   join app_private.catalog_tags t on t.version_id=ca.version_id join app_private.accounts acct on acct.id=li.account_id and acct.closed_at is null
  where li.removed_at is null and li.catalog_tags_revision<>t.revision order by li.account_id,li.id limit greatest(1,least(coalesce(p_limit,100),500))) x
$$;

-- Operator view (backfill script, admin): counts only, no titles or accounts.
create function public.worker_tags_status() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
  'enabled',(select enabled from app_private.tag_policy),
  'wanted',(select count(*) from app_private.tag_wanted_versions()),
  'untagged',(select count(*) from app_private.tag_wanted_versions() w left join app_private.catalog_tags t on t.version_id=w.version_id where t.method is null),
  'model',(select count(*) from app_private.catalog_tags where method='model'),
  'categories',(select count(*) from app_private.catalog_tags where method='categories'),
  'claimed',(select count(*) from app_private.catalog_tags where claim_id is not null),
  'stale_items',(select count(*) from app_private.library_items li join app_private.catalog_asset_approvals ca on ca.id=li.approval_id
   join app_private.catalog_tags t on t.version_id=ca.version_id where li.removed_at is null and li.catalog_tags_revision<>t.revision))
$$;

create function public.worker_set_tagging_enabled(p_enabled boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare p app_private.tag_policy;
begin
 if p_enabled is null then raise exception 'invalid_policy'; end if;
 update app_private.tag_policy set enabled=p_enabled where singleton returning * into p;
 return to_jsonb(p);
end $$;

alter table app_private.tag_policy enable row level security;
alter table app_private.catalog_tags enable row level security;
revoke all on app_private.tag_policy,app_private.catalog_tags from public,anon,authenticated,service_role;
revoke all on all functions in schema app_private from public,anon,authenticated,service_role;
revoke all on function public.v2_set_item_tags(uuid,uuid,text[],text[],bigint) from public,anon,authenticated,service_role;
grant execute on function public.v2_set_item_tags(uuid,uuid,text[],text[],bigint) to authenticated;
revoke all on function public.worker_tags_claim(uuid,integer,boolean,text),
 public.worker_tags_record(uuid,uuid,uuid,text[],text,text,text,bytea,text,jsonb,bigint,boolean),
 public.worker_tags_project(uuid,uuid),public.worker_tags_pending_projection(integer),public.worker_tags_status(),
 public.worker_set_tagging_enabled(boolean) from public,anon,authenticated;
grant execute on function public.worker_tags_claim(uuid,integer,boolean,text),
 public.worker_tags_record(uuid,uuid,uuid,text[],text,text,text,bytea,text,jsonb,bigint,boolean),
 public.worker_tags_project(uuid,uuid),public.worker_tags_pending_projection(integer),public.worker_tags_status(),
 public.worker_set_tagging_enabled(boolean) to service_role;
notify pgrst,'reload schema';
commit;
