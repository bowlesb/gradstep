begin;
create table app_private.key_transitions (
 account_id uuid not null references app_private.keyrings(account_id),
 id uuid not null,
 from_epoch integer not null,
 to_epoch integer not null,
 request_sha256 bytea not null check(octet_length(request_sha256)=32),
 created_at timestamptz not null default now(),
 primary key(account_id,id),
 check(to_epoch=from_epoch+1)
);
alter table app_private.key_transitions enable row level security;
create trigger key_transitions_immutable before update or delete on app_private.key_transitions for each row execute function app_private.immutable_record();
create function public.v1_devices() returns jsonb language sql stable security definer set search_path = '' as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'public_key',public_key,'challenge',challenge,'created_at',created_at,'revoked_at',revoked_at) order by created_at,id),'[]'::jsonb)
 from app_private.devices where account_id=app_private.require_actor()
$$;
create function public.v1_rotate_keys(p_id uuid,p_expected_epoch integer,p_management_token bytea,p_new_management_token bytea,
 p_recovery_package bytea,p_revoked_device_ids uuid[],p_device_envelopes jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare a uuid:=app_private.require_actor(); k app_private.keyrings; t app_private.key_transitions;
 request_digest bytea; item jsonb; recipient uuid; retained integer;
begin
 if p_new_management_token is null or octet_length(p_new_management_token)<>32
  or p_new_management_token=p_management_token or p_revoked_device_ids is null
  or array_position(p_revoked_device_ids,null) is not null
  or p_device_envelopes is null or jsonb_typeof(p_device_envelopes)<>'array'
  or p_recovery_package is null then raise exception 'invalid_key_transition'; end if;
 request_digest:=sha256(convert_to(jsonb_build_object('from',p_expected_epoch,'revoked',p_revoked_device_ids,'envelopes',p_device_envelopes)::text,'UTF8')
  ||p_recovery_package||sha256(p_new_management_token));
 select * into strict k from app_private.keyrings where account_id=a for update;
 select * into t from app_private.key_transitions where account_id=a and id=p_id;
 if found then
  if t.request_sha256 is distinct from request_digest or not coalesce(app_private.verify_management(a,p_new_management_token),false) then raise exception 'key_transition_conflict'; end if;
  return t.to_epoch;
 end if;
 if k.epoch is distinct from p_expected_epoch or not coalesce(app_private.verify_management(a,p_management_token),false) then raise exception 'key_authority_required' using errcode='42501'; end if;
 if cardinality(p_revoked_device_ids)<>(select count(distinct x) from unnest(p_revoked_device_ids) x)
  or cardinality(p_revoked_device_ids)<>(select count(*) from app_private.devices where account_id=a and id=any(p_revoked_device_ids) and revoked_at is null) then raise exception 'invalid_revoked_devices'; end if;
 select count(*) into retained from app_private.devices where account_id=a and revoked_at is null and not(id=any(p_revoked_device_ids));
 if retained<1 or retained>50 or jsonb_array_length(p_device_envelopes)<>retained then raise exception 'remaining_device_envelopes_required'; end if;
 for item in select value from jsonb_array_elements(p_device_envelopes) loop
  recipient:=(item->>'device_id')::uuid;
  if not exists(select 1 from app_private.devices where account_id=a and id=recipient and revoked_at is null and not(id=any(p_revoked_device_ids))) then raise exception 'invalid_envelope_recipient'; end if;
  insert into app_private.device_envelopes(account_id,device_id,epoch,envelope)
   values(a,recipient,k.epoch+1,(item->>'envelope')::bytea);
 end loop;
 update app_private.devices set revoked_at=now() where account_id=a and id=any(p_revoked_device_ids);
 update app_private.keyrings set epoch=k.epoch+1,recovery_package=p_recovery_package,
  management_verifier=sha256(convert_to('science-reader/management/v1/'||a::text||'/','UTF8')||p_new_management_token) where account_id=a;
 insert into app_private.key_transitions(account_id,id,from_epoch,to_epoch,request_sha256) values(a,p_id,k.epoch,k.epoch+1,request_digest);
 return k.epoch+1;
end $$;
revoke all on function public.v1_devices(),public.v1_rotate_keys(uuid,integer,bytea,bytea,bytea,uuid[],jsonb) from public,anon;
grant execute on function public.v1_devices(),public.v1_rotate_keys(uuid,integer,bytea,bytea,bytea,uuid[],jsonb) to authenticated;
commit;
