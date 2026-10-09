-- Chat answer quotes (docs/architecture/CHAT.md#models-effort-and-length). A reader chooses a model, effort and
-- length per chat; the chat function accepts only its versioned profile table (chat-profiles-v1, in code) and holds
-- the maximum at that model's rates. This records, with the reservation and in the same transaction, what the hold
-- was sized for: the profile and its version, the model, effort and length, the output allowance (thinking included),
-- the credit rate version and provider tariff, the input estimate, the search allowance and the topic-title request.
-- It holds no prompt, answer or title text. Rows are immutable billing evidence and are kept, like the operation
-- they belong to, when an account is deleted. Additive: other reservation callers are unchanged.
begin;

create table app_private.chat_quotes (
 account_id uuid not null,
 operation_id uuid not null,
 profile_version text not null check(profile_version ~ '^[a-z0-9-]{1,64}$'),
 profile text not null check(profile ~ '^[a-z0-9_-]{1,64}$'),
 model text not null check(model ~ '^[a-z0-9.-]{1,64}$'),
 effort text not null check(effort in ('low','medium','high')),
 length text not null check(length in ('brief','standard','detailed','repair')),
 rate_version text not null check(rate_version ~ '^[a-z0-9-]{1,64}$'),
 tariff text not null check(tariff ~ '^[a-z0-9-]{1,64}$'),
 max_output_tokens integer not null check(max_output_tokens between 1 and 128000),
 input_estimate_tokens bigint not null check(input_estimate_tokens between 0 and 10000000),
 max_searches integer not null check(max_searches between 0 and 16),
 title_model text check(title_model ~ '^[a-z0-9.-]{1,64}$'),
 title_max_tokens integer check(title_max_tokens between 1 and 1000),
 title_ceiling_microusd bigint check(title_ceiling_microusd between 0 and 30000000),
 credit_ceiling bigint not null check(credit_ceiling>=0),
 spend_ceiling_microusd bigint not null check(spend_ceiling_microusd>=0),
 created_at timestamptz not null default now(),
 primary key(account_id,operation_id),
 foreign key(account_id,operation_id) references app_private.metered_operations(account_id,id),
 check((title_model is null)=(title_max_tokens is null) and (title_model is null)=(title_ceiling_microusd is null))
);
create trigger chat_quotes_immutable before update or delete on app_private.chat_quotes
 for each row execute function app_private.immutable_record();

-- worker_reserve_operation plus the quote, atomically: a quote that fails validation rolls the hold back too.
-- A replay must carry the identical quote; an operation reserved before this migration has none to compare.
create function public.worker_reserve_chat(p_account_id uuid,p_id uuid,p_request_sha256 bytea,p_rate_version text,
 p_credits bigint,p_microusd bigint,p_quote jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; existing app_private.chat_quotes; q app_private.chat_quotes; field record;
begin
 if p_quote is null or jsonb_typeof(p_quote)<>'object' or octet_length(p_quote::text)>2048
  or (select array_agg(k order by k) from jsonb_object_keys(p_quote) k)
   is distinct from array['effort','input_estimate_tokens','length','max_output_tokens','max_searches','model','profile',
    'profile_version','tariff','title_ceiling_microusd','title_max_tokens','title_model']
 then raise exception 'invalid_reservation'; end if;
 for field in select * from (values ('profile_version','string',false),('profile','string',false),('model','string',false),
   ('effort','string',false),('length','string',false),('tariff','string',false),('max_output_tokens','number',false),
   ('input_estimate_tokens','number',false),('max_searches','number',false),('title_model','string',true),
   ('title_max_tokens','number',true),('title_ceiling_microusd','number',true)) f(name,kind,nullable) loop
  if not (jsonb_typeof(p_quote->field.name)=field.kind or (field.nullable and jsonb_typeof(p_quote->field.name)='null'))
   or (field.kind='number' and jsonb_typeof(p_quote->field.name)='number' and (p_quote->>field.name) !~ '^[0-9]{1,12}$')
  then raise exception 'invalid_reservation'; end if;
 end loop;
 q.account_id:=p_account_id; q.operation_id:=p_id; q.profile_version:=p_quote->>'profile_version'; q.profile:=p_quote->>'profile';
 q.model:=p_quote->>'model'; q.effort:=p_quote->>'effort'; q.length:=p_quote->>'length'; q.rate_version:=p_rate_version;
 q.tariff:=p_quote->>'tariff'; q.max_output_tokens:=(p_quote->>'max_output_tokens')::integer;
 q.input_estimate_tokens:=(p_quote->>'input_estimate_tokens')::bigint; q.max_searches:=(p_quote->>'max_searches')::integer;
 q.title_model:=p_quote->>'title_model'; q.title_max_tokens:=(p_quote->>'title_max_tokens')::integer;
 q.title_ceiling_microusd:=(p_quote->>'title_ceiling_microusd')::bigint; q.credit_ceiling:=p_credits; q.spend_ceiling_microusd:=p_microusd;
 result:=public.worker_reserve_operation(p_account_id,p_id,'chat',p_request_sha256,p_rate_version,p_credits,p_microusd);
 select * into existing from app_private.chat_quotes where account_id=p_account_id and operation_id=p_id;
 if (result->>'replayed')::boolean then
  if found and (existing.profile_version,existing.profile,existing.model,existing.effort,existing.length,existing.rate_version,existing.tariff,
    existing.max_output_tokens,existing.input_estimate_tokens,existing.max_searches,existing.title_model,existing.title_max_tokens,
    existing.title_ceiling_microusd) is distinct from (q.profile_version,q.profile,q.model,q.effort,q.length,q.rate_version,q.tariff,
    q.max_output_tokens,q.input_estimate_tokens,q.max_searches,q.title_model,q.title_max_tokens,q.title_ceiling_microusd)
  then raise exception 'operation_id_conflict'; end if;
  return result;
 end if;
 begin
  insert into app_private.chat_quotes(account_id,operation_id,profile_version,profile,model,effort,length,rate_version,tariff,
   max_output_tokens,input_estimate_tokens,max_searches,title_model,title_max_tokens,title_ceiling_microusd,credit_ceiling,spend_ceiling_microusd)
  values(q.account_id,q.operation_id,q.profile_version,q.profile,q.model,q.effort,q.length,q.rate_version,q.tariff,
   q.max_output_tokens,q.input_estimate_tokens,q.max_searches,q.title_model,q.title_max_tokens,q.title_ceiling_microusd,q.credit_ceiling,q.spend_ceiling_microusd);
 exception when check_violation or not_null_violation or numeric_value_out_of_range then
  -- Raising here aborts the whole call, the new hold included.
  raise exception 'invalid_reservation';
 end;
 return result;
end $$;

alter table app_private.chat_quotes enable row level security;
revoke all on app_private.chat_quotes from public,anon,authenticated,service_role;
revoke all on function public.worker_reserve_chat(uuid,uuid,bytea,text,bigint,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.worker_reserve_chat(uuid,uuid,bytea,text,bigint,bigint,jsonb) to service_role;

notify pgrst,'reload schema';
commit;
