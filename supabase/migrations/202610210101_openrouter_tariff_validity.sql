-- 0101: Every OpenRouter price card's validity is one renewable table read by SQL and the chat function (review A4,
-- 2026-10-21; design: docs/architecture/PROVIDER_SPENDING.md "Tariff validity").
-- Before: the date 2027-01-01 was a literal in nine copies of worker_provider_attempt_begin and in four TypeScript
-- constants. At that instant every chat, tag and podcast call would be refused as `tariff_expired` while chat still
-- published the models, so readers' holds were placed, refused and retried in a loop, and nothing warned beforehand.
-- Now: one row per admitted model (the same date for now; no price changes), renewable by an owner with evidence and an
-- audit row, never beyond six months ahead. A changed price still needs a migration and a code change. Chat reads the
-- table (worker_provider_spending_policy) to stop offering a model a day before its card lapses; podcast quotes stop a
-- day before; Health and the scheduled budget check warn six weeks ahead.
begin;
set local lock_timeout='15s';

create table app_private.openrouter_tariffs (
 -- The model as admitted (provider_attempts.model).
 model text primary key check(model ~ '^[a-z0-9][a-z0-9./-]{0,127}$'),
 tariff text not null check(tariff ~ '^[a-z0-9][a-z0-9.-]{0,127}$'),
 valid_until timestamptz not null,
 evidence_reference text not null check(length(evidence_reference) between 3 and 256),
 updated_at timestamptz not null default now()
);
alter table app_private.openrouter_tariffs enable row level security;
revoke all on app_private.openrouter_tariffs from public,anon,authenticated;
insert into app_private.openrouter_tariffs(model,tariff,valid_until,evidence_reference) values
 ('gemini-3.8-flash','openrouter-google-flash-vertex-us-20261017','2027-01-01T00:00:00Z','migration 089 reviewed card'),
 ('anthropic/claude-haiku-5.5','openrouter-claude-vertex-us-20261017','2027-01-01T00:00:00Z','migration 089 reviewed card'),
 ('anthropic/claude-sonnet-5.5','openrouter-claude-vertex-us-20261017','2027-01-01T00:00:00Z','migration 089 reviewed card'),
 ('anthropic/claude-opus-5.5','openrouter-claude-vertex-us-20261017','2027-01-01T00:00:00Z','migration 089 reviewed card'),
 ('deepseek/deepseek-v4.1-flash-1017','openrouter-deepseek-deepinfra-20261018','2027-01-01T00:00:00Z','migration 089 reviewed card'),
 ('deepseek/deepseek-v4-pro-0813','openrouter-deepseek-deepinfra-20261018','2027-01-01T00:00:00Z','migration 089 reviewed card'),
 ('google/gemini-3.8-flash-tts','openrouter-gemini-tts-upper-20270101','2027-01-01T00:00:00Z','migration 089 reviewed card');

-- A model without a row has no valid card (fails closed). Admission (0100) and every pricing snapshot read this.
create or replace function app_private.openrouter_tariff_expires(p_model text) returns timestamptz
language sql stable security definer set search_path='' as $$
 select coalesce((select valid_until from app_private.openrouter_tariffs where model=p_model),'-infinity'::timestamptz)
$$;

-- Renewing a card's validity (the reviewed prices still hold) is an owner's audited act, at most six months ahead;
-- shortening it retires the model sooner. Evidence is a short reference (for example the endpoints listing's date).
create function public.worker_openrouter_tariff_renew(p_actor_id uuid,p_request_id uuid,p_model text,p_valid_until timestamptz,
 p_evidence_reference text,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t app_private.openrouter_tariffs; prior app_private.admin_audit_events;
begin
 perform app_private.require_owner_account(p_actor_id);
 if p_request_id is null or p_model is null or p_valid_until is null or p_valid_until>now()+interval '183 days'
  or p_evidence_reference is null or length(p_evidence_reference) not between 3 and 256 or p_evidence_reference !~ '^[a-zA-Z0-9._:/ -]+$'
  or p_reason is null or length(btrim(p_reason)) not between 3 and 500 then raise exception 'invalid_tariff_renewal'; end if;
 select * into prior from app_private.admin_audit_events where id=p_request_id;
 if found then
  if prior.action<>'openrouter_tariff' or prior.actor_id<>p_actor_id or prior.target_id<>p_model
   or (prior.details->>'valid_until')::timestamptz<>p_valid_until then raise exception 'request_id_conflict'; end if;
  return jsonb_build_object('replayed',true,'model',p_model,'valid_until',(select valid_until from app_private.openrouter_tariffs where model=p_model));
 end if;
 select * into t from app_private.openrouter_tariffs where model=p_model for update;
 -- A new model or a changed price is a reviewed migration and code change, never a renewal.
 if not found then raise exception 'tariff_unknown'; end if;
 update app_private.openrouter_tariffs set valid_until=p_valid_until,evidence_reference=p_evidence_reference,updated_at=now() where model=p_model;
 insert into app_private.admin_audit_events(id,actor_id,action,target_id,reason,details)
 values(p_request_id,p_actor_id,'openrouter_tariff',p_model,btrim(p_reason),jsonb_build_object('tariff',t.tariff,
  'valid_until_before',t.valid_until,'valid_until',p_valid_until,'evidence_reference',p_evidence_reference));
 return jsonb_build_object('replayed',false,'model',p_model,'tariff',t.tariff,'valid_until',p_valid_until);
end $$;
revoke all on function public.worker_openrouter_tariff_renew(uuid,uuid,text,timestamptz,text,text) from public,anon,authenticated;
grant execute on function public.worker_openrouter_tariff_renew(uuid,uuid,text,timestamptz,text,text) to service_role;

-- The chat function's policy read (started with every request) also names each card's validity.
create or replace function public.worker_provider_spending_policy() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('native_search_enabled',false,'tavily_enabled',
  p.enabled and exists(select 1 from app_private.provider_allowance_periods a where a.enabled and a.overage_disabled
   and now()>=a.starts_at and now()<a.ends_at and a.baseline_units+a.spent_units+a.reserved_units<a.limit_units),
  'openrouter_tariffs',(select coalesce(jsonb_object_agg(t.model,t.valid_until),'{}'::jsonb) from app_private.openrouter_tariffs t))
 from app_private.provider_spending_policy p where singleton
$$;

-- Cards that lapse within six weeks (42 days): Health's Attention and the scheduled budget check.
create function app_private.openrouter_tariff_attention() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('warn_days',42,'soonest_valid_until',(select min(valid_until) from app_private.openrouter_tariffs),
  'expiring',coalesce((select jsonb_agg(jsonb_build_object('model',model,'tariff',tariff,'valid_until',valid_until) order by valid_until,model)
   from app_private.openrouter_tariffs where valid_until<now()+interval '42 days'),'[]'::jsonb))
$$;
revoke all on function app_private.openrouter_tariff_attention() from public,anon,authenticated;

create or replace function app_private.budget_health_extra() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('attempt_capacity_eighty_percent',coalesce((app_private.provider_attempt_window()->>'eighty_percent')::boolean,false),
  'tariffs_expiring_within_42d',jsonb_array_length(app_private.openrouter_tariff_attention()->'expiring'),
  'soonest_tariff_expiry',app_private.openrouter_tariff_attention()->'soonest_valid_until')
$$;

-- Health gains fields from one replaceable function, as the budget check does (0100).
create function app_private.admin_health_extra() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('tariffs',app_private.openrouter_tariff_attention())
$$;
revoke all on function app_private.admin_health_extra() from public,anon,authenticated;
alter function public.v1_admin_health(integer) rename to admin_health_before_0101;
alter function public.admin_health_before_0101(integer) set schema app_private;
revoke all on function app_private.admin_health_before_0101(integer) from public,anon,authenticated;
create function public.v1_admin_health(p_days integer default 30) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 -- The earlier function checks the owner with MFA and the window before anything is read.
 return app_private.admin_health_before_0101(p_days)||app_private.admin_health_extra();
end $$;
revoke all on function public.v1_admin_health(integer) from public,anon;
grant execute on function public.v1_admin_health(integer) to authenticated;

-- A podcast is quoted only while its script and speech cards stay valid for a day (a job runs minutes, not days). An
-- already-made episode (`reuse`) or a running one (`join`) needs no new card and is answered as before; refusing a new
-- quote rolls back everything the earlier function wrote.
alter function public.v1_podcast_quote(uuid,uuid,text,text,jsonb) rename to podcast_quote_before_0101;
alter function public.podcast_quote_before_0101(uuid,uuid,text,text,jsonb) set schema app_private;
revoke all on function app_private.podcast_quote_before_0101(uuid,uuid,text,text,jsonb) from public,anon,authenticated,service_role;
create function public.v1_podcast_quote(p_item_id uuid,p_request_id uuid,p_profile text default null,p_writer text default null,p_device jsonb default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; spec jsonb;
begin
 result:=app_private.podcast_quote_before_0101(p_item_id,p_request_id,p_profile,p_writer,p_device);
 if result ? 'quote' then
  select pr.spec into strict spec from app_private.podcast_quotes q join app_private.podcast_profiles pr on (pr.id,pr.version)=(q.profile_id,q.profile_version)
   where q.id=(result->'quote'->>'id')::uuid;
  if spec->>'consent_version'='podcast-private-v3' and (
    app_private.openrouter_tariff_expires(spec->'script'->>'transport_model')<now()+interval '1 day'
    or app_private.openrouter_tariff_expires('google/'||(spec->'speech'->>'model'))<now()+interval '1 day') then
   raise exception 'podcast_unavailable';
  end if;
 end if;
 return result;
end $$;
revoke all on function public.v1_podcast_quote(uuid,uuid,text,text,jsonb) from public,anon,service_role;
grant execute on function public.v1_podcast_quote(uuid,uuid,text,text,jsonb) to authenticated;

notify pgrst,'reload schema';
commit;
