"""Paper podcasts (migration 048) on real concurrent sessions: two devices starting the same private work, a
single-use audio grant redeemed twice at once, two workers claiming one job, and a seed allowance disabled while
an admission waits. Every race is forced with an observed lock wait, not timing."""
import json
import os
import secrets
import select
import subprocess
import time
import uuid


def verify(bin_path, db, base):
    if list(base) != ['-h', '127.0.0.1', '-p', '55431'] or not db.startswith('science_reader_test_'):
        raise ValueError('Refusing non-disposable/non-loopback podcast concurrency target')
    env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
    sessions = []

    def sql(source):
        result = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                input=source, text=True, capture_output=True, timeout=30, env=env)
        if result.returncode: raise AssertionError(result.stderr)
        lines = result.stdout.strip().splitlines()
        return lines[-1] if lines else ''

    class Session:
        def __init__(self):
            self.process = subprocess.Popen([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=0', '-d', db],
                                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            self.buffer = b''
            sessions.append(self)
            self.pid = int(self.complete("set statement_timeout='15s'; set lock_timeout='10s'; select pg_backend_pid();")[-1])

        def send(self, source):
            marker = 'barrier_' + uuid.uuid4().hex
            self.process.stdin.write((source + f"\nselect '{marker}';\n").encode())
            self.process.stdin.flush()
            return marker

        def until(self, marker):
            deadline, lines = time.monotonic() + 20, []
            while time.monotonic() < deadline:
                while b'\n' in self.buffer:
                    raw, self.buffer = self.buffer.split(b'\n', 1)
                    line = raw.decode().strip()
                    if line == marker: return lines
                    if line: lines.append(line)
                if select.select([self.process.stdout], [], [], .05)[0]:
                    data = os.read(self.process.stdout.fileno(), 65536)
                    if not data: raise AssertionError(self.process.stderr.read().decode())
                    self.buffer += data
            raise AssertionError('Podcast SQL barrier timeout')

        def complete(self, source): return self.until(self.send(source))

        def errors(self):
            chunks = []
            while select.select([self.process.stderr], [], [], .05)[0]:
                data = os.read(self.process.stderr.fileno(), 65536)
                if not data: break
                chunks.append(data)
            return b''.join(chunks).decode()

        def close(self):
            if self.process.stdin and not self.process.stdin.closed: self.process.stdin.close()
            try: self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.terminate(); self.process.wait(timeout=3)
            self.process.stdout.close(); self.process.stderr.close()

    def blocked(waiter, holder):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if sql(f'select pg_blocking_pids({waiter.pid}) && array[{holder.pid}];') == 't': return
            if waiter.process.poll() is not None: raise AssertionError(waiter.process.stderr.read().decode())
            time.sleep(.02)
        raise AssertionError('Expected podcast lock wait was not observed')

    def h(): return secrets.token_hex(32)
    owner, account, other = (str(uuid.uuid4()) for _ in range(3))
    pub, ver, doc, meta, appr, run, art, item = (str(uuid.uuid4()) for _ in range(8))
    orig, rawm, text, readm = (str(uuid.uuid4()) for _ in range(4))
    raw_digest, reader_digest = h(), h()
    source_id = f'2410.{secrets.randbelow(90000) + 10000}'
    metadata = json.dumps({'title': 'Concurrency fixture paper', 'authors': ['A. Fixture'], 'published_at': '2024-10-02', 'categories': ['cs.LG']})
    # A converted CC BY paper in one account's library, built from its committed identities (no pipeline claim).
    sql(f"""begin;
      insert into auth.users(id) values('{owner}'),('{account}'),('{other}');
      insert into app_private.app_roles(account_id,role) values('{owner}','owner');
      insert into app_private.publications(id,title) values('{pub}','Concurrency fixture paper');
      insert into app_private.publication_versions(id,publication_id,source,revision) values('{ver}','{pub}','arxiv','1');
      insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count) values('{doc}',decode('{h()}','hex'),'shared_catalog','{{"license":"CC-BY-4.0"}}',1000,2);
      insert into app_private.version_documents values('{ver}','{doc}');
      insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at) values
       ('{orig}','paper-assets','originals/{h()}.pdf','{doc}','verified',decode('{h()}','hex'),1000,'application/pdf',now()),
       ('{rawm}','paper-assets','raw/{raw_digest}/manifest.json','{doc}','verified',decode('{raw_digest}','hex'),100,'application/json',now()),
       ('{text}','paper-assets','raw/{raw_digest}/standalone.mmd','{doc}','verified',decode('{h()}','hex'),5000,'text/plain',now()),
       ('{readm}','paper-assets','reader/{reader_digest}/manifest.json','{doc}','verified',decode('{reader_digest}','hex'),100,'application/json',now());
      insert into app_private.paper_asset_manifest_members values('{rawm}','{text}','standalone.mmd');
      insert into app_private.catalog_metadata(id,version_id,source_id,source_revision,metadata,metadata_sha256)
       values('{meta}','{ver}','{source_id}',1,'{metadata}'::jsonb,sha256(convert_to('{metadata}'::jsonb::text,'UTF8')));
      insert into app_private.catalog_asset_approvals(id,version_id,document_id,metadata_id,original_object_id,license_uri,policy_version,evidence)
       values('{appr}','{ver}','{doc}','{meta}','{orig}','https://creativecommons.org/licenses/by/4.0/','arxiv-reuse-v1','{{}}');
      insert into app_private.ocr_runs(id,document_id,provider,options_sha256,raw_bundle_object_id) values('{run}','{doc}','mathpix',decode('{h()}','hex'),'{rawm}');
      insert into app_private.render_artifacts(id,ocr_run_id,renderer_version,manifest_object_id) values('{art}','{run}','podcast-concurrency-v1','{readm}');
      insert into app_private.library_items(id,account_id,document_id,approval_id,artifact_id) values('{item}','{account}','{doc}','{appr}','{art}');
      update app_private.paper_asset_policy set enforced=true,inventory_scope=3,inventory_verified_at=now(),inventory_discrepancies=0,reconciliation_id=null;
      update app_private.podcast_policy set catalog_enabled=true,delivery_enabled=true,generation_enabled=true,seed_enabled=true,
       fixtures_enabled=true,max_active_environment=10,max_jobs_day_environment=200;
      update app_private.paper_storage_capacity set max_bytes=greatest(max_bytes,1073741824),max_objects=greatest(max_objects,50000);
      select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,30000000,true);
      select public.worker_grant_credits('{account}','adjustment','podcast-concurrency-{account}',1000,now()-interval '1 day',null,'Podcast concurrency fixture');
      commit;""")
    actor = lambda who: f"set role authenticated; set request.jwt.claim.sub='{who}';"
    try:
        # 1. Two devices of one account start the same private work: one funding operation, the other joins.
        q1 = json.loads(sql(actor(account) + f"select public.v1_podcast_quote('{item}','{uuid.uuid4()}');"))['quote']['id']
        q2 = json.loads(sql(actor(account) + f"select public.v1_podcast_quote('{item}','{uuid.uuid4()}');"))['quote']['id']
        r1, r2 = str(uuid.uuid4()), str(uuid.uuid4())
        first, second = Session(), Session()
        first.complete('begin; ' + actor(account) + f"select public.v1_podcast_start('{q1}','{r1}','podcast-private-v1');")
        marker = second.send('begin; ' + actor(account) + f"select public.v1_podcast_start('{q2}','{r2}','podcast-private-v1');")
        blocked(second, first)
        first.complete('commit;')
        joined = json.loads(second.until(marker)[-1]); second.complete('commit;')
        assert joined['job']['request_id'] == r2 and joined['job']['state'] == 'queued', joined
        assert sql(f"select count(*) from app_private.metered_operations where account_id='{account}' and kind='podcast';") == '1', 'one hold'
        assert sql(f"select string_agg(outcome,',' order by outcome) from app_private.podcast_requests where account_id='{account}';") == 'joined,started'
        assert sql(actor(account) + "select (public.v1_credit_balance()->>'reserved');") == '150'

        # 1b. The operator policy call takes podcast policy before storage capacity, as every other path does:
        # a start/asset-plan path holding policy and then asking for capacity cannot deadlock with it.
        holder, operator = Session(), Session()
        holder.complete("begin; select 1 from app_private.podcast_policy where singleton for update;")
        marker = operator.send(f"select public.worker_podcast_policy_set('{owner}','{uuid.uuid4()}','{{\"max_jobs_day_environment\":200}}','Race fixture');")
        blocked(operator, holder)
        holder.complete("select 1 from app_private.paper_storage_capacity where singleton for update; commit;")
        operator.until(marker)
        assert 'deadlock' not in operator.errors()

        # 2. Two workers claim the one queued job: exactly one owns it.
        a, b = Session(), Session()
        a_claim = json.loads(a.complete('begin; reset role; ' + f"select public.worker_podcast_claim('{uuid.uuid4()}');")[-1])
        assert a_claim['claimed'] is True, a_claim
        marker = b.send('begin; reset role; ' + f"select public.worker_podcast_claim('{uuid.uuid4()}');")
        blocked(b, a)
        a.complete('commit;')
        b_claim = json.loads(b.until(marker)[-1]); b.complete('commit;')
        assert b_claim['claimed'] is False, b_claim
        job = a_claim['job_id']
        assert sql(f"select state||':'||claim_generation from app_private.podcast_jobs where id='{job}';") == 'scripting:1'

        # 3. Cancel during work stops the next paid grant (no POST) and settles known usage only.
        sql(actor(account) + f"select public.v1_podcast_cancel('{r1}');")
        grant = json.loads(sql(f"select public.worker_podcast_attempt_begin('{job}','{a_claim['claim_id']}',{a_claim['generation']},"
                               f"'{uuid.uuid4()}','podcast_script',sha256('x'));"))
        assert grant['granted'] is False and grant['reason'] == 'canceled', grant
        assert sql(actor(account) + "select (public.v1_credit_balance()->>'reserved');") == '0'

        # 4. A seed admission waiting on the budget lock observes an allowance disabled meanwhile.
        month = sql("select date_trunc('month',now() at time zone 'UTC')::date;")
        sql(f"select public.worker_podcast_seed_period('{owner}','{uuid.uuid4()}','{month}',2000000,true,'concurrency-fixture');")
        holder, waiter = Session(), Session()
        holder.complete(f"begin; select public.worker_podcast_seed_period('{owner}','{uuid.uuid4()}','{month}',2000000,false,'concurrency-disable');")
        # Autocommit: the refused statement rolls itself back and the barrier still answers.
        marker = waiter.send(f"select public.worker_podcast_seed_admit('{owner}','{uuid.uuid4()}','{appr}','Seed racing a disable');")
        blocked(waiter, holder)
        holder.complete('commit;')
        waiter.until(marker)
        assert 'seed_allowance_unavailable' in waiter.errors()
        assert sql(f"select count(*) from app_private.podcast_jobs where funding_kind='platform_seed';") == '0'

        # 5. A fixture release delivered once: two concurrent redemptions of one grant, one succeeds.
        sql(f"select public.worker_podcast_seed_period('{owner}','{uuid.uuid4()}','{month}',2000000,true,'concurrency-reenable');")
        fixture = json.loads(sql(f"select public.worker_podcast_seed_admit('{owner}','{uuid.uuid4()}','{appr}','Fixture for delivery race',true);"))
        claim = json.loads(sql(f"select public.worker_podcast_claim('{uuid.uuid4()}');"))
        assert claim['job_id'] == fixture['id'], claim
        fence = f"'{claim['job_id']}','{claim['claim_id']}',{claim['generation']}"
        for state in ('checking', 'synthesizing', 'verifying', 'publishing'):
            sql(f"select public.worker_podcast_advance({fence},'{state}');")
        key, upload = h(), str(uuid.uuid4())
        objects = [{'role': 'audio', 'path': f'shared/{key}/audio.m4a', 'sha256': h(), 'bytes': 1000, 'media_type': 'audio/mp4'},
                   {'role': 'transcript', 'path': f'shared/{key}/transcript.json', 'sha256': h(), 'bytes': 100, 'media_type': 'application/json'},
                   {'role': 'manifest', 'path': f'shared/{key}/manifest.json', 'sha256': h(), 'bytes': 100, 'media_type': 'application/json'}]
        plan = json.loads(sql(f"select public.worker_podcast_asset_plan({fence},'{upload}','{json.dumps(objects)}'::jsonb);"))
        for planned in plan['objects']:
            write = str(uuid.uuid4())
            sql(f"select public.worker_podcast_asset_write({fence},'{upload}','{planned['id']}','{write}');")
            sql(f"select public.worker_podcast_asset_written('{write}',true);")
        release = json.loads(sql(f"""select public.worker_podcast_publish({fence},'{upload}',jsonb_build_object('script_sha256','{h()}',
          'checker_version','podcast-checker-v1','segments',6,'chapters',3,'duration_ms',30000,'manifest_sha256','{objects[2]['sha256']}',
          'identity','{{}}'::jsonb));"""))['release']['release_id']
        sql(f"select public.worker_podcast_review('{owner}','{uuid.uuid4()}','{release}','publish','Fixture for delivery race');")
        token = h()
        grant = json.loads(sql(f"select public.worker_podcast_delivery_create('{other}','{release}',sha256('{token}'));"))
        audio = grant['members'][0]['id']
        one, two = Session(), Session()
        one.complete(f"begin; select public.worker_podcast_delivery_redeem('{other}',sha256('{token}'),'{audio}');")
        marker = two.send(f"select public.worker_podcast_delivery_redeem('{other}',sha256('{token}'),'{audio}');")
        blocked(two, one)
        one.complete('commit;')
        two.until(marker)
        assert 'podcast_grant_consumed' in two.errors()
        assert sql(f"select count(*) from app_private.podcast_delivery_redemptions r join app_private.podcast_delivery_grants g on g.id=r.grant_id "
                   f"where g.account_id='{other}';") == '1', 'one redemption, one charge'
        assert sql(f"select authorized_bytes from app_private.reader_transfer_months where scope_id='{other}' and kind='podcast';") == '1000'
    finally:
        for session in sessions: session.close()
