-- Device-supplied source metadata (docs/architecture/ARXIV_DEVICE_ONLY.md §5.3–5.4, rollout step 2). Owner direction,
-- 2026-10-15: our servers never contact arXiv; readers' devices read a paper's metadata from what they download and
-- pass it up. Additive and switched off: `source_metadata_enabled` is false, so the submit RPC refuses and the reader
-- capability says off; nothing reads the new columns yet (the metadata stage and the library projection change in
-- step 5). Device data stays on the submitting account's import row; it reaches the shared catalog only through
-- `worker_catalog_promote` (a server-side DataCite match) or `admin_catalog_promote` (the owner, with a reason).
begin;
set local lock_timeout='15s';

-- The same tables as supabase/functions/_shared/source-metadata.ts (tests/backend/source-metadata.test.ts compares).
create table app_private.arxiv_categories(code text primary key check(code ~ '^[a-z-]+(\.[A-Za-z-]+)?$'));
insert into app_private.arxiv_categories(code) values
 ('cs.AI'),('cs.AR'),('cs.CC'),('cs.CE'),('cs.CG'),('cs.CL'),('cs.CR'),('cs.CV'),('cs.CY'),('cs.DB'),
 ('cs.DC'),('cs.DL'),('cs.DM'),('cs.DS'),('cs.ET'),('cs.FL'),('cs.GL'),('cs.GR'),('cs.GT'),('cs.HC'),
 ('cs.IR'),('cs.IT'),('cs.LG'),('cs.LO'),('cs.MA'),('cs.MM'),('cs.MS'),('cs.NA'),('cs.NE'),('cs.NI'),
 ('cs.OH'),('cs.OS'),('cs.PF'),('cs.PL'),('cs.RO'),('cs.SC'),('cs.SD'),('cs.SE'),('cs.SI'),('cs.SY'),
 ('econ.EM'),('econ.GN'),('econ.TH'),('eess.AS'),('eess.IV'),('eess.SP'),('eess.SY'),('math.AC'),('math.AG'),('math.AP'),
 ('math.AT'),('math.CA'),('math.CO'),('math.CT'),('math.CV'),('math.DG'),('math.DS'),('math.FA'),('math.GM'),('math.GN'),
 ('math.GR'),('math.GT'),('math.HO'),('math.IT'),('math.KT'),('math.LO'),('math.MG'),('math.MP'),('math.NA'),('math.NT'),
 ('math.OA'),('math.OC'),('math.PR'),('math.QA'),('math.RA'),('math.RT'),('math.SG'),('math.SP'),('math.ST'),('astro-ph'),
 ('astro-ph.CO'),('astro-ph.EP'),('astro-ph.GA'),('astro-ph.HE'),('astro-ph.IM'),('astro-ph.SR'),('cond-mat'),('cond-mat.dis-nn'),('cond-mat.mes-hall'),('cond-mat.mtrl-sci'),
 ('cond-mat.other'),('cond-mat.quant-gas'),('cond-mat.soft'),('cond-mat.stat-mech'),('cond-mat.str-el'),('cond-mat.supr-con'),('gr-qc'),('hep-ex'),('hep-lat'),('hep-ph'),
 ('hep-th'),('math-ph'),('nucl-ex'),('nucl-th'),('quant-ph'),('nlin'),('nlin.AO'),('nlin.CD'),('nlin.CG'),('nlin.PS'),
 ('nlin.SI'),('physics'),('physics.acc-ph'),('physics.ao-ph'),('physics.app-ph'),('physics.atm-clus'),('physics.atom-ph'),('physics.bio-ph'),('physics.chem-ph'),('physics.class-ph'),
 ('physics.comp-ph'),('physics.data-an'),('physics.ed-ph'),('physics.flu-dyn'),('physics.gen-ph'),('physics.geo-ph'),('physics.hist-ph'),('physics.ins-det'),('physics.med-ph'),('physics.optics'),
 ('physics.plasm-ph'),('physics.pop-ph'),('physics.soc-ph'),('physics.space-ph'),('q-bio'),('q-bio.BM'),('q-bio.CB'),('q-bio.GN'),('q-bio.MN'),('q-bio.NC'),
 ('q-bio.OT'),('q-bio.PE'),('q-bio.QM'),('q-bio.SC'),('q-bio.TO'),('q-fin.CP'),('q-fin.EC'),('q-fin.GN'),('q-fin.MF'),('q-fin.PM'),
 ('q-fin.PR'),('q-fin.RM'),('q-fin.ST'),('q-fin.TR'),('stat.AP'),('stat.CO'),('stat.ME'),('stat.ML'),('stat.OT'),('stat.TH'),
 ('acc-phys'),('adap-org'),('alg-geom'),('ao-sci'),('atom-ph'),('bayes-an'),('chao-dyn'),('chem-ph'),('cmp-lg'),('comp-gas'),
 ('dg-ga'),('funct-an'),('mtrl-th'),('patt-sol'),('plasm-ph'),('q-alg'),('solv-int'),('supr-con');
create table app_private.arxiv_licenses(uri text primary key, label text not null);
insert into app_private.arxiv_licenses(uri,label) values
 ('https://creativecommons.org/licenses/by/4.0/','CC BY 4.0'),
 ('https://creativecommons.org/licenses/by-sa/4.0/','CC BY-SA 4.0'),
 ('https://creativecommons.org/licenses/by-nc-sa/4.0/','CC BY-NC-SA 4.0'),
 ('https://creativecommons.org/licenses/by-nc-nd/4.0/','CC BY-NC-ND 4.0'),
 ('https://creativecommons.org/publicdomain/zero/1.0/','CC Zero'),
 ('http://arxiv.org/licenses/nonexclusive-distrib/1.0/','arXiv.org perpetual non-exclusive license'),
 ('https://creativecommons.org/licenses/by/3.0/','CC BY 3.0'),
 ('https://creativecommons.org/licenses/by-nc-sa/3.0/','CC BY-NC-SA 3.0'),
 ('https://creativecommons.org/licenses/publicdomain/','Public Domain'),
 ('http://arxiv.org/licenses/assumed-1991-2003/','Assumed arXiv.org perpetual non-exclusive license');

-- Flags. `arxiv_egress` (true until step 5) says whether the metadata stage may still call arXiv; the stage reads it
-- then. `source_metadata_enabled` lets devices submit and turns the reader capability on.
alter table app_private.pipeline_policy add column arxiv_egress boolean not null default true;
alter table app_private.pipeline_policy add column source_metadata_enabled boolean not null default false;

-- The submitting account's own record, on its import. Never read into shared tables except by promotion below.
alter table app_private.import_requests add column device_metadata jsonb
 check(device_metadata is null or (jsonb_typeof(device_metadata)='object' and octet_length(device_metadata::text)<=30000));
alter table app_private.import_requests add column device_metadata_origin text check(device_metadata_origin in ('arxiv_html','arxiv_api','datacite'));
alter table app_private.import_requests add column device_metadata_sha256 bytea check(device_metadata_sha256 is null or octet_length(device_metadata_sha256)=32);
alter table app_private.import_requests add column device_metadata_revision integer check(device_metadata_revision between 1 and 9999);
alter table app_private.import_requests add column device_metadata_at timestamptz;
alter table app_private.import_requests add constraint device_metadata_complete check(
 (device_metadata is null)=(device_metadata_origin is null) and (device_metadata is null)=(device_metadata_sha256 is null)
 and (device_metadata is null)=(device_metadata_revision is null) and (device_metadata is null)=(device_metadata_at is null));

-- Where a promoted catalog row came from. Catalog rows are immutable records, so their provenance is a companion row
-- written when they are promoted (rows recorded before this migration have none: arXiv's API and OAI).
create table app_private.catalog_metadata_provenance (
 metadata_id uuid primary key references app_private.catalog_metadata(id),
 origin text not null check(origin in ('datacite','device_verified','operator')),
 evidence_sha256 bytea not null check(octet_length(evidence_sha256)=32),
 import_account_id uuid not null, import_id uuid not null,
 recorded_at timestamptz not null default now()
);

insert into app_private.api_rate_rules values('source-metadata',3600,120,2000) on conflict(route) do nothing;

-- The contract check (format arxiv-source-metadata-v1), the same rules as validateSourceMetadata: exact keys; the
-- import's identifier and revision; NFC text without control or direction-override characters, trimmed; bounded
-- arrays; categories and licences from the tables; real dates, not in the future, and never before the identifier's
-- month; a parseable observation time not in the future.
create function app_private.valid_source_text(t text, max_chars integer, multiline boolean) returns boolean
language sql immutable set search_path='' as $$
 select t is not null and char_length(t) between 1 and max_chars and t=btrim(t) and normalize(t,NFC)=t
  and t !~ (case when multiline then '[\u0000-\u0008\u000b-\u001f\u007f-\u009f  ‪-‮⁦-⁩]'
              else '[\u0000-\u001f\u007f-\u009f  ‪-‮⁦-⁩]' end)
$$;
create function app_private.valid_source_metadata(m jsonb, p_source_id text, p_revision integer) returns boolean
language plpgsql stable security definer set search_path='' as $$
declare d date; id_month date; observed timestamptz;
begin
 if m is null or jsonb_typeof(m)<>'object' or octet_length(m::text)>30000 then return false; end if;
 if (select array_agg(k order by k) from jsonb_object_keys(m) k) is distinct from
  array['abstract','authors','categories','format','html_available','license_uri','observed_at','origin','revision','source_id','title','version_date']
 then return false; end if;
 if m->>'format' is distinct from 'arxiv-source-metadata-v1' or m->>'source_id' is distinct from p_source_id
  or p_source_id !~ '^([0-9]{4}\.[0-9]{4,5}|[a-z-]+(\.[A-Z]{2})?/[0-9]{7})$' then return false; end if;
 if jsonb_typeof(m->'revision')<>'number' or (m->>'revision') !~ '^[1-9][0-9]{0,3}$' or (m->>'revision')::integer is distinct from p_revision then return false; end if;
 if m->>'origin' is null or m->>'origin' not in ('arxiv_html','arxiv_api','datacite') then return false; end if;
 if jsonb_typeof(m->'title')<>'string' or not app_private.valid_source_text(m->>'title',2000,false) then return false; end if;
 if jsonb_typeof(m->'authors')<>'array' or jsonb_array_length(m->'authors') not between 1 and 512
  or exists(select 1 from jsonb_array_elements(m->'authors') a where jsonb_typeof(a)<>'string' or not app_private.valid_source_text(a#>>'{}',256,false))
 then return false; end if;
 if jsonb_typeof(m->'abstract') not in ('null','string')
  or (jsonb_typeof(m->'abstract')='string' and not app_private.valid_source_text(m->>'abstract',24000,true)) then return false; end if;
 if jsonb_typeof(m->'categories')<>'array' or jsonb_array_length(m->'categories')>64
  or exists(select 1 from jsonb_array_elements(m->'categories') c where jsonb_typeof(c)<>'string'
   or not exists(select 1 from app_private.arxiv_categories x where x.code=c#>>'{}'))
  or (select count(distinct c) from jsonb_array_elements_text(m->'categories') c)<>jsonb_array_length(m->'categories')
 then return false; end if;
 if jsonb_typeof(m->'license_uri') not in ('null','string')
  or (jsonb_typeof(m->'license_uri')='string' and not exists(select 1 from app_private.arxiv_licenses l where l.uri=m->>'license_uri')) then return false; end if;
 if jsonb_typeof(m->'html_available')<>'boolean' then return false; end if;
 if jsonb_typeof(m->'version_date')='string' then
  if m->>'version_date' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then return false; end if;
  d:=(m->>'version_date')::date;
  if d>current_date+1 or d<date '1991-08-01' then return false; end if;
  if p_source_id ~ '^[0-9]{4}\.' then
   id_month:=make_date(2000+substr(p_source_id,1,2)::integer,substr(p_source_id,3,2)::integer,1);
   if d<id_month then return false; end if;
  end if;
 elsif jsonb_typeof(m->'version_date')<>'null' then return false; end if;
 if jsonb_typeof(m->'observed_at')<>'string'
  or m->>'observed_at' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})$' then return false; end if;
 observed:=(m->>'observed_at')::timestamptz;
 if observed>now()+interval '5 minutes' then return false; end if;
 return true;
exception when others then return false;
end $$;

-- A device sends what it read for one of its account's arXiv imports. Account-scoped, rate-limited, last write wins
-- for a revision, never an older revision over a newer one; refused while the flag is off.
create function public.v1_submit_source_metadata(p_import_id uuid,p_metadata jsonb,p_expected_revision integer) returns jsonb
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
 return jsonb_build_object('status','stored','revision',p_expected_revision);
end $$;

-- Verification helpers, deliberately conservative (a mismatch only means "not promoted"): case, spacing, ASCII and
-- common typographic punctuation and inline $math$ don't count in titles; an author's family name is the part before a
-- comma, else the last word.
create function app_private.comparable_title(t text) returns text language sql immutable set search_path='' as $$
 select btrim(regexp_replace(translate(lower(regexp_replace(normalize(coalesce(t,''),NFKC),'\$[^$]*\$',' ','g')),
  '‐‑‒–—―‘’‚‛“”„‟′″…·','                    '),'[[:space:][:punct:]]+',' ','g'))
$$;
create function app_private.family_name(t text) returns text language sql immutable set search_path='' as $$
 select regexp_replace(lower(case when position(',' in coalesce(t,''))>0 then split_part(t,',',1)
  else regexp_replace(btrim(normalize(coalesce(t,''),NFKC)),'^.*\s','') end),'[[:space:][:punct:]]+','','g')
$$;

-- The account's device record in the shared catalog's shape (the library decoders' metadata keys).
create function app_private.source_metadata_catalog_shape(m jsonb) returns jsonb language sql immutable set search_path='' as $$
 select jsonb_build_object('title',m->'title','authors',m->'authors','abstract',m->'abstract','categories',m->'categories',
  'venue',null,'published_at',null,'updated_at',m->'version_date')
$$;

-- Promotion through a server-side DataCite match (the verifier passes what DataCite says; the comparison happens here).
create function public.worker_catalog_promote(p_account_id uuid,p_import_id uuid,p_evidence jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare i app_private.import_requests; meta uuid;
begin
 select * into i from app_private.import_requests where account_id=p_account_id and id=p_import_id for update;
 if not found or i.device_metadata is null then raise exception 'source_metadata_unavailable'; end if;
 if p_evidence is null or jsonb_typeof(p_evidence)<>'object' or octet_length(p_evidence::text)>8192
  or p_evidence->>'origin' is distinct from 'datacite'
  or lower(p_evidence->>'doi') is distinct from lower('10.48550/arXiv.'||i.source_id)
  or coalesce(p_evidence->>'version','') !~ '^[1-9][0-9]{0,3}$' or (p_evidence->>'version')::integer<i.device_metadata_revision
  or app_private.comparable_title(p_evidence->>'title')='' or app_private.comparable_title(p_evidence->>'title') is distinct from app_private.comparable_title(i.device_metadata->>'title')
  or app_private.family_name(p_evidence->>'first_author')='' or app_private.family_name(p_evidence->>'first_author') is distinct from app_private.family_name(i.device_metadata->'authors'->>0)
 then raise exception 'verification_mismatch'; end if;
 meta:=public.worker_record_arxiv_metadata(i.source_id,i.device_metadata_revision,app_private.source_metadata_catalog_shape(i.device_metadata));
 insert into app_private.catalog_metadata_provenance(metadata_id,origin,evidence_sha256,import_account_id,import_id)
  values(meta,'device_verified',sha256(convert_to(p_evidence::text,'UTF8')),p_account_id,p_import_id) on conflict(metadata_id) do nothing;
 return meta;
end $$;

-- Promotion by the owner (MFA), with a reason in the audit log.
create function public.admin_catalog_promote(p_account_id uuid,p_import_id uuid,p_reason text) returns uuid
language plpgsql security definer set search_path='' as $$
declare i app_private.import_requests; meta uuid; evidence jsonb;
begin
 if not app_private.is_operator('owner') then raise exception 'operator_required' using errcode='42501'; end if;
 if p_reason is null or length(btrim(p_reason)) not between 3 and 1000 then raise exception 'reason_required'; end if;
 select * into i from app_private.import_requests where account_id=p_account_id and id=p_import_id for update;
 if not found or i.device_metadata is null then raise exception 'source_metadata_unavailable'; end if;
 meta:=public.worker_record_arxiv_metadata(i.source_id,i.device_metadata_revision,app_private.source_metadata_catalog_shape(i.device_metadata));
 evidence:=jsonb_build_object('origin','operator','operator',app_private.actor(),'import',p_import_id,'metadata_sha256',encode(i.device_metadata_sha256,'hex'));
 insert into app_private.catalog_metadata_provenance(metadata_id,origin,evidence_sha256,import_account_id,import_id)
  values(meta,'operator',sha256(convert_to(evidence::text,'UTF8')),p_account_id,p_import_id) on conflict(metadata_id) do nothing;
 insert into app_private.admin_audit_events(actor_id,action,target_id,reason,details)
  values(app_private.actor(),'catalog_promote',i.source_id||'v'||i.device_metadata_revision,btrim(p_reason),evidence||jsonb_build_object('metadata_id',meta));
 return meta;
end $$;

-- The reader capability: devices submit only while it says enabled.
alter function public.v1_reader_capabilities() rename to reader_capabilities_before_071;
alter function public.reader_capabilities_before_071() set schema app_private;
create function public.v1_reader_capabilities() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 return app_private.reader_capabilities_before_071()||jsonb_build_object('source_metadata',jsonb_build_object(
  'enabled',coalesce((select source_metadata_enabled from app_private.pipeline_policy where singleton),false),
  'format','arxiv-source-metadata-v1'));
end $$;

revoke all on app_private.arxiv_categories,app_private.arxiv_licenses,app_private.catalog_metadata_provenance from public,anon,authenticated,service_role;
revoke all on function app_private.valid_source_text(text,integer,boolean),app_private.valid_source_metadata(jsonb,text,integer),
 app_private.comparable_title(text),app_private.family_name(text),app_private.source_metadata_catalog_shape(jsonb),
 app_private.reader_capabilities_before_071() from public,anon,authenticated,service_role;
revoke all on function public.v1_submit_source_metadata(uuid,jsonb,integer),public.worker_catalog_promote(uuid,uuid,jsonb),
 public.admin_catalog_promote(uuid,uuid,text),public.v1_reader_capabilities() from public,anon,authenticated,service_role;
grant execute on function public.v1_submit_source_metadata(uuid,jsonb,integer),public.admin_catalog_promote(uuid,uuid,text),
 public.v1_reader_capabilities() to authenticated;
grant execute on function public.worker_catalog_promote(uuid,uuid,jsonb) to service_role;
notify pgrst,'reload schema';
commit;
