-- Follow-up suggestion quotes (docs/architecture/CHAT.md#agent-v2-2026-10-14-numbered-context-grounded-citations-follow-ups).
-- Additive: a chat quote may now freeze the follow-up suggestion request's ceiling beside the title's, so what a
-- hold was sized for stays readable. Quotes without the three keys (every earlier client and function build, and
-- answers that do not ask for suggestions) stay valid and record nulls. No row is changed or deleted.
begin;
set local lock_timeout='15s';

alter table app_private.chat_quotes
 add column follow_ups_model text check(follow_ups_model ~ '^[a-z0-9.-]{1,64}$'),
 add column follow_ups_max_tokens integer check(follow_ups_max_tokens between 1 and 1000),
 add column follow_ups_ceiling_microusd bigint check(follow_ups_ceiling_microusd between 0 and 30000000),
 add constraint chat_quotes_follow_ups_complete check((follow_ups_model is null)=(follow_ups_max_tokens is null)
  and (follow_ups_model is null)=(follow_ups_ceiling_microusd is null));

-- As migration 047, plus the optional follow-up group: either all three keys or none (then null).
create or replace function public.worker_reserve_chat(p_account_id uuid,p_id uuid,p_request_sha256 bytea,p_rate_version text,
 p_credits bigint,p_microusd bigint,p_quote jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; existing app_private.chat_quotes; q app_private.chat_quotes; field record; keys text[];
begin
 if p_quote is null or jsonb_typeof(p_quote)<>'object' or octet_length(p_quote::text)>2048 then raise exception 'invalid_reservation'; end if;
 keys:=(select array_agg(k order by k) from jsonb_object_keys(p_quote) k);
 if keys is distinct from array['effort','input_estimate_tokens','length','max_output_tokens','max_searches','model','profile',
    'profile_version','tariff','title_ceiling_microusd','title_max_tokens','title_model']
  and keys is distinct from array['effort','follow_ups_ceiling_microusd','follow_ups_max_tokens','follow_ups_model','input_estimate_tokens',
    'length','max_output_tokens','max_searches','model','profile','profile_version','tariff','title_ceiling_microusd','title_max_tokens','title_model']
 then raise exception 'invalid_reservation'; end if;
 for field in select * from (values ('profile_version','string',false),('profile','string',false),('model','string',false),
   ('effort','string',false),('length','string',false),('tariff','string',false),('max_output_tokens','number',false),
   ('input_estimate_tokens','number',false),('max_searches','number',false),('title_model','string',true),
   ('title_max_tokens','number',true),('title_ceiling_microusd','number',true),('follow_ups_model','string',true),
   ('follow_ups_max_tokens','number',true),('follow_ups_ceiling_microusd','number',true)) f(name,kind,nullable) loop
  if not (p_quote ? field.name) then continue; end if;
  if not (jsonb_typeof(p_quote->field.name)=field.kind or (field.nullable and jsonb_typeof(p_quote->field.name)='null'))
   or (field.kind='number' and jsonb_typeof(p_quote->field.name)='number' and (p_quote->>field.name) !~ '^[0-9]{1,12}$')
  then raise exception 'invalid_reservation'; end if;
 end loop;
 q.account_id:=p_account_id; q.operation_id:=p_id; q.profile_version:=p_quote->>'profile_version'; q.profile:=p_quote->>'profile';
 q.model:=p_quote->>'model'; q.effort:=p_quote->>'effort'; q.length:=p_quote->>'length'; q.rate_version:=p_rate_version;
 q.tariff:=p_quote->>'tariff'; q.max_output_tokens:=(p_quote->>'max_output_tokens')::integer;
 q.input_estimate_tokens:=(p_quote->>'input_estimate_tokens')::bigint; q.max_searches:=(p_quote->>'max_searches')::integer;
 q.title_model:=p_quote->>'title_model'; q.title_max_tokens:=(p_quote->>'title_max_tokens')::integer;
 q.title_ceiling_microusd:=(p_quote->>'title_ceiling_microusd')::bigint;
 q.follow_ups_model:=p_quote->>'follow_ups_model'; q.follow_ups_max_tokens:=(p_quote->>'follow_ups_max_tokens')::integer;
 q.follow_ups_ceiling_microusd:=(p_quote->>'follow_ups_ceiling_microusd')::bigint;
 q.credit_ceiling:=p_credits; q.spend_ceiling_microusd:=p_microusd;
 result:=public.worker_reserve_operation(p_account_id,p_id,'chat',p_request_sha256,p_rate_version,p_credits,p_microusd);
 select * into existing from app_private.chat_quotes where account_id=p_account_id and operation_id=p_id;
 if (result->>'replayed')::boolean then
  if found and (existing.profile_version,existing.profile,existing.model,existing.effort,existing.length,existing.rate_version,existing.tariff,
    existing.max_output_tokens,existing.input_estimate_tokens,existing.max_searches,existing.title_model,existing.title_max_tokens,
    existing.title_ceiling_microusd,existing.follow_ups_model,existing.follow_ups_max_tokens,existing.follow_ups_ceiling_microusd)
   is distinct from (q.profile_version,q.profile,q.model,q.effort,q.length,q.rate_version,q.tariff,
    q.max_output_tokens,q.input_estimate_tokens,q.max_searches,q.title_model,q.title_max_tokens,q.title_ceiling_microusd,
    q.follow_ups_model,q.follow_ups_max_tokens,q.follow_ups_ceiling_microusd)
  then raise exception 'operation_id_conflict'; end if;
  return result;
 end if;
 begin
  insert into app_private.chat_quotes(account_id,operation_id,profile_version,profile,model,effort,length,rate_version,tariff,
   max_output_tokens,input_estimate_tokens,max_searches,title_model,title_max_tokens,title_ceiling_microusd,
   follow_ups_model,follow_ups_max_tokens,follow_ups_ceiling_microusd,credit_ceiling,spend_ceiling_microusd)
  values(q.account_id,q.operation_id,q.profile_version,q.profile,q.model,q.effort,q.length,q.rate_version,q.tariff,
   q.max_output_tokens,q.input_estimate_tokens,q.max_searches,q.title_model,q.title_max_tokens,q.title_ceiling_microusd,
   q.follow_ups_model,q.follow_ups_max_tokens,q.follow_ups_ceiling_microusd,q.credit_ceiling,q.spend_ceiling_microusd);
 exception when check_violation or not_null_violation or numeric_value_out_of_range then
  -- Raising here aborts the whole call, the new hold included.
  raise exception 'invalid_reservation';
 end;
 return result;
end $$;
revoke all on function public.worker_reserve_chat(uuid,uuid,bytea,text,bigint,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.worker_reserve_chat(uuid,uuid,bytea,text,bigint,bigint,jsonb) to service_role;
notify pgrst,'reload schema';
commit;
