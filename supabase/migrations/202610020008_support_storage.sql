-- Additive rollout: existing support clients remain compatible. No row backfill.
-- Pending uploads reserve capacity until their object deletion is confirmed.
begin;
revoke create on schema public from public, anon, authenticated;

create table app_private.support_storage_limits (
 singleton boolean primary key default true check(singleton),
 environment_bytes bigint not null check(environment_bytes between 5242880 and 536870912),
 account_bytes bigint not null check(account_bytes between 5242880 and 52428800)
);
insert into app_private.support_storage_limits values(true,536870912,52428800);

create table app_private.attachment_uploads (
 id uuid primary key,
 report_id uuid not null,
 account_id uuid not null,
 object_id uuid not null unique references app_private.stored_objects(id),
 expires_at timestamptz not null default now()+interval '24 hours',
 created_at timestamptz not null default now(),
 foreign key(report_id,account_id) references app_private.support_reports(id,account_id)
);
create index attachment_upload_report on app_private.attachment_uploads(report_id);
create index support_object_capacity on app_private.stored_objects(owner_id,state) where bucket='support';

create table app_private.api_rate_rules (
 route text primary key,
 window_seconds integer not null check(window_seconds between 10 and 3600),
 account_limit integer not null check(account_limit between 1 and 1000),
 environment_limit integer not null check(environment_limit between 1 and 10000)
);
insert into app_private.api_rate_rules values('support-upload',3600,30,300),('support-download',3600,300,3000);
create table app_private.api_rate_windows (
 route text not null references app_private.api_rate_rules(route),
 scope_id text not null,
 window_start timestamptz not null,
 used integer not null check(used>=0),
 primary key(route,scope_id,window_start)
);

create function public.worker_consume_request(p_account_id uuid,p_route text) returns void
language plpgsql security definer set search_path = '' as $$
declare r app_private.api_rate_rules; w timestamptz; n integer;
begin
 if not exists(select 1 from app_private.accounts where id=p_account_id and closed_at is null) then raise exception 'account_unavailable' using errcode='42501'; end if;
 select * into r from app_private.api_rate_rules where route=p_route;
 if not found then raise exception 'route_unavailable'; end if;
 w:=to_timestamp(floor(extract(epoch from now())/r.window_seconds)*r.window_seconds);
 -- Always acquire environment before account. Rejected calls roll back both.
 insert into app_private.api_rate_windows values(p_route,'environment',w,1)
 on conflict(route,scope_id,window_start) do update set used=app_private.api_rate_windows.used+1 returning used into n;
 if n>r.environment_limit then raise exception 'request_rate_limit'; end if;
 insert into app_private.api_rate_windows values(p_route,p_account_id::text,w,1)
 on conflict(route,scope_id,window_start) do update set used=app_private.api_rate_windows.used+1 returning used into n;
 if n>r.account_limit then raise exception 'request_rate_limit'; end if;
end $$;

create function public.worker_reserve_attachment(p_account_id uuid,p_report_id uuid,p_id uuid,p_sha256 bytea,p_byte_count bigint,p_media_type text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare limits app_private.support_storage_limits; u app_private.attachment_uploads; o app_private.stored_objects;
begin
 select * into limits from app_private.support_storage_limits where singleton for update;
 perform 1 from app_private.accounts where id=p_account_id and closed_at is null for update;
 if not found then raise exception 'account_unavailable' using errcode='42501'; end if;
 perform 1 from app_private.support_reports where id=p_report_id and account_id=p_account_id for update;
 if not found then raise exception 'report_unavailable' using errcode='42501'; end if;
 if p_id is null or p_sha256 is null or octet_length(p_sha256)<>32 or p_byte_count is null or p_byte_count not between 1 and 5242880
   or p_media_type is null or p_media_type not in ('image/png','image/jpeg') then raise exception 'invalid_attachment'; end if;
 select * into u from app_private.attachment_uploads where id=p_id;
 if found then
  select * into o from app_private.stored_objects where id=u.object_id;
  if u.account_id is distinct from p_account_id or u.report_id is distinct from p_report_id
    or o.sha256 is distinct from p_sha256 or o.byte_count is distinct from p_byte_count or o.media_type is distinct from p_media_type then
   raise exception 'attachment_id_conflict';
  end if;
  if o.state in ('deleting','deleted') or (o.state='pending' and u.expires_at<=now()) then raise exception 'attachment_expired'; end if;
  return jsonb_build_object('id',u.id,'object_id',o.id,'bucket',o.bucket,'path',o.path,'state',o.state,'byte_count',o.byte_count,'media_type',o.media_type);
 end if;
 if (select count(*) from app_private.attachment_uploads a join app_private.stored_objects s on s.id=a.object_id
     where a.report_id=p_report_id and s.state<>'deleted')>=5 then raise exception 'attachment_count_limit'; end if;
 if coalesce((select sum(byte_count) from app_private.stored_objects where bucket='support' and state<>'deleted'),0)+p_byte_count>limits.environment_bytes
   or coalesce((select sum(byte_count) from app_private.stored_objects where bucket='support' and owner_id=p_account_id and state<>'deleted'),0)+p_byte_count>limits.account_bytes then
  raise exception 'attachment_storage_limit';
 end if;
 insert into app_private.stored_objects(id,bucket,path,owner_id,sha256,byte_count,media_type)
 values(p_id,'support',p_account_id::text||'/'||p_id::text||case when p_media_type='image/png' then '.png' else '.jpg' end,p_account_id,p_sha256,p_byte_count,p_media_type) returning * into o;
 insert into app_private.attachment_uploads(id,report_id,account_id,object_id) values(p_id,p_report_id,p_account_id,o.id);
 return jsonb_build_object('id',p_id,'object_id',o.id,'bucket',o.bucket,'path',o.path,'state',o.state,'byte_count',o.byte_count,'media_type',o.media_type);
end $$;

create function public.worker_publish_attachment(p_account_id uuid,p_id uuid,p_verified_sha256 bytea,p_verified_bytes bigint) returns uuid
language plpgsql security definer set search_path = '' as $$
declare u app_private.attachment_uploads; o app_private.stored_objects;
begin
 select * into u from app_private.attachment_uploads where id=p_id and account_id=p_account_id;
 if not found then raise exception 'attachment_unavailable' using errcode='42501'; end if;
 perform 1 from app_private.support_reports where id=u.report_id and account_id=p_account_id for update;
 if not exists(select 1 from app_private.accounts where id=p_account_id and closed_at is null) then raise exception 'account_unavailable'; end if;
 select * into o from app_private.stored_objects where id=u.object_id for update;
 if o.sha256 is distinct from p_verified_sha256 or o.byte_count is distinct from p_verified_bytes then raise exception 'attachment_verification_failed'; end if;
 if o.state='verified' and exists(select 1 from app_private.support_attachments where id=p_id and object_id=o.id) then return p_id; end if;
 if o.state<>'pending' or u.expires_at<=now() then raise exception 'attachment_expired'; end if;
 update app_private.stored_objects set state='verified',verified_at=now() where id=o.id;
 insert into app_private.support_attachments(id,report_id,account_id,object_id) values(p_id,u.report_id,p_account_id,o.id);
 update app_private.support_reports set updated_at=now() where id=u.report_id;
 return p_id;
end $$;

create function public.v1_report_attachment(p_id uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 select jsonb_build_object('id',s.id,'bucket',o.bucket,'path',o.path,'byte_count',o.byte_count,'media_type',o.media_type,'sha256',o.sha256)
 into result from app_private.support_attachments s join app_private.stored_objects o on o.id=s.object_id
 join app_private.support_reports r on r.id=s.report_id and r.account_id=s.account_id
 where s.id=p_id and o.state='verified' and (r.account_id=a or app_private.is_operator());
 if result is null then raise exception 'attachment_unavailable' using errcode='42501'; end if;
 return result;
end $$;

create function public.worker_claim_orphan_attachments(p_limit integer default 20) returns jsonb language plpgsql security definer set search_path = '' as $$
declare result jsonb;
begin
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'invalid_limit'; end if;
 with candidates as (
  select o.id from app_private.stored_objects o join app_private.attachment_uploads u on u.object_id=o.id
  -- The grace exceeds Edge's maximum invocation lifetime, so an upload that
  -- started before expiry cannot finish after its object has been removed.
  where o.bucket='support' and o.state in ('pending','deleting') and u.expires_at<=now()-interval '10 minutes'
   and not exists(select 1 from app_private.support_attachments a where a.object_id=o.id)
  order by u.expires_at,o.id for update of o skip locked limit p_limit
 ), changed as (
  update app_private.stored_objects o set state='deleting' from candidates c where o.id=c.id
  returning o.id,o.bucket,o.path
 ) select coalesce(jsonb_agg(to_jsonb(changed)),'[]'::jsonb) into result from changed;
 -- Small, bounded time series; stale counters have no authorization meaning.
 delete from app_private.api_rate_windows where window_start<now()-interval '2 days';
 return result;
end $$;
create function public.worker_confirm_attachment_deleted(p_object_id uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
 perform 1 from app_private.support_storage_limits where singleton for update;
 if exists(select 1 from app_private.support_attachments where object_id=p_object_id) then raise exception 'attachment_in_use'; end if;
 update app_private.stored_objects set state='deleted' where id=p_object_id and bucket='support' and state='deleting';
 if not found and not exists(select 1 from app_private.stored_objects where id=p_object_id and bucket='support' and state='deleted') then raise exception 'attachment_not_deleting'; end if;
end $$;

create function public.v2_reports(p_before_created_at timestamptz default null,p_before_id uuid default null,p_limit integer default 50) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 if p_limit is null or p_limit not between 1 and 100 or (p_before_created_at is null)<>(p_before_id is null) then raise exception 'invalid_page'; end if;
 select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc,r.id desc),'[]'::jsonb) into result from (
  select * from app_private.support_reports where (account_id=a or app_private.is_operator())
   and (p_before_created_at is null or (created_at,id)<(p_before_created_at,p_before_id))
  order by created_at desc,id desc limit p_limit
 ) r;
 return result;
end $$;

create or replace function public.v1_reply_to_report(p_id uuid,p_report_id uuid,p_body text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare a uuid:=app_private.require_actor(); m app_private.support_messages; operator boolean:=app_private.is_operator();
begin
 -- Account lock makes the hourly limit effective across concurrent reports.
 perform 1 from app_private.accounts where id=a for update;
 perform 1 from app_private.support_reports where id=p_report_id and (account_id=a or operator) for update;
 if not found then raise exception 'report_unavailable' using errcode='42501'; end if;
 select * into m from app_private.support_messages where id=p_id;
 if found then
  if m.report_id is distinct from p_report_id or m.author_id is distinct from a or m.body is distinct from p_body then raise exception 'message_id_conflict'; end if;
  return p_id;
 end if;
 if (select count(*) from app_private.support_messages where author_id=a and created_at>now()-interval '1 hour')>=100 then raise exception 'reply_rate_limit'; end if;
 insert into app_private.support_messages(id,report_id,author_id,body,is_operator) values(p_id,p_report_id,a,p_body,operator);
 update app_private.support_reports set updated_at=now() where id=p_report_id;
 return p_id;
end $$;

do $$ declare t text; f record; begin
 foreach t in array array['support_storage_limits','attachment_uploads','api_rate_rules','api_rate_windows'] loop
  execute format('alter table app_private.%I enable row level security',t);
 end loop;
 for f in select p.oid::regprocedure as signature,p.proname from pg_proc p join pg_namespace n on p.pronamespace=n.oid
  where n.nspname='public' and p.proname in ('worker_consume_request','worker_reserve_attachment','worker_publish_attachment','worker_claim_orphan_attachments','worker_confirm_attachment_deleted','v1_report_attachment','v2_reports') loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  execute format('grant execute on function %s to %I',f.signature,case when f.proname like 'worker_%' then 'service_role' else 'authenticated' end);
 end loop;
end $$;
commit;
