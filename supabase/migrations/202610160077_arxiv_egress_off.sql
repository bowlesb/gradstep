-- Our servers never contact arXiv (owner direction 2026-10-15; docs/architecture/ARXIV_DEVICE_ONLY.md, rollout steps
-- 5–7): each reader's device calls arXiv only as that person's own agent, and shared data comes from DataCite.
--   1. The switches can no longer send a server to arXiv: `arxiv_egress` is off for good, the Feed's source is DataCite
--      only, and devices may send what they read (`source_metadata_enabled`).
--   2. `worker_pipeline_arxiv_slot` fails closed for any forgotten caller: nothing reserved, a ten-minute wait.
--   3. The metadata stage records an arXiv paper from DataCite (`worker_pipeline_datacite_metadata`), with the record's
--      provenance; shared reuse only for the exact version DataCite describes under CC BY 4.0 or CC0.
--   4. A device's record for an import still waiting for DataCite asks the pipeline again at once.
-- deploy-staging.py applies it before deploying the functions; the pipeline worker follows at once (until then the old
-- worker's arXiv gate refuses and new papers wait). Deploy order: ARXIV_DEVICE_ONLY.md §6.0.3.
begin;
set local lock_timeout='15s';

-- 1. Switches.
update app_private.pipeline_policy set arxiv_egress=false, source_metadata_enabled=true, feed_source='datacite' where singleton;
alter table app_private.pipeline_policy alter column arxiv_egress set default false;
alter table app_private.pipeline_policy add constraint pipeline_policy_arxiv_egress_off check (not arxiv_egress);
alter table app_private.pipeline_policy alter column feed_source set default 'datacite';
alter table app_private.pipeline_policy drop constraint pipeline_policy_feed_source_check;
alter table app_private.pipeline_policy add constraint pipeline_policy_feed_source_check check (feed_source = 'datacite');

-- The Feed's pool comes only from DataCite's row; `arxiv-ml` stays in feed_sources for the record.
create or replace function app_private.feed_active_source() returns text language sql stable security definer set search_path='' as $$
 select 'datacite-ml'::text
$$;

-- 2. arXiv's pacing gate, kept for older code: never reserves.
create or replace function public.worker_pipeline_arxiv_slot(p_slots integer default 1,p_max_wait_ms integer default 45000) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('reserved',false,'code','arxiv_egress_disabled','wait_ms',600000)
$$;

-- 3. Provenance of a record DataCite supplied directly (no import involved).
alter table app_private.catalog_metadata_provenance alter column import_account_id drop not null;
alter table app_private.catalog_metadata_provenance alter column import_id drop not null;
alter table app_private.catalog_metadata_provenance add constraint catalog_metadata_provenance_import check(
 origin='datacite' or (import_account_id is not null and import_id is not null));

-- The metadata stage's record from DataCite: `p_evidence` is what DataCite said (metadata-pipeline.ts
-- `dataciteCatalog`), checked here against the claimed paper; eligibility is decided here, not by the caller.
create function public.worker_pipeline_datacite_metadata(p_paper_id uuid,p_claim_id uuid,p_generation bigint,p_revision integer,
 p_metadata jsonb,p_evidence jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p app_private.pipeline_papers; latest integer; license text; eligible boolean; result jsonb; meta uuid;
begin
 select * into p from app_private.pipeline_papers where id=p_paper_id;
 if not found then raise exception 'stale_pipeline_claim'; end if;
 if p_revision is null or p_revision not between 1 and 9999 or p_evidence is null or jsonb_typeof(p_evidence)<>'object'
  or octet_length(p_evidence::text)>8192
  or p_evidence->>'origin' is distinct from 'datacite' or p_evidence->>'evidence_format' is distinct from 'datacite'
  or p_evidence->>'source_id' is distinct from p.source_id
  or lower(p_evidence->>'doi') is distinct from lower('10.48550/arXiv.'||p.source_id)
  or coalesce(jsonb_typeof(p_evidence->'source_revision'),'') <> 'number' or p_evidence->>'source_revision' is distinct from p_revision::text
  or p_evidence->>'source_url' is distinct from 'https://arxiv.org/abs/'||p.source_id||'v'||p_revision
  or coalesce(jsonb_typeof(p_evidence->'version'),'') <> 'number' or coalesce(p_evidence->>'version','') !~ '^[1-9][0-9]{0,3}$'
  or coalesce(p_evidence->>'evidence_sha256','') !~ '^[0-9a-f]{64}$'
  or coalesce(jsonb_typeof(p_evidence->'license_uri'),'') not in ('null','string')
  or coalesce(jsonb_typeof(p_evidence->'observed_at'),'') <> 'string'
 then raise exception 'invalid_pipeline_metadata'; end if;
 latest:=(p_evidence->>'version')::integer;
 license:=p_evidence->>'license_uri';
 if latest<p_revision or (license is not null and (latest<>p_revision or not exists(select 1 from app_private.arxiv_licenses l where l.uri=license)))
 then raise exception 'invalid_pipeline_metadata'; end if;
 perform (p_evidence->>'observed_at')::timestamptz;
 eligible:=latest=p_revision and coalesce(license in ('https://creativecommons.org/licenses/by/4.0/','https://creativecommons.org/publicdomain/zero/1.0/'),false);
 result:=public.worker_pipeline_metadata(p_paper_id,p_claim_id,p_generation,p_revision,p_metadata,eligible,license,
  case when eligible then p_evidence end);
 select metadata_id into strict meta from app_private.pipeline_papers where id=p_paper_id;
 insert into app_private.catalog_metadata_provenance(metadata_id,origin,evidence_sha256)
  values(meta,'datacite',decode(p_evidence->>'evidence_sha256','hex')) on conflict(metadata_id) do nothing;
 return result;
end $$;

-- 4. Migration 071's submission, plus: an import whose paper still waits at the metadata stage (DataCite hasn't
-- listed it yet) is asked again now rather than at its next scheduled attempt.
create or replace function public.v1_submit_source_metadata(p_import_id uuid,p_metadata jsonb,p_expected_revision integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a uuid:=app_private.require_actor(); i app_private.import_requests; digest bytea;
begin
 if not coalesce((select source_metadata_enabled from app_private.pipeline_policy where singleton),false) then
  raise exception 'source_metadata_disabled' using errcode='42501'; end if;
 if p_import_id is null or p_expected_revision is null or p_expected_revision not between 1 and 9999 then raise exception 'invalid_source_metadata'; end if;
 perform public.worker_consume_request(a,'source-metadata');
 select * into i from app_private.import_requests where account_id=a and id=p_import_id for update;
 if not found or not i.desired_present then raise exception 'document_unavailable' using errcode='42501'; end if;
 if i.requested_revision is not null and i.requested_revision<>p_expected_revision then raise exception 'revision_mismatch'; end if;
 if not app_private.valid_source_metadata(p_metadata,i.source_id,p_expected_revision) then raise exception 'invalid_source_metadata'; end if;
 if i.device_metadata_revision is not null and p_expected_revision<i.device_metadata_revision then raise exception 'revision_older'; end if;
 digest:=sha256(convert_to(p_metadata::text,'UTF8'));
 if i.device_metadata_sha256=digest then return jsonb_build_object('status','unchanged','revision',p_expected_revision); end if;
 update app_private.import_requests set device_metadata=p_metadata,device_metadata_origin=p_metadata->>'origin',device_metadata_sha256=digest,
  device_metadata_revision=p_expected_revision,device_metadata_at=now() where account_id=a and id=p_import_id;
 update app_private.pipeline_papers pp set next_attempt_at=clock_timestamp()
  from app_private.pipeline_imports pi where pi.account_id=a and pi.import_id=p_import_id and pp.id=pi.paper_id
   and pp.stage='metadata' and pp.metadata_id is null and pp.next_attempt_at>clock_timestamp();
 return jsonb_build_object('status','stored','revision',p_expected_revision);
end $$;

insert into app_private.admin_audit_events(actor_id,action,target_id,reason,details)
select r.account_id,'arxiv_egress','pipeline_policy',
 'Owner direction 2026-10-15: our servers never contact arXiv; metadata from DataCite and devices (docs/architecture/ARXIV_DEVICE_ONLY.md)',
 jsonb_build_object('arxiv_egress',false,'source_metadata_enabled',true,'feed_source','datacite','migration','202610160077')
from app_private.app_roles r join app_private.accounts a on a.id=r.account_id
where r.role='owner' and a.closed_at is null order by r.account_id limit 1;

revoke all on function public.worker_pipeline_datacite_metadata(uuid,uuid,bigint,integer,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.worker_pipeline_datacite_metadata(uuid,uuid,bigint,integer,jsonb,jsonb) to service_role;
notify pgrst,'reload schema';
commit;
