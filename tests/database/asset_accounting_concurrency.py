"""Actual PostgreSQL sessions: capacity, deletion/FK and member replay races."""
import json
import os
import select
import subprocess
import time
import uuid


def verify(bin_path, db, base):
    if list(base) != ['-h', '127.0.0.1', '-p', '55431'] or not db.startswith('science_reader_test_'):
        raise ValueError('Refusing non-disposable/non-loopback asset test target')
    env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
    sessions = []

    def sql(source):
        r = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                           input=source, text=True, capture_output=True, timeout=15, env=env)
        if r.returncode:
            raise AssertionError(r.stderr)
        return r.stdout.strip().splitlines()[-1]

    class Session:
        def __init__(self):
            self.process = subprocess.Popen([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            self.buffer = b''
            sessions.append(self)
            self.pid = int(self.complete("set statement_timeout='10s'; set lock_timeout='5s'; select pg_backend_pid();")[-1])

        def send(self, text):
            self.process.stdin.write((text + '\n').encode())
            self.process.stdin.flush()

        def until(self, marker):
            deadline = time.monotonic() + 12
            lines = []
            while time.monotonic() < deadline:
                while b'\n' in self.buffer:
                    raw, self.buffer = self.buffer.split(b'\n', 1)
                    line = raw.decode().strip()
                    if line == marker:
                        return lines
                    if line:
                        lines.append(line)
                if select.select([self.process.stdout], [], [], .1)[0]:
                    data = os.read(self.process.stdout.fileno(), 65536)
                    if not data:
                        raise AssertionError(self.process.stderr.read().decode())
                    self.buffer += data
            raise AssertionError('SQL barrier timeout')

        def complete(self, source):
            marker = 'barrier_' + uuid.uuid4().hex
            self.send(source + f" select '{marker}';")
            return self.until(marker)

        def error(self, expected):
            code = self.process.wait(timeout=12)
            detail = self.process.stderr.read().decode()
            assert code and expected in detail, detail

        def close(self):
            if self.process.stdin and not self.process.stdin.closed:
                self.process.stdin.close()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=3)
            self.process.stdout.close()
            self.process.stderr.close()

    def blocked_by(waiter, holder):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if sql(f'select {holder.pid}=any(pg_blocking_pids({waiter.pid}));') == 't':
                return
            if waiter.process.poll() is not None:
                raise AssertionError(waiter.process.stderr.read().decode())
            time.sleep(.02)
        raise AssertionError('Expected real lock wait was not observed')

    accounts = [str(uuid.uuid4()) for _ in range(4)]
    papers = [str(uuid.uuid4()) for _ in range(3)]
    claims = [str(uuid.uuid4()) for _ in range(3)]
    old_cap = sql('select max_bytes from app_private.paper_storage_capacity;')
    old_delivery_mode = sql('select mode from app_private.reader_delivery_policy;')
    try:
        sql('insert into auth.users values' + ','.join(f"('{a}')" for a in accounts) + '; select 1;')
        for n, (account, paper, claim) in enumerate(zip(accounts, papers, claims)):
            sql(f"""select public.worker_grant_credits('{account}','adjustment','asset-race:{account}',10,now()-interval '1 day',null,'Synthetic asset race');
              insert into app_private.pipeline_papers(id,owner_id,source_id,revision,stage,eligible,claim_id,generation,lease_until)
              values('{paper}','{account}','2411.0340{n}',1,'download',false,'{claim}',1,clock_timestamp()+interval '10 minutes'); select 1;""")
        sql("""update app_private.paper_storage_capacity set max_bytes=
          (select coalesce(sum(byte_count),0) from app_private.stored_objects where bucket='paper-assets' and state<>'deleted')+
          (select coalesce(sum(bytes),0) from app_private.paper_asset_holds)+159907840; select 1;""")
        one, two = Session(), Session()
        one.complete('begin;')
        result = json.loads(one.complete(f"select public.worker_pipeline_admit_download('{papers[0]}','{claims[0]}',1);")[-1])
        assert result['admitted'] is True
        marker = 'capacity_done'
        two.send(f"select public.worker_pipeline_admit_download('{papers[1]}','{claims[1]}',1); select '{marker}';")
        blocked_by(two, one)
        one.complete('commit;')
        assert json.loads(two.until(marker)[-1])['admitted'] is False
        assert sql(f"select count(*) from app_private.paper_asset_holds where paper_id='{papers[1]}';") == '0'
        sql(f"update app_private.paper_storage_capacity set max_bytes={old_cap}; update app_private.reader_delivery_policy set mode='{old_delivery_mode}'; select 1;")
        print('PASS competing original admissions reserve one remaining full-pipeline slot', flush=True)

        def plan(index, upload):
            objects = json.dumps([{'path': f'private/{accounts[index]}/originals/' + str(index + 5) * 64 + '.pdf',
                                   'sha256': str(index + 5) * 64, 'bytes': 1000, 'media_type': 'application/pdf'}])
            return f"select public.worker_pipeline_asset_plan('{papers[index]}','{claims[index]}',1,'{upload}','original','{objects}',1);"

        # Publication must take paper before capacity/availability. The former
        # wrapper did the reverse and deadlocked this exact interleaving.
        upload, attempt = str(uuid.uuid4()), str(uuid.uuid4())
        original = json.loads(sql(plan(0, upload)))['objects'][0]['id']
        sql(f"select public.worker_pipeline_asset_write('{papers[0]}','{claims[0]}',1,'{upload}','{original}','{attempt}'); select public.worker_pipeline_asset_written('{attempt}',true); select 1;")
        paper_holder, publisher = Session(), Session()
        paper_holder.complete(f"begin; select id from app_private.pipeline_papers where id='{papers[0]}' for update;")
        publisher.send(f"select public.worker_pipeline_original('{papers[0]}','{claims[0]}',1,decode(repeat('5',64),'hex'),1000,1,'private/{accounts[0]}/originals/{'5' * 64}.pdf');")
        blocked_by(publisher, paper_holder)
        paper_holder.complete(f"select singleton from app_private.paper_storage_capacity for update; update app_private.pipeline_papers set stage='failed' where id='{papers[0]}'; commit;")
        publisher.error('invalid_pipeline_stage')
        print('PASS publication waits on paper before taking capacity or availability locks', flush=True)

        closer, planner = Session(), Session()
        closer.complete(f"begin; select public.worker_delete_account_begin('{accounts[2]}');")
        planner.send(plan(2, str(uuid.uuid4())))
        blocked_by(planner, closer)
        closer.complete('commit;')
        planner.error('account_unavailable')
        assert sql(f"select count(*) from app_private.paper_asset_uploads where paper_id='{papers[2]}';") == '0'
        print('PASS deletion-first plan waits on the account then creates no private objects', flush=True)

        writer, closer2 = Session(), Session()
        upload, attempt = str(uuid.uuid4()), str(uuid.uuid4())
        writer.complete('begin;')
        prepared = json.loads(writer.complete(plan(1, upload))[-1])
        member = prepared['objects'][0]['id']
        writer.complete(f"select public.worker_pipeline_asset_write('{papers[1]}','{claims[1]}',1,'{upload}','{member}','{attempt}');")
        closer2.send(f"select public.worker_delete_account_begin('{accounts[1]}'); select 'closed';")
        blocked_by(closer2, writer)
        writer.complete('commit;')
        deletion = json.loads(closer2.until('closed')[-1])
        assert deletion['blocked'] == 'asset_write_uncertain' and deletion['objects'] == []
        sql(f"select public.worker_pipeline_asset_written('{attempt}',true); select 1;")
        deletion = json.loads(sql(f"select public.worker_delete_account_begin('{accounts[1]}');"))
        assert len(deletion['objects']) == 1 and 'blocked' not in deletion
        sql(f"select public.worker_delete_account_finish('{accounts[1]}');")
        assert sql(f"select state from app_private.stored_objects where id='{member}';") == 'deleted'
        print('PASS upload-first deletion waits, then withholds physical removal until the late write is terminal', flush=True)

        # Trusted small delivery fixture: immutable document+manifest/member,
        # membership and its normal availability projection. No real content.
        account = accounts[3]
        document, manifest, member, run, artifact, item = [str(uuid.uuid4()) for _ in range(6)]
        sql(f"""insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count)
          values('{document}',sha256(convert_to('{document}','UTF8')),'shared_catalog','{{"fixture":true}}',1000,1);
          insert into app_private.stored_objects(id,bucket,path,document_id,state,sha256,byte_count,media_type,verified_at) values
          ('{manifest}','paper-assets','reader/{'8' * 64}/manifest.json','{document}','verified',decode(repeat('8',64),'hex'),100,'application/json',now()),
          ('{member}','paper-assets','reader/{'8' * 64}/index.html','{document}','verified',decode(repeat('9',64),'hex'),200,'text/html',now());
          insert into app_private.paper_asset_manifest_members values('{manifest}','{member}','index.html');
          insert into app_private.ocr_runs(id,document_id,provider,options_sha256) values('{run}','{document}','fixture',decode(repeat('b',64),'hex'));
          insert into app_private.render_artifacts(id,ocr_run_id,renderer_version,manifest_object_id)
          values('{artifact}','{run}','timestep-mathpix-mathml-v1','{manifest}');
          select app_private.mark_paper_availability('{manifest}','available');
          insert into app_private.library_items(id,account_id,document_id,artifact_id) values('{item}','{account}','{document}','{artifact}');
          update app_private.reader_delivery_policy set mode='dual';
          select public.worker_reader_delivery_create('{account}','{item}',decode(repeat('c',64),'hex'),'bounded-v1');""")
        reader1, reader2 = Session(), Session()
        call = f"select public.worker_reader_delivery_redeem('{account}',decode(repeat('c',64),'hex'),'{member}');"
        reader1.complete('begin; ' + call)
        reader2.send(call)
        blocked_by(reader2, reader1)
        reader1.complete('commit;')
        reader2.error('reader_grant_consumed')
        assert sql(f"select count(*) from app_private.reader_delivery_redemptions where object_id='{member}';") == '1'
        assert sql(f"select authorized_bytes from app_private.reader_transfer_months where scope_id='{account}' and kind='reader';") == str(1048576 + 200)
        print('PASS concurrent member replay commits exactly one byte charge and one redemption', flush=True)
    finally:
        for session in sessions:
            session.close()
        sql(f'update app_private.paper_storage_capacity set max_bytes={old_cap}; select 1;')
