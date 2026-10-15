-- 067: A private episode from a device source reaches publishing without a Mathpix source row; the asset plan read
-- that row strictly (066's live proof failed at "publishing" with database_error). The document is only needed for a
-- shared episode's objects. docs/architecture/PAPER_PODCASTS.md "Episodes from the paper on this device".
begin;
create or replace function public.worker_podcast_asset_plan(p_job uuid,p_claim uuid,p_generation bigint,p_upload_id uuid,p_objects jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.podcast_jobs; k app_private.podcast_episode_keys; spec jsonb; u app_private.podcast_asset_uploads; row jsonb; o app_private.stored_objects;
 digest bytea; prefix text; release_key text; role text; name text; total bigint:=0; doc uuid; media text; limit_bytes bigint;
begin
 j:=app_private.podcast_fenced(p_job,p_claim,p_generation);
 if j.state<>'publishing' then raise exception 'invalid_podcast_stage'; end if;
 if p_upload_id is null or p_objects is null or jsonb_typeof(p_objects)<>'array' or jsonb_array_length(p_objects)<>3 or octet_length(p_objects::text)>8192
 then raise exception 'invalid_asset_plan'; end if;
 digest:=sha256(convert_to(jsonb_build_array(p_job,p_claim,p_generation,p_objects)::text,'UTF8'));
 select * into u from app_private.podcast_asset_uploads where id=p_upload_id;
 if found then
  if u.request_sha256<>digest or u.job_id<>j.id then raise exception 'operation_id_conflict'; end if;
  return jsonb_build_object('upload_id',u.id,'objects',(select jsonb_agg(jsonb_build_object('role',m.role,'id',s.id,'path',s.path,'verified',s.state='verified') order by m.role)
   from app_private.podcast_asset_upload_members m join app_private.stored_objects s on s.id=m.object_id where m.upload_id=u.id));
 end if;
 select * into strict k from app_private.podcast_episode_keys where id=j.episode_id;
 spec:=app_private.podcast_job_spec(j);
 -- A shared episode's objects carry its document; a private one (a Mathpix source or, since 066, a device source) carries the owner.
 select document_id into doc from app_private.podcast_sources where episode_id=j.episode_id and ordinal=0;
 if not found and k.scope='shared' then raise exception 'source_unavailable'; end if;
 release_key:=split_part(regexp_replace(p_objects->0->>'path','^(shared/|private/[0-9a-f-]{36}/)',''),'/',1);
 if release_key !~ '^[0-9a-f]{64}$' then raise exception 'invalid_asset_plan'; end if;
 prefix:=case when k.scope='shared' then 'shared/' else 'private/'||k.owner_id::text||'/' end||release_key||'/';
 perform 1 from app_private.paper_storage_capacity where singleton for update;
 if (select reconciliation_id is not null from app_private.paper_asset_policy where singleton) then raise exception 'asset_inventory_reconciling'; end if;
 insert into app_private.podcast_asset_uploads(id,job_id,claim_id,claim_generation,request_sha256,release_key)
  values(p_upload_id,j.id,p_claim,p_generation,digest,release_key);
 for row in select value from jsonb_array_elements(p_objects) loop
  role:=row->>'role';
  name:=case role when 'audio' then 'audio.m4a' when 'transcript' then 'transcript.json' when 'manifest' then 'manifest.json' end;
  media:=case role when 'audio' then 'audio/mp4' else 'application/json' end;
  limit_bytes:=case role when 'audio' then (spec->'storage'->>'audio_bytes')::bigint when 'transcript' then (spec->'storage'->>'transcript_bytes')::bigint
   else (spec->'storage'->>'manifest_bytes')::bigint end;
  if name is null or row->>'path' is distinct from prefix||name or (row->>'sha256') !~ '^[0-9a-f]{64}$'
   or coalesce((row->>'bytes')::bigint,0) not between 1 and limit_bytes or row->>'media_type' is distinct from media then raise exception 'invalid_asset_plan'; end if;
  total:=total+(row->>'bytes')::bigint;
  select * into o from app_private.stored_objects where path=prefix||name for update;
  if not found then
   insert into app_private.stored_objects(bucket,path,document_id,owner_id,sha256,byte_count,media_type)
    values('podcast-assets',prefix||name,case when k.scope='shared' then doc end,k.owner_id,decode(row->>'sha256','hex'),(row->>'bytes')::bigint,media) returning * into o;
  elsif o.bucket<>'podcast-assets' or o.sha256<>decode(row->>'sha256','hex') or o.byte_count<>(row->>'bytes')::bigint or o.media_type<>media
   or o.owner_id is distinct from k.owner_id or o.state not in ('pending','verified') then raise exception 'asset_identity_conflict'; end if;
  insert into app_private.podcast_asset_upload_members(upload_id,role,object_id) values(p_upload_id,role,o.id);
 end loop;
 if total>(spec->'storage'->>'bytes')::bigint then raise exception 'invalid_asset_plan'; end if;
 delete from app_private.podcast_asset_holds where job_id=j.id;
 begin perform app_private.paper_asset_check_capacity(k.owner_id);
 exception when raise_exception then
  if sqlerrm in ('paper_storage_capacity','paper_owner_storage_capacity') then raise exception 'storage_full'; end if; raise;
 end;
 perform app_private.podcast_event(j.id,'planned',jsonb_build_object('upload_id',p_upload_id,'bytes',total));
 return jsonb_build_object('upload_id',p_upload_id,'objects',(select jsonb_agg(jsonb_build_object('role',m.role,'id',s.id,'path',s.path,'verified',s.state='verified') order by m.role)
  from app_private.podcast_asset_upload_members m join app_private.stored_objects s on s.id=m.object_id where m.upload_id=p_upload_id));
end $$;

notify pgrst,'reload schema';
commit;
