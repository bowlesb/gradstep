begin;
create table app_private.keyrings (
  account_id uuid primary key references app_private.accounts(id),
  epoch integer not null check(epoch > 0),
  recovery_package bytea not null check(octet_length(recovery_package) between 28 and 65536),
  management_verifier bytea not null check(octet_length(management_verifier)=32),
  next_cursor bigint not null default 0 check(next_cursor>=0),
  created_at timestamptz not null default now()
);
create table app_private.devices (
  account_id uuid not null references app_private.keyrings(account_id),
  id uuid not null,
  public_key bytea not null check(octet_length(public_key)=32),
  challenge bytea not null check(octet_length(challenge)=32),
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  acknowledged_cursor bigint not null default 0 check(acknowledged_cursor>=0),
  primary key(account_id,id)
);
create table app_private.device_envelopes (
  account_id uuid not null,
  device_id uuid not null,
  epoch integer not null check(epoch>0),
  envelope bytea not null check(octet_length(envelope) between 60 and 65536),
  primary key(account_id,device_id,epoch),
  foreign key(account_id,device_id) references app_private.devices(account_id,id)
);
create table app_private.enrollment_requests (
  account_id uuid not null references app_private.keyrings(account_id),
  id uuid primary key,
  device_id uuid not null,
  public_key bytea not null check(octet_length(public_key)=32),
  challenge bytea not null check(octet_length(challenge)=32),
  expires_at timestamptz not null default now()+interval '15 minutes',
  approved_at timestamptz,
  unique(account_id,id)
);
create table app_private.sync_events (
  account_id uuid not null references app_private.keyrings(account_id),
  id uuid not null,
  device_id uuid not null,
  cursor bigint not null check(cursor>0),
  epoch integer not null check(epoch>0),
  format integer not null check(format=1),
  ciphertext bytea not null check(octet_length(ciphertext) between 28 and 262144),
  ciphertext_sha256 bytea generated always as (sha256(ciphertext)) stored,
  committed_at timestamptz not null default now(),
  primary key(account_id,id),
  unique(account_id,cursor),
  foreign key(account_id,device_id) references app_private.devices(account_id,id)
);

-- The domain-bound management token is independent of content keys. Never log
-- request bodies/arguments for these RPCs. Compare a hash, never persist the token.
create function app_private.verify_management(a uuid, token bytea) returns boolean
language sql stable security definer set search_path = '' as $$
 select octet_length(token)=32 and exists(select 1 from app_private.keyrings where account_id=a
   and management_verifier=sha256(convert_to('science-reader/management/v1/'||a::text||'/','UTF8')||token))
$$;
create function public.v1_bootstrap_keys(p_device_id uuid,p_public_key bytea,p_recovery_package bytea,
  p_management_token bytea,p_device_envelope bytea,p_challenge bytea) returns boolean
language plpgsql security definer set search_path = '' as $$
declare a uuid := app_private.require_actor();
begin
  if octet_length(p_management_token)<>32 or p_management_token is null then raise exception 'invalid_management_token'; end if;
  -- The account row serializes racing first-device initializations.
  perform 1 from app_private.accounts where id=a for update;
  if exists(select 1 from app_private.keyrings where account_id=a) then return false; end if;
  insert into app_private.keyrings(account_id,epoch,recovery_package,management_verifier)
    values(a,1,p_recovery_package,sha256(convert_to('science-reader/management/v1/'||a::text||'/','UTF8')||p_management_token));
  insert into app_private.devices(account_id,id,public_key,challenge) values(a,p_device_id,p_public_key,p_challenge);
  insert into app_private.device_envelopes values(a,p_device_id,1,p_device_envelope);
  return true;
end $$;
create function public.v1_key_state(p_device_id uuid) returns jsonb language sql stable security definer set search_path = '' as $$
 select jsonb_build_object('epoch',k.epoch,'recovery_package',k.recovery_package,
  'device_envelope',(select e.envelope from app_private.device_envelopes e join app_private.devices d on
    d.account_id=e.account_id and d.id=e.device_id where e.account_id=k.account_id and e.device_id=p_device_id
    and e.epoch=k.epoch and d.revoked_at is null))
 from app_private.keyrings k where account_id=app_private.require_actor()
$$;
create function public.v1_request_enrollment(p_request_id uuid,p_device_id uuid,p_public_key bytea,p_challenge bytea)
returns uuid language plpgsql security definer set search_path = '' as $$
declare a uuid := app_private.require_actor(); r app_private.enrollment_requests;
begin
  perform 1 from app_private.keyrings where account_id=a for update;
  select * into r from app_private.enrollment_requests where id=p_request_id;
  if found then
    if r.account_id is distinct from a or r.device_id is distinct from p_device_id or r.public_key is distinct from p_public_key or r.challenge is distinct from p_challenge then
      raise exception 'enrollment_id_conflict';
    end if;
    return r.id;
  end if;
  if (select count(*) from app_private.enrollment_requests where account_id=a and expires_at>now() and approved_at is null)>=5 then
    raise exception 'too_many_enrollment_requests';
  end if;
  insert into app_private.enrollment_requests(account_id,id,device_id,public_key,challenge)
    values(a,p_request_id,p_device_id,p_public_key,p_challenge);
  return p_request_id;
end $$;
create function public.v1_enrollment_requests() returns jsonb language sql stable security definer set search_path = '' as $$
 select coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) from app_private.enrollment_requests r
 where account_id=app_private.require_actor() and expires_at>now() and approved_at is null
$$;
create function public.v1_approve_enrollment(p_request_id uuid,p_epoch integer,p_management_token bytea,
  p_expected_public_key bytea,p_expected_challenge bytea,p_envelope bytea) returns void
language plpgsql security definer set search_path = '' as $$
declare a uuid := app_private.require_actor(); k app_private.keyrings; r app_private.enrollment_requests;
begin
  select * into strict k from app_private.keyrings where account_id=a for update;
  if not coalesce(app_private.verify_management(a,p_management_token),false) or k.epoch is distinct from p_epoch then raise exception 'key_authority_required' using errcode='42501'; end if;
  select * into strict r from app_private.enrollment_requests where account_id=a and id=p_request_id for update;
  if r.expires_at<=now() or r.public_key is distinct from p_expected_public_key or r.challenge is distinct from p_expected_challenge then raise exception 'enrollment_mismatch'; end if;
  if r.approved_at is not null then
    if not exists(select 1 from app_private.device_envelopes where account_id=a and device_id=r.device_id and epoch=p_epoch and envelope=p_envelope) then raise exception 'enrollment_conflict'; end if;
    return;
  end if;
  insert into app_private.devices(account_id,id,public_key,challenge) values(a,r.device_id,r.public_key,r.challenge);
  insert into app_private.device_envelopes values(a,r.device_id,p_epoch,p_envelope);
  update app_private.enrollment_requests set approved_at=now() where id=r.id;
end $$;
create function public.v1_append_event(p_device_id uuid,p_id uuid,p_epoch integer,p_format integer,p_ciphertext bytea,
  p_management_token bytea) returns bigint language plpgsql security definer set search_path = '' as $$
declare a uuid := app_private.require_actor(); k app_private.keyrings; e app_private.sync_events; c bigint;
begin
  -- Row lock is held through commit, giving commit-ordered account cursors.
  select * into strict k from app_private.keyrings where account_id=a for update;
  if not coalesce(app_private.verify_management(a,p_management_token),false) or not exists(
    select 1 from app_private.devices where account_id=a and id=p_device_id and revoked_at is null
  ) then raise exception 'key_authority_required' using errcode='42501'; end if;
  select * into e from app_private.sync_events where account_id=a and id=p_id;
  if found then
    if e.device_id is distinct from p_device_id or e.epoch is distinct from p_epoch or e.format is distinct from p_format or e.ciphertext is distinct from p_ciphertext then raise exception 'event_id_conflict'; end if;
    return e.cursor;
  end if;
  if p_epoch is distinct from k.epoch then raise exception 'stale_key_epoch'; end if;
  update app_private.keyrings set next_cursor=next_cursor+1 where account_id=a returning next_cursor into c;
  insert into app_private.sync_events(account_id,id,device_id,cursor,epoch,format,ciphertext)
    values(a,p_id,p_device_id,c,p_epoch,p_format,p_ciphertext);
  return c;
end $$;
create function public.v1_pull_events(p_after bigint,p_limit integer default 200) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare a uuid := app_private.require_actor(); result jsonb;
begin
  if p_after is null or p_after<0 or p_limit is null or p_limit not between 1 and 200 then raise exception 'invalid_cursor_page'; end if;
  select coalesce(jsonb_agg(to_jsonb(e) order by e.cursor),'[]'::jsonb) into result from (
    select id,device_id,cursor,epoch,format,ciphertext,ciphertext_sha256 from app_private.sync_events
    where account_id=a and cursor>p_after order by cursor limit p_limit
  ) e;
  return result;
end $$;
create function public.v1_acknowledge_cursor(p_device_id uuid,p_cursor bigint,p_management_token bytea) returns void
language plpgsql security definer set search_path = '' as $$
declare a uuid := app_private.require_actor(); k app_private.keyrings;
begin
  select * into strict k from app_private.keyrings where account_id=a for update;
  if not coalesce(app_private.verify_management(a,p_management_token),false) then raise exception 'key_authority_required' using errcode='42501'; end if;
  if p_cursor is null or p_cursor<0 or p_cursor>k.next_cursor then raise exception 'invalid_cursor'; end if;
  update app_private.devices set acknowledged_cursor=greatest(acknowledged_cursor,p_cursor)
    where account_id=a and id=p_device_id and revoked_at is null;
  if not found then raise exception 'device_unavailable'; end if;
end $$;

do $$ declare t record; begin
 for t in select tablename from pg_tables where schemaname='app_private' loop
  execute format('alter table app_private.%I enable row level security',t.tablename);
 end loop;
end $$;
revoke all on all functions in schema app_private from public,anon,authenticated;
revoke all on function public.v1_bootstrap_keys(uuid,bytea,bytea,bytea,bytea,bytea),
 public.v1_key_state(uuid), public.v1_request_enrollment(uuid,uuid,bytea,bytea),public.v1_enrollment_requests(),
 public.v1_approve_enrollment(uuid,integer,bytea,bytea,bytea,bytea),
 public.v1_append_event(uuid,uuid,integer,integer,bytea,bytea),public.v1_pull_events(bigint,integer),
 public.v1_acknowledge_cursor(uuid,bigint,bytea) from public,anon;
grant execute on function public.v1_bootstrap_keys(uuid,bytea,bytea,bytea,bytea,bytea),
 public.v1_key_state(uuid), public.v1_request_enrollment(uuid,uuid,bytea,bytea),public.v1_enrollment_requests(),
 public.v1_approve_enrollment(uuid,integer,bytea,bytea,bytea,bytea),
 public.v1_append_event(uuid,uuid,integer,integer,bytea,bytea),public.v1_pull_events(bigint,integer),
 public.v1_acknowledge_cursor(uuid,bigint,bytea) to authenticated;
commit;
