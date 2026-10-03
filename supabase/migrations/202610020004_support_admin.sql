begin;
create table app_private.support_reports (
 id uuid primary key,
 account_id uuid not null references app_private.accounts(id),
 title text not null check(length(title) between 1 and 160),
 note text not null check(length(note) between 1 and 10000),
 app_version text not null check(length(app_version) between 1 and 40),
 build text not null check(length(build) between 1 and 40),
 os_version text not null check(length(os_version)<=100),
 screen text not null check(length(screen)<=100),
 status text not null default 'open' check(status in ('open','investigating','ready_to_retest','verified')),
 fixed_build text check(length(fixed_build)<=40),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(id,account_id)
);
create index support_report_queue on app_private.support_reports(status,updated_at desc);
create table app_private.support_messages (
 id uuid primary key,
 report_id uuid not null references app_private.support_reports(id),
 author_id uuid not null references app_private.accounts(id),
 body text not null check(length(body) between 1 and 10000),
 is_operator boolean not null,
 created_at timestamptz not null default now()
);
create index support_message_thread on app_private.support_messages(report_id,created_at,id);
create table app_private.support_attachments (
 id uuid primary key,
 report_id uuid not null,
 account_id uuid not null,
 object_id uuid not null unique references app_private.stored_objects(id),
 created_at timestamptz not null default now(),
 foreign key(report_id,account_id) references app_private.support_reports(id,account_id)
);
create table app_private.support_status_events (
 id uuid primary key,
 report_id uuid not null references app_private.support_reports(id),
 actor_id uuid not null references app_private.accounts(id),
 old_status text not null,
 new_status text not null,
 fixed_build text,
 created_at timestamptz not null default now()
);
create table app_private.admin_audit_events (
 id uuid primary key default gen_random_uuid(),
 actor_id uuid not null references app_private.accounts(id),
 action text not null,
 target_id text not null,
 reason text not null check(length(reason) between 3 and 1000),
 details jsonb not null default '{}',
 created_at timestamptz not null default now()
);
create trigger admin_audit_immutable before update or delete on app_private.admin_audit_events for each row execute function app_private.immutable_record();
create trigger support_status_immutable before update or delete on app_private.support_status_events for each row execute function app_private.immutable_record();

create function public.v1_create_report(p_id uuid,p_title text,p_note text,p_app_version text,p_build text,p_os_version text,p_screen text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare a uuid:=app_private.require_actor(); r app_private.support_reports;
begin
 perform 1 from app_private.accounts where id=a for update;
 select * into r from app_private.support_reports where id=p_id;
 if found then
  if r.account_id is distinct from a or r.title is distinct from p_title or r.note is distinct from p_note
    or r.app_version is distinct from p_app_version or r.build is distinct from p_build or r.os_version is distinct from p_os_version or r.screen is distinct from p_screen then
   raise exception 'report_id_conflict';
  end if;
  return p_id;
 end if;
 if (select count(*) from app_private.support_reports where account_id=a and created_at>now()-interval '1 hour')>=20 then raise exception 'report_rate_limit'; end if;
 insert into app_private.support_reports(id,account_id,title,note,app_version,build,os_version,screen)
 values(p_id,a,p_title,p_note,p_app_version,p_build,p_os_version,p_screen);
 return p_id;
end $$;
create function public.v1_reports(p_before timestamptz default now(),p_limit integer default 50) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare a uuid:=app_private.require_actor(); result jsonb;
begin
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'invalid_page'; end if;
 select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc,r.id),'[]'::jsonb) into result from (
  select * from app_private.support_reports where created_at<=p_before
   and (account_id=a or app_private.is_operator()) order by created_at desc,id limit p_limit
 ) r;
 return result;
end $$;
create function public.v1_report_thread(p_report_id uuid) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a uuid:=app_private.require_actor(); r app_private.support_reports;
begin
 select * into r from app_private.support_reports where id=p_report_id and (account_id=a or app_private.is_operator());
 if not found then raise exception 'report_unavailable' using errcode='42501'; end if;
 return jsonb_build_object('report',to_jsonb(r),
  'messages',coalesce((select jsonb_agg(to_jsonb(m) order by created_at,id) from app_private.support_messages m where report_id=r.id),'[]'::jsonb),
  'attachments',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'object_id',s.object_id)) from app_private.support_attachments s where report_id=r.id),'[]'::jsonb),
  'status_events',coalesce((select jsonb_agg(to_jsonb(s) order by created_at,id) from app_private.support_status_events s where report_id=r.id),'[]'::jsonb));
end $$;
create function public.v1_reply_to_report(p_id uuid,p_report_id uuid,p_body text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare a uuid:=app_private.require_actor(); m app_private.support_messages; operator boolean:=app_private.is_operator();
begin
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
create function public.v1_set_report_status(p_id uuid,p_report_id uuid,p_status text,p_fixed_build text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare a uuid:=app_private.require_actor(); r app_private.support_reports; e app_private.support_status_events; operator boolean:=app_private.is_operator();
begin
 select * into r from app_private.support_reports where id=p_report_id and (account_id=a or operator) for update;
 if not found then raise exception 'report_unavailable' using errcode='42501'; end if;
 if not operator and (p_status is null or p_status not in ('open','verified') or p_fixed_build is not null) then raise exception 'operator_required' using errcode='42501'; end if;
 if p_status='ready_to_retest' and (p_fixed_build is null or length(trim(p_fixed_build))=0) then raise exception 'fixed_build_required'; end if;
 select * into e from app_private.support_status_events where id=p_id;
 if found then
  if e.report_id is distinct from p_report_id or e.actor_id is distinct from a or e.new_status is distinct from p_status or e.fixed_build is distinct from p_fixed_build then raise exception 'status_id_conflict'; end if;
  return;
 end if;
 update app_private.support_reports set status=p_status,fixed_build=coalesce(p_fixed_build,fixed_build),updated_at=now() where id=p_report_id;
 insert into app_private.support_status_events(id,report_id,actor_id,old_status,new_status,fixed_build) values(p_id,p_report_id,a,r.status,p_status,p_fixed_build);
end $$;
create function public.v1_admin_overview() returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
 if not app_private.is_operator('owner') then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 return jsonb_build_object(
  'accounts',(select count(*) from app_private.accounts where closed_at is null),
  'library_items',(select count(*) from app_private.library_items where removed_at is null),
  'shared_documents',(select count(*) from app_private.documents where scope='shared_catalog'),
  'shared_documents_reused',(select count(*) from (select li.document_id from app_private.library_items li join app_private.documents d on d.id=li.document_id
    where d.scope='shared_catalog' and li.removed_at is null group by li.document_id having count(distinct li.account_id)>1) reused),
  'budgets',coalesce((select jsonb_agg(to_jsonb(b) order by period desc) from app_private.platform_budgets b),'[]'::jsonb),
  'jobs',coalesce((select jsonb_object_agg(state,n) from (select state,count(*) n from app_private.processing_jobs group by state) j),'{}'::jsonb),
  'subscriptions',coalesce((select jsonb_object_agg(state,n) from (select state,count(*) n from app_private.entitlements group by state) e),'{}'::jsonb),
  'open_reports',(select count(*) from app_private.support_reports where status<>'verified'),
  'usage',coalesce((select jsonb_agg(to_jsonb(u)) from (select provider,model,count(*) calls,sum(estimated_microusd) estimated_microusd
   from app_private.provider_usage_events where created_at>=date_trunc('month',now() at time zone 'UTC') at time zone 'UTC' group by provider,model) u),'[]'::jsonb));
end $$;
create function public.v1_admin_pause_work(p_paused boolean,p_reason text) returns void language plpgsql security definer set search_path = '' as $$
begin
 if not app_private.is_operator('owner') then raise exception 'owner_mfa_required' using errcode='42501'; end if;
 if p_paused is null then raise exception 'invalid_pause'; end if;
 update app_private.platform_budgets set work_enabled=not p_paused where period=date_trunc('month',now() at time zone 'UTC')::date;
 if not found then raise exception 'budget_not_configured'; end if;
 insert into app_private.admin_audit_events(actor_id,action,target_id,reason,details)
 values(app_private.actor(),'set_work_paused',date_trunc('month',now() at time zone 'UTC')::date::text,p_reason,jsonb_build_object('paused',p_paused));
end $$;

do $$ declare t record; f record; begin
 for t in select tablename from pg_tables where schemaname='app_private' loop
  execute format('alter table app_private.%I enable row level security',t.tablename);
 end loop;
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on p.pronamespace=n.oid
  where n.nspname='public' and (p.proname in ('v1_create_report','v1_reports','v1_report_thread','v1_reply_to_report','v1_set_report_status','v1_admin_overview','v1_admin_pause_work')) loop
  execute format('revoke all on function %s from public,anon',f.signature);
  execute format('grant execute on function %s to authenticated',f.signature);
 end loop;
end $$;
commit;
