-- Releases chat credit holds whose Edge invocation ended without settling
-- (instance terminated mid-stream). The customer is not charged; the hold's
-- provider ceiling is recorded as spent so the platform budget stays
-- conservative. OCR holds are never swept here: they have explicit exits
-- tied to their attempts (migration 014).
begin;

create function public.worker_expire_stale_chat_operations(p_older_than_minutes integer default 30) returns integer
language plpgsql security definer set search_path='' as $$
declare op record; n integer:=0;
begin
 if p_older_than_minutes is null or p_older_than_minutes<10 then raise exception 'invalid_age'; end if;
 for op in select account_id,id,spend_ceiling_microusd from app_private.metered_operations
  where kind='chat' and state<>'settled' and created_at<now()-make_interval(mins=>p_older_than_minutes)
  order by created_at limit 50 loop
  begin
   perform public.worker_settle_operation(op.account_id,op.id,0,op.spend_ceiling_microusd);
   n:=n+1;
  exception when others then null;
  end;
 end loop;
 return n;
end $$;
revoke all on function public.worker_expire_stale_chat_operations(integer) from public,anon,authenticated;
grant execute on function public.worker_expire_stale_chat_operations(integer) to service_role;

-- Library arXiv search (discover Edge function) rate window.
insert into app_private.api_rate_rules values('discover',3600,240,3000) on conflict(route) do nothing;
commit;
