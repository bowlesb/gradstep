-- Additive beta capacity contract. No encrypted payloads or cursors change.
-- Old readers receive an explicit error if a count-based page exceeds 1 MiB;
-- v2 readers follow the byte-bounded page's explicit continuation.
begin;
lock table app_private.sync_events in share row exclusive mode;

create table app_private.sync_storage_policy (
 singleton boolean primary key default true check(singleton),
 account_bytes bigint not null check(account_bytes>0),
 environment_bytes bigint not null check(environment_bytes>=account_bytes),
 account_events bigint not null check(account_events>0),
 environment_events bigint not null check(environment_events>=account_events)
);
insert into app_private.sync_storage_policy values(true,67108864,536870912,100000,500000);
create table app_private.sync_environment_storage (
 singleton boolean primary key default true check(singleton),
 ciphertext_bytes bigint not null check(ciphertext_bytes>=0),
 event_count bigint not null check(event_count>=0)
);
create table app_private.sync_account_storage (
 account_id uuid primary key references app_private.accounts(id) on delete cascade,
 ciphertext_bytes bigint not null check(ciphertext_bytes>=0),
 event_count bigint not null check(event_count>=0)
);
insert into app_private.sync_environment_storage
 select true,coalesce(sum(octet_length(ciphertext)),0),count(*) from app_private.sync_events;
insert into app_private.sync_account_storage
 select account_id,sum(octet_length(ciphertext)),count(*) from app_private.sync_events group by account_id;

create function app_private.account_sync_storage() returns trigger
language plpgsql security definer set search_path = '' as $$
declare a uuid; delta_bytes bigint; delta_events bigint; policy app_private.sync_storage_policy;
 environment app_private.sync_environment_storage; account app_private.sync_account_storage;
begin
 if TG_OP='INSERT' then a:=NEW.account_id; delta_bytes:=octet_length(NEW.ciphertext); delta_events:=1;
 else a:=OLD.account_id; delta_bytes:=-octet_length(OLD.ciphertext); delta_events:=-1; end if;
 select * into strict policy from app_private.sync_storage_policy where singleton;
 -- The append RPC already holds the account keyring. All accounts then acquire
 -- environment storage before their own counter. Deletion jobs use this order.
 update app_private.sync_environment_storage set ciphertext_bytes=ciphertext_bytes+delta_bytes,event_count=event_count+delta_events
 where singleton returning * into strict environment;
 if delta_events>0 and (environment.ciphertext_bytes>policy.environment_bytes or environment.event_count>policy.environment_events)
 then raise exception 'sync_environment_storage_limit'; end if;
 if delta_events>0 then
  insert into app_private.sync_account_storage values(a,delta_bytes,delta_events)
  on conflict(account_id) do update set ciphertext_bytes=app_private.sync_account_storage.ciphertext_bytes+excluded.ciphertext_bytes,
   event_count=app_private.sync_account_storage.event_count+excluded.event_count returning * into account;
 else
  update app_private.sync_account_storage set ciphertext_bytes=ciphertext_bytes+delta_bytes,event_count=event_count+delta_events
   where account_id=a returning * into strict account;
 end if;
 if delta_events>0 and (account.ciphertext_bytes>policy.account_bytes or account.event_count>policy.account_events)
 then raise exception 'sync_account_storage_limit'; end if;
 return null;
end $$;
create trigger sync_events_capacity after insert or delete on app_private.sync_events
 for each row execute function app_private.account_sync_storage();
create trigger sync_events_immutable before update on app_private.sync_events
 for each row execute function app_private.immutable_record();

create table app_private.sync_transfer_policy (
 singleton boolean primary key default true check(singleton),
 account_bytes bigint not null check(account_bytes>0),
 environment_bytes bigint not null check(environment_bytes>=account_bytes)
);
insert into app_private.sync_transfer_policy values(true,536870912,10737418240);
create table app_private.sync_transfer_months (
 period date not null check(extract(day from period)=1),
 scope_id text not null check(scope_id='environment' or scope_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
 reserved_bytes bigint not null check(reserved_bytes>=0),
 requests bigint not null check(requests>=0),
 primary key(period,scope_id)
);
insert into app_private.api_rate_rules values('sync-read',3600,1000,10000),('sync-write',3600,1000,10000);

create function app_private.consume_sync_transfer(a uuid,result jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare policy app_private.sync_transfer_policy; p date:=date_trunc('month',now() at time zone 'UTC')::date;
 bytes bigint:=octet_length(result::text)+1024; total bigint;
begin
 if result is null or octet_length(result::text)>1048576 then raise exception 'sync_page_too_large'; end if;
 select * into strict policy from app_private.sync_transfer_policy where singleton;
 insert into app_private.sync_transfer_months values(p,'environment',bytes,1)
 on conflict(period,scope_id) do update set reserved_bytes=app_private.sync_transfer_months.reserved_bytes+excluded.reserved_bytes,
  requests=app_private.sync_transfer_months.requests+1 returning reserved_bytes into total;
 if total>policy.environment_bytes then raise exception 'sync_environment_transfer_limit'; end if;
 insert into app_private.sync_transfer_months values(p,a::text,bytes,1)
 on conflict(period,scope_id) do update set reserved_bytes=app_private.sync_transfer_months.reserved_bytes+excluded.reserved_bytes,
  requests=app_private.sync_transfer_months.requests+1 returning reserved_bytes into total;
 if total>policy.account_bytes then raise exception 'sync_account_transfer_limit'; end if;
end $$;

-- Keep the proven epoch, replay and cursor-lock implementation behind a wrapper.
-- The moved implementation is no longer client-callable.
alter function public.v1_append_event(uuid,uuid,integer,integer,bytea,bytea) set schema app_private;
create function public.v1_append_event(p_device_id uuid,p_id uuid,p_epoch integer,p_format integer,p_ciphertext bytea,p_management_token bytea)
returns bigint language plpgsql security definer set search_path = '' as $$
declare a uuid:=app_private.require_actor();
begin
 perform public.worker_consume_request(a,'sync-write');
 return app_private.v1_append_event(p_device_id,p_id,p_epoch,p_format,p_ciphertext,p_management_token);
end $$;

create function app_private.sync_event_page(a uuid,p_after bigint,p_limit integer) returns jsonb
language plpgsql stable security definer set search_path = '' set bytea_output = 'hex' as $$
declare result jsonb;
begin
 if p_after is null or p_after<0 or p_limit is null or p_limit not between 1 and 200 then raise exception 'invalid_cursor_page'; end if;
 -- Payload hex doubles the ciphertext length. 512 bytes/row bounds the fixed
 -- fields; another 512 bytes bounds the page wrapper. Even a maximum-size event
 -- fits alone. Rows and has_more are derived from this one MVCC snapshot.
 with candidates as materialized (
  select id,device_id,cursor,epoch,format,ciphertext,ciphertext_sha256 from app_private.sync_events
   where account_id=a and cursor>p_after order by cursor limit p_limit
 ), sized as (
  select *,sum(2*octet_length(ciphertext)+512) over(order by cursor) as response_bytes from candidates
 ), selected as materialized (
  select id,device_id,cursor,epoch,format,ciphertext,ciphertext_sha256 from sized where response_bytes<=1048064
 ), page as (
  select coalesce(jsonb_agg(to_jsonb(s) order by cursor),'[]'::jsonb) as events,coalesce(max(cursor),p_after) as next_cursor from selected s
 ) select jsonb_build_object('events',page.events,'next_cursor',page.next_cursor,'has_more',exists(
  select 1 from app_private.sync_events where account_id=a and cursor>page.next_cursor
 )) into result from page;
 return result;
end $$;

create function public.v2_pull_events(p_after bigint,p_limit integer default 200) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform public.worker_consume_request(a,'sync-read');
 result:=app_private.sync_event_page(a,p_after,p_limit);
 perform app_private.consume_sync_transfer(a,result);
 return result;
end $$;
create or replace function public.v1_pull_events(p_after bigint,p_limit integer default 200) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare a uuid:=app_private.require_actor(); page jsonb; result jsonb;
begin
 perform public.worker_consume_request(a,'sync-read');
 page:=app_private.sync_event_page(a,p_after,p_limit);
 -- Never let a legacy reader interpret byte truncation as complete catch-up.
 if (page->>'has_more')::boolean and jsonb_array_length(page->'events')<p_limit then raise exception 'sync_page_too_large'; end if;
 result:=page->'events'; perform app_private.consume_sync_transfer(a,result);
 return result;
end $$;

create function public.v1_sync_usage() returns jsonb language plpgsql security definer set search_path = '' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 perform public.worker_consume_request(a,'sync-read');
 select jsonb_build_object('ciphertext_bytes',coalesce(s.ciphertext_bytes,0),'events',coalesce(s.event_count,0),
  'storage_limit_bytes',p.account_bytes,'event_limit',p.account_events,
  'transfer_bytes',coalesce(t.reserved_bytes,0),'transfer_limit_bytes',q.account_bytes,
  'transfer_period',date_trunc('month',now() at time zone 'UTC')::date)
 into result from app_private.sync_storage_policy p cross join app_private.sync_transfer_policy q
 left join app_private.sync_account_storage s on s.account_id=a
 left join app_private.sync_transfer_months t on t.scope_id=a::text and t.period=date_trunc('month',now() at time zone 'UTC')::date;
 return result;
end $$;

alter function public.v1_admin_overview() set schema app_private;
create function public.v1_admin_overview() returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
 result:=app_private.v1_admin_overview(); -- Existing owner-role and MFA gate.
 return result||jsonb_build_object(
  'sync_storage',(select to_jsonb(s)||to_jsonb(p) from app_private.sync_environment_storage s cross join app_private.sync_storage_policy p),
  'sync_transfers',jsonb_build_object('period',date_trunc('month',now() at time zone 'UTC')::date,
   'policy',(select to_jsonb(p) from app_private.sync_transfer_policy p),
   'months',coalesce((select jsonb_agg(to_jsonb(m) order by period desc) from app_private.sync_transfer_months m
    where scope_id='environment' and period>=(date_trunc('month',now() at time zone 'UTC')-interval '2 months')::date),'[]'::jsonb)));
end $$;

create function public.worker_prune_sync_usage() returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
 delete from app_private.sync_transfer_months where period<(date_trunc('month',now() at time zone 'UTC')-interval '2 months')::date;
 get diagnostics n = row_count; return n;
end $$;

alter table app_private.sync_storage_policy enable row level security;
alter table app_private.sync_environment_storage enable row level security;
alter table app_private.sync_account_storage enable row level security;
alter table app_private.sync_transfer_policy enable row level security;
alter table app_private.sync_transfer_months enable row level security;
revoke all on all functions in schema app_private from public,anon,authenticated;
revoke all on function public.v1_append_event(uuid,uuid,integer,integer,bytea,bytea),public.v2_pull_events(bigint,integer),
 public.v1_pull_events(bigint,integer),public.v1_sync_usage(),public.v1_admin_overview(),public.worker_prune_sync_usage() from public,anon,authenticated;
grant execute on function public.v1_append_event(uuid,uuid,integer,integer,bytea,bytea),public.v2_pull_events(bigint,integer),
 public.v1_pull_events(bigint,integer),public.v1_sync_usage(),public.v1_admin_overview() to authenticated;
grant execute on function public.worker_prune_sync_usage() to service_role;
notify pgrst, 'reload schema';
commit;
