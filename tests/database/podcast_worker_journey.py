"""Zero-spend podcast journey on the real migrated schema: the TypeScript worker and Edge handlers (run by Node)
call the SQL functions through psql; providers, Storage and the encoder are local fakes."""
import hashlib
import json
import os
import pathlib
import secrets
import subprocess
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
PAPER = ('# Journey fixture paper\n## Abstract\nWe study a synthetic routing method for journey tests only.\n'
         '## Results\nThe synthetic method keeps every expert busy during the whole training run.\n'
         'The authors report that the routing gate remains stable across all random seeds they tried.\n'
         '## Limitations\nThe evaluation covers only small synthetic models and a single synthetic dataset.\n'
         'The method has not been compared against the strongest published routing baselines.\n')


def verify(bin_path, db, base):
    if list(base) != ['-h', '127.0.0.1', '-p', '55431'] or not db.startswith('science_reader_test_'):
        raise ValueError('Refusing non-disposable/non-loopback podcast journey target')
    env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}

    def sql(source):
        result = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                input=source, text=True, capture_output=True, timeout=60, env=env)
        if result.returncode: raise AssertionError(result.stderr)
        return result.stdout.strip()

    def h(): return secrets.token_hex(32)
    owner, account, other = (str(uuid.uuid4()) for _ in range(3))
    pub, ver, doc, meta, appr, run, art, item = (str(uuid.uuid4()) for _ in range(8))
    orig, rawm, text, readm = (str(uuid.uuid4()) for _ in range(4))
    raw_digest, reader_digest = h(), h()
    paper = PAPER.encode()
    text_path = f'raw/{raw_digest}/standalone.mmd'
    metadata = json.dumps({'title': 'Journey fixture paper', 'authors': ['J. Fixture'], 'published_at': '2025-01-02', 'categories': ['cs.LG']})
    sql(f"""begin;
      insert into auth.users(id) values('{owner}'),('{account}'),('{other}');
      insert into app_private.app_roles(account_id,role) values('{owner}','owner');
      insert into app_private.publications(id,title) values('{pub}','Journey fixture paper');
      insert into app_private.publication_versions(id,publication_id,source,revision) values('{ver}','{pub}','arxiv','1');
      insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count) values('{doc}',decode('{h()}','hex'),'shared_catalog','{{"license":"CC-BY-4.0"}}',1000,2);
      insert into app_private.version_documents values('{ver}','{doc}');
      insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at) values
       ('{orig}','paper-assets','originals/{h()}.pdf','{doc}','verified',decode('{h()}','hex'),1000,'application/pdf',now()),
       ('{rawm}','paper-assets','raw/{raw_digest}/manifest.json','{doc}','verified',decode('{raw_digest}','hex'),100,'application/json',now()),
       ('{text}','paper-assets','{text_path}','{doc}','verified',decode('{hashlib.sha256(paper).hexdigest()}','hex'),{len(paper)},'text/plain',now()),
       ('{readm}','paper-assets','reader/{reader_digest}/manifest.json','{doc}','verified',decode('{reader_digest}','hex'),100,'application/json',now());
      insert into app_private.paper_asset_manifest_members values('{rawm}','{text}','standalone.mmd');
      insert into app_private.catalog_metadata(id,version_id,source_id,source_revision,metadata,metadata_sha256)
       values('{meta}','{ver}','2501.{secrets.randbelow(90000) + 10000}',1,'{metadata}'::jsonb,sha256(convert_to('{metadata}'::jsonb::text,'UTF8')));
      insert into app_private.catalog_asset_approvals(id,version_id,document_id,metadata_id,original_object_id,license_uri,policy_version,evidence)
       values('{appr}','{ver}','{doc}','{meta}','{orig}','https://creativecommons.org/licenses/by/4.0/','arxiv-reuse-v1','{{}}');
      insert into app_private.ocr_runs(id,document_id,provider,options_sha256,raw_bundle_object_id) values('{run}','{doc}','mathpix',decode('{h()}','hex'),'{rawm}');
      insert into app_private.render_artifacts(id,ocr_run_id,renderer_version,manifest_object_id) values('{art}','{run}','podcast-journey-v1','{readm}');
      insert into app_private.library_items(id,account_id,document_id,approval_id,artifact_id) values('{item}','{account}','{doc}','{appr}','{art}');
      update app_private.paper_asset_policy set enforced=true,inventory_scope=3,inventory_verified_at=now(),inventory_discrepancies=0,reconciliation_id=null;
      update app_private.podcast_policy set max_active_environment=10,max_jobs_day_environment=200,max_active_private_per_account=5;
      update app_private.paper_storage_capacity set max_bytes=greatest(max_bytes,1073741824),max_objects=greatest(max_objects,50000);
      select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,30000000,true);
      select public.worker_grant_credits('{account}','adjustment','podcast-journey-{account}',1000,now()-interval '1 day',null,'Podcast journey fixture');
      commit;""")
    fixture = {'owner': owner, 'account': account, 'other': other, 'approval': appr, 'item': item, 'paper': text_path + '|' + PAPER}
    result = subprocess.run(['node', str(ROOT / 'tests/database/podcast-worker-journey.ts')], cwd=ROOT, capture_output=True, text=True, timeout=300,
                            env={**env, 'PODCAST_PSQL': str(bin_path / 'psql'), 'PODCAST_DB': db, 'PODCAST_FIXTURE': json.dumps(fixture)})
    if result.returncode: raise AssertionError(result.stdout[-3000:] + result.stderr[-3000:])
    print('PASS podcast worker journey', result.stdout.strip().splitlines()[-1], flush=True)
