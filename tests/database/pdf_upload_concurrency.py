"""Real PDF-ingress capacity/closure/freeze/attachment races on disposable PostgreSQL."""
import json
import os
import select
import subprocess
import time
import uuid


def verify(bin_path, db, base):
    if list(base) != ['-h', '127.0.0.1', '-p', '55431'] or not db.startswith('science_reader_test_'):
        raise ValueError('Refusing non-disposable/non-loopback upload target')
    env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
    sessions = []

    def sql(source):
        result = subprocess.run([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                input=source, text=True, capture_output=True, timeout=15, env=env)
        if result.returncode: raise AssertionError(result.stderr)
        return result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ''

    class Session:
        def __init__(self):
            self.process = subprocess.Popen([str(bin_path / 'psql'), *base, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', db],
                                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            self.buffer = b''
            sessions.append(self)
            self.pid = int(self.complete("set statement_timeout='12s'; set lock_timeout='8s'; select pg_backend_pid();")[-1])
            self.complete("create function pg_temp.attempt(s text) returns jsonb language plpgsql as $$ declare r jsonb; begin execute s into r; return r; exception when others then return jsonb_build_object('error',sqlerrm); end $$;")

        def send(self, source):
            marker = 'barrier_' + uuid.uuid4().hex
            self.process.stdin.write((source + f" select '{marker}';\n").encode())
            self.process.stdin.flush()
            return marker

        def until(self, marker):
            deadline, lines = time.monotonic() + 15, []
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
            raise AssertionError('Upload SQL barrier timeout')

        def complete(self, source): return self.until(self.send(source))

        def close(self):
            if self.process.stdin and not self.process.stdin.closed: self.process.stdin.close()
            try: self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.terminate(); self.process.wait(timeout=3)
            self.process.stdout.close(); self.process.stderr.close()

    def blocked(waiter, holder):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if sql(f'select {holder.pid}=any(pg_blocking_pids({waiter.pid}));') == 't': return
            if waiter.process.poll() is not None: raise AssertionError(waiter.process.stderr.read().decode())
            time.sleep(.02)
        raise AssertionError('Expected upload lock wait was not observed')

    def ident(): return str(uuid.uuid4())
    def literal(value): return "'" + value.replace("'", "''") + "'"
    def attempt(statement): return f'select pg_temp.attempt({literal(statement)});'
    def account():
        value = ident()
        sql(f"insert into auth.users values('{value}'); select public.worker_grant_credits('{value}','adjustment','fixture-{value}',100,now()-interval '1 day',null,'Upload race');")
        return value
    sha = "decode(repeat('1',64),'hex')"
    def begin(owner, upload): return f"select public.worker_begin_pdf_upload('{owner}','{upload}',{sha},1000,array[{sha}],'paper')"
    def write(owner, upload, send): return f"select public.worker_pdf_upload_write('{owner}','{upload}',1,0,'{send}',{sha},1000)"
    def written(send): return f"select public.worker_pdf_upload_written('{send}',{sha},1000)"
    def freeze(owner, upload): return f"select public.worker_freeze_pdf_upload('{owner}','{upload}',1,2,0)"
    def attach(owner, upload): return f"select public.worker_finalize_pdf_upload('{owner}','{upload}',1)"
    def descriptor(owner,upload):
        sql(f"insert into app_private.library_descriptors(account_id,source_id,id,revision,mutation_id,device_id,epoch,format,ciphertext,sha256) values('{owner}','upload:{upload}',gen_random_uuid(),1,gen_random_uuid(),gen_random_uuid(),1,1,decode(repeat('11',28),'hex'),sha256(decode(repeat('11',28),'hex')));select 1;")
    def ready(owner):
        upload, send = ident(), ident(); sql(begin(owner,upload)); sql(write(owner,upload,send)); sql(written(send)); descriptor(owner,upload); return upload,send
    def web(owner):
        imported, claim = ident(), ident()
        source='openalex:W'+str(uuid.uuid4().int % 10**9+1000000000)
        sql(f"select set_config('request.jwt.claim.sub','{owner}',false);select public.v2_begin_web_import('{imported}','{source}',0);")
        shared=sql(f"select id from app_private.pipeline_papers where owner_id is null and source_id='{source}';")
        sql(f"update app_private.pipeline_papers set claim_id='{claim}',generation=1,lease_until=clock_timestamp()+interval '10 minutes' where id='{shared}';select public.worker_pipeline_web_metadata('{shared}','{claim}',1,'{{\"title\":\"Race fixture\",\"authors\":[],\"categories\":[]}}',null,array['https://fixture.example/paper.pdf'],null);select public.worker_pipeline_split_private('{shared}','{claim}',1);select public.worker_pipeline_sync_imports('{shared}','{claim}',1);select public.worker_pipeline_release('{shared}','{claim}',1);")
        paper=sql(f"select id from app_private.pipeline_papers where owner_id='{owner}' and source_id='{source}';")
        return imported,paper
    def ready_import(owner,imported,revision=1):
        upload,send=ident(),ident()
        sql(f"select public.worker_begin_pdf_upload('{owner}','{upload}',{sha},1000,array[{sha}],'import','{imported}',{revision});")
        sql(write(owner,upload,send));sql(written(send));sql(freeze(owner,upload))
        return upload,send
    def claim_only(paper):
        claim=ident()
        sql(f"select public.worker_set_pipeline_enabled(true);update app_private.pipeline_papers set next_attempt_at=clock_timestamp()+interval '1 hour' where id<>'{paper}';update app_private.pipeline_papers set next_attempt_at=clock_timestamp() where id='{paper}';select 1;")
        result=json.loads(sql(f"select public.worker_pipeline_claim('{claim}');"))
        assert result['id']==paper,result
        return claim,result

    previous_import_limit=sql('select environment_active_imports from app_private.library_policy;')
    try:
        sql('update app_private.library_policy set environment_active_imports=10000; select 1;')
        sql("update app_private.paper_asset_policy set enforced=true,inventory_verified_at=clock_timestamp(),inventory_scope=2; select public.worker_pdf_upload_policy(true);")
        # Different account locks cannot independently spend the same remaining
        # environment headroom. The global capacity mutex commits only one.
        owners = [account(),account()]; uploads = [ident(),ident()]
        baseline=int(sql("select (select coalesce(sum(byte_count),0) from app_private.stored_objects where bucket in ('paper-assets','paper-uploads') and state<>'deleted')+(select coalesce(sum(bytes),0) from app_private.paper_asset_holds)+(select coalesce(sum(bytes),0) from app_private.pdf_upload_holds);"))
        sql(f'update app_private.paper_storage_capacity set max_bytes={baseline+159908840}; select 1;')
        barrier, first, second = Session(), Session(), Session()
        barrier.complete('begin; select singleton from app_private.paper_storage_capacity for update;')
        one = first.send(attempt(begin(owners[0], uploads[0]))); blocked(first, barrier)
        two = second.send(attempt(begin(owners[1], uploads[1]))); blocked(second, first)  # request counter is also serialized
        barrier.complete('commit;')
        results = [json.loads(first.until(one)[-1]),json.loads(second.until(two)[-1])]
        assert sum(r.get('state')=='receiving' for r in results)==1, results
        assert sum(r.get('error')=='paper_storage_capacity' for r in results)==1, results
        assert sql('select sum(bytes) from app_private.pdf_upload_holds;')=='159908840'
        sql('update app_private.paper_storage_capacity set max_bytes=5368709120; select 1;')
        print('PASS concurrent accounts cannot overbook common staging + future pipeline capacity',flush=True)

        owner, upload, send = account(), ident(), ident(); sql(begin(owner,upload))
        writer, closer = Session(),Session()
        writer.complete('begin; '+write(owner,upload,send)+';')
        closing = closer.send(f"select public.worker_delete_account_begin('{owner}');")
        blocked(closer,writer); writer.complete('commit;')
        result=json.loads(closer.until(closing)[-1]); assert result['blocked']=='asset_write_uncertain' and result['objects']==[],result
        rejected=json.loads(closer.complete(attempt(write(owner,upload,ident())))[-1]); assert rejected['error']=='account_unavailable',rejected
        sql(written(send)); result=json.loads(sql(f"select public.worker_delete_account_begin('{owner}');")); assert len(result['objects'])==1,result
        sql(f"select public.worker_delete_account_finish('{owner}');")
        print('PASS write-before-closure commits liability and prevents deletion until the real send terminates',flush=True)

        owner, upload = account(),ident();sql(begin(owner,upload))
        closing, pending = Session(),Session()
        closing.complete(f"begin; select public.worker_delete_account_begin('{owner}');")
        waiting=pending.send(attempt(write(owner,upload,ident())));blocked(pending,closing)
        closing.complete('commit;'); result=json.loads(pending.until(waiting)[-1]);assert result['error']=='account_unavailable',result
        assert sql(f"select count(*) from app_private.pdf_upload_write_attempts where upload_id='{upload}';")=='0'
        print('PASS closure-before-write admits no physical grant after waiting on the account',flush=True)

        # Duplicate delivery of one attempt ID returns exactly one true grant;
        # the second caller cannot turn a lost first acknowledgment into a PUT.
        owner, upload, send = account(),ident(),ident();sql(begin(owner,upload))
        first, second = Session(),Session();first.complete('begin; '+write(owner,upload,send)+';')
        waiting=second.send(write(owner,upload,send)+';');blocked(second,first);first.complete('commit;')
        result=json.loads(second.until(waiting)[-1]);assert result['write'] is False and result['uncertain'] is True,result
        assert sql(f"select count(*) from app_private.pdf_upload_write_attempts where upload_id='{upload}';")=='1'
        sql(written(send))
        print('PASS simultaneous replay of a write attempt cannot create two physical sends',flush=True)

        # A verified selection is frozen while another request has already
        # buffered a replacement body. Its later write check must fail closed.
        descriptor(owner,upload)
        freezer, replacement = Session(),Session()
        freezer.complete('begin; '+freeze(owner,upload)+';')
        waiting=replacement.send(attempt(write(owner,upload,ident())));blocked(replacement,freezer)
        freezer.complete('commit;');result=json.loads(replacement.until(waiting)[-1]);assert result['error']=='upload_not_receiving',result
        print('PASS freeze prevents a previously buffered chunk from creating a late physical grant',flush=True)

        # Attachment first: cancellation sees the committed exact import and
        # must not release holds needed by that worker.
        attaching, cancellation=Session(),Session()
        attaching.complete('begin; '+attach(owner,upload)+';')
        waiting=cancellation.send(attempt(f"select public.worker_cancel_pdf_upload('{owner}','{upload}',1)"));blocked(cancellation,attaching)
        attaching.complete('commit;');result=json.loads(cancellation.until(waiting)[-1]);assert result['error']=='upload_already_attached',result
        assert sql(f"select count(*) from app_private.pdf_upload_holds where upload_id='{upload}';")=='3'
        assert sql(f"select bound_import_id='{upload}' and bound_intent_revision=1 from app_private.pdf_uploads where id='{upload}';")=='t'
        print('PASS attach-before-cancel preserves exact source binding and future worker capacity',flush=True)

        # Cancellation first: attachment cannot create an import after cleanup
        # has retired the frozen session, even if its initial request was valid.
        owner=account();upload,_=ready(owner);sql(freeze(owner,upload))
        cancelling, attaching=Session(),Session()
        cancelling.complete(f"begin; select public.worker_cancel_pdf_upload('{owner}','{upload}',1);")
        waiting=attaching.send(attempt(attach(owner,upload)));blocked(attaching,cancelling)
        cancelling.complete('commit;');result=json.loads(attaching.until(waiting)[-1]);assert result['error']=='upload_not_frozen',result
        assert sql(f"select count(*) from app_private.import_requests where id='{upload}';")=='0'
        assert sql(f"select count(*) from app_private.pdf_upload_holds where upload_id='{upload}';")=='0'
        assert sql(f"select count(*) from app_private.stored_objects where owner_id='{owner}' and state<>'deleted';")=='1'
        print('PASS cancel-before-attach prevents import revival while preserving physical object liability',flush=True)

        # A worker waits for attachment's account lock, then atomically moves
        # the same future holds. No intermediate state is free or double-billed.
        owner=account();upload,_=ready(owner);sql(freeze(owner,upload));sql(attach(owner,upload))
        paper=sql(f"select id from app_private.pipeline_papers where source_id='upload:{upload}';");claim=ident()
        sql(f"update app_private.pipeline_papers set claim_id='{claim}',generation=1,lease_until=clock_timestamp()+interval '10 minutes' where id='{paper}';select 1;")
        before=int(sql(f"select sum(bytes) from app_private.pdf_upload_holds where upload_id='{upload}';"))
        transferring, cleanup=Session(),Session()
        transferring.complete(f"begin; select public.worker_pipeline_admit_download('{paper}','{claim}',1);")
        # Force stale threshold while the worker owns the account/paper/session.
        # The janitor still rechecks a live bound intent and retains the session.
        transferring.complete(f"update app_private.pdf_uploads set finalized_at=clock_timestamp()-interval '8 days' where id='{upload}';")
        waiting=cleanup.send('select public.worker_claim_stale_pdf_uploads(50);')
        transferring.complete('commit;');cleanup.until(waiting)
        assert sql(f"select state from app_private.pdf_uploads where id='{upload}';")=='checking'
        assert sql(f"select count(*) from app_private.pdf_upload_holds where upload_id='{upload}';")=='0'
        assert int(sql(f"select sum(bytes) from app_private.paper_asset_holds where paper_id='{paper}';"))==before
        print('PASS admitted worker retains exact session and all future capacity across janitor execution',flush=True)

        # The actual claim snapshot has no supplied bytes. Finalization commits
        # while the next admission waits on its owner lock; the admission must
        # return the committed descriptor, not preserve the claim's old source.
        owner=account();imported,paper=web(owner);claim,snapshot=claim_only(paper)
        assert snapshot['upload'] is None,snapshot
        upload,_=ready_import(owner,imported)
        attaching,admitting=Session(),Session()
        attaching.complete('begin;'+attach(owner,upload)+';')
        waiting=admitting.send(f"select public.worker_pipeline_admit_download('{paper}','{claim}',{snapshot['generation']});")
        blocked(admitting,attaching);attaching.complete('commit;')
        result=json.loads(admitting.until(waiting)[-1]);assert result['upload']['id']==upload and result['upload']['generation']==1,result
        assert sql(f"select upload_id='{upload}' and upload_generation=1 from app_private.pipeline_papers where id='{paper}';")=='t'
        assert sql(f"select count(*) from app_private.pdf_upload_holds where upload_id='{upload}';")=='0'
        print('PASS attachment after an actual claim snapshot but before admission selects exactly the supplied PDF',flush=True)

        # Reverse order: a web GET is already authorized. Finalize must leave
        # its frozen selection/holds intact and never redirect that physical
        # attempt to bytes it did not admit. Replay after release may attach.
        owner=account();imported,paper=web(owner);claim,snapshot=claim_only(paper);upload,_=ready_import(owner,imported)
        admitting,attaching=Session(),Session()
        admitted=json.loads(admitting.complete(f"begin;select public.worker_pipeline_admit_download('{paper}','{claim}',{snapshot['generation']});")[-1]);assert admitted['upload'] is None
        waiting=attaching.send(attempt(attach(owner,upload)));blocked(attaching,admitting);admitting.complete('commit;')
        result=json.loads(attaching.until(waiting)[-1]);assert result['error']=='upload_target_busy',result
        assert sql(f"select state||':'||(select count(*) from app_private.pdf_upload_holds where upload_id=u.id) from app_private.pdf_uploads u where id='{upload}';")=='frozen:3'
        sql(f"select public.worker_pipeline_release('{paper}','{claim}',{snapshot['generation']});")
        sql(attach(owner,upload))
        print('PASS already-admitted web download defers supplied attachment without losing its selection or capacity',flush=True)

        # The frozen target revision is immutable across the saga. A cancel
        # that wins the account lock invalidates attachment without a new import.
        owner=account();imported,paper=web(owner);upload,_=ready_import(owner,imported)
        cancelling,attaching=Session(),Session()
        cancelling.complete(f"select set_config('request.jwt.claim.sub','{owner}',false);begin;select public.v2_cancel_import(gen_random_uuid(),'{imported}',1);")
        waiting=attaching.send(attempt(attach(owner,upload)));blocked(attaching,cancelling);cancelling.complete('commit;')
        result=json.loads(attaching.until(waiting)[-1]);assert result['error']=='upload_target_unavailable',result
        assert sql(f"select count(*) from app_private.import_requests where account_id='{owner}';")=='1'
        assert sql(f"select state from app_private.pdf_uploads where id='{upload}';")=='frozen'
        print('PASS cancel of an exact frozen import intent prevents attachment from substituting a newer intent',flush=True)

        # The second janitor captured the old eligible state, but waits on
        # the first issuer's owner lock. It must recheck committed pacing and
        # never treat a lost Storage acknowledgment as confirmed deletion.
        owner,upload,send=account(),ident(),ident()
        sql(begin(owner,upload));sql(write(owner,upload,send));sql(written(send))
        sql(f"update app_private.pdf_uploads set expires_at=clock_timestamp()-interval '1 minute' where id='{upload}';select 1;")
        first,second=Session(),Session()
        batches=json.loads(first.complete('begin;select public.worker_claim_stale_pdf_uploads(50);')[-1])
        batch=next(b for b in batches if any(o['path'].startswith(f'{owner}/{upload}/') for o in b['objects']))
        waiting=second.send('select public.worker_claim_stale_pdf_uploads(50);');blocked(second,first)
        first.complete('commit;');assert json.loads(second.until(waiting)[-1])==[]
        assert sql(f"select sum(byte_count)=1000 from app_private.stored_objects where owner_id='{owner}' and state='deleting';")=='t'
        assert sql(f"select public.worker_confirm_pdf_uploads_deleted('{batch['batch_id']}');")=='1'
        assert sql(f"select public.worker_confirm_pdf_uploads_deleted('{batch['batch_id']}');")=='0'
        print('PASS concurrent janitor rechecks committed pacing after its owner wait and retains bytes until confirmation',flush=True)

        # Actual first-append RPC is paused on the environment counter. Closure
        # used to hold account FOR UPDATE while waiting for this keyring; the
        # append then needed the account FK for its first counter, deadlocking.
        owner=account();device=ident();event=ident()
        sql(f"select set_config('request.jwt.claim.sub','{owner}',false); select public.v1_bootstrap_keys('{device}',decode(repeat('21',32),'hex'),decode(repeat('22',60),'hex'),decode(repeat('23',32),'hex'),decode(repeat('24',60),'hex'),decode(repeat('25',32),'hex'));")
        assert sql(f"select count(*) from app_private.sync_account_storage where account_id='{owner}';")=='0'
        environment,appending,closing=Session(),Session(),Session()
        environment.complete('begin;select singleton from app_private.sync_environment_storage for update;')
        appending.complete(f"select set_config('request.jwt.claim.sub','{owner}',false);")
        appended=appending.send(f"select public.v1_append_event('{device}','{event}',1,1,decode(repeat('26',28),'hex'),decode(repeat('23',32),'hex'));")
        blocked(appending,environment)
        closed=closing.send(f"select public.worker_delete_account_begin('{owner}');");blocked(closing,appending)
        environment.complete('commit;');assert appending.until(appended)[-1]=='1';closing.until(closed)
        assert sql(f"select count(*) from app_private.sync_events where account_id='{owner}';")=='0'
        assert sql(f"select count(*) from app_private.sync_account_storage where account_id='{owner}';")=='0'
        print('PASS actual first-history-append and closure cannot invert keyring/account FK locks',flush=True)

        # Closure-first append sees the post-wait closed row and creates no
        # event/counter after personal erasure.
        owner=account();device=ident()
        sql(f"select set_config('request.jwt.claim.sub','{owner}',false); select public.v1_bootstrap_keys('{device}',decode(repeat('21',32),'hex'),decode(repeat('22',60),'hex'),decode(repeat('23',32),'hex'),decode(repeat('24',60),'hex'),decode(repeat('25',32),'hex'));")
        closing,appending=Session(),Session()
        closing.complete(f"begin;select public.worker_delete_account_begin('{owner}');")
        appending.complete(f"select set_config('request.jwt.claim.sub','{owner}',false);")
        appended=appending.send(attempt(f"select to_jsonb(public.v1_append_event('{device}',gen_random_uuid(),1,1,decode(repeat('26',28),'hex'),decode(repeat('23',32),'hex')))") )
        blocked(appending,closing);closing.complete('commit;');result=json.loads(appending.until(appended)[-1]);assert result['error']=='account_unavailable',result
        assert sql(f"select count(*) from app_private.sync_account_storage where account_id='{owner}';")=='0'
        print('PASS closure-first history append rejects after its account-lock wait without recreating data',flush=True)

        # Concurrent edits of one encrypted title cannot both win the same CAS.
        # Public RPCs validate current authority and serialize account/keyring.
        owner=account();device=ident();descriptor_id=ident();source='2410.03988'
        sql(f"select set_config('request.jwt.claim.sub','{owner}',false); select public.v1_bootstrap_keys('{device}',decode(repeat('21',32),'hex'),decode(repeat('22',60),'hex'),decode(repeat('23',32),'hex'),decode(repeat('24',60),'hex'),decode(repeat('25',32),'hex')); select public.v2_begin_import(gen_random_uuid(),'{source}',0);")
        def edit(rev,mutation):
            envelope=f"jsonb_build_object('descriptor_id','{descriptor_id}','revision',{rev},'mutation_id','{mutation}','device_id','{device}','epoch',1,'format',1,'ciphertext',replace(encode(decode(repeat('11',28),'hex'),'base64'),E'\\n',''),'sha256',encode(sha256(decode(repeat('11',28),'hex')),'hex'))"
            return f"select public.v1_put_library_descriptor('{source}',{rev-1},'{device}',decode(repeat('23',32),'hex'),{envelope})"
        sql(f"select set_config('request.jwt.claim.sub','{owner}',false);"+edit(1,ident()))
        first,second=Session(),Session()
        for session in (first,second):session.complete(f"select set_config('request.jwt.claim.sub','{owner}',false);")
        first.complete('begin;'+edit(2,ident())+';')
        waiting=second.send(edit(2,ident())+';');blocked(second,first);first.complete('commit;')
        result=json.loads(second.until(waiting)[-1]);assert result['result']['status']=='revision_conflict',result
        assert result['result']['reference']['revision']==2
        assert sql(f"select count(*)||':'||max(revision) from app_private.library_descriptors where account_id='{owner}';")=='1:2'
        print('PASS concurrent encrypted descriptor mutations preserve exactly one CAS winner',flush=True)
    finally:
        for session in sessions: session.close()
        sql(f'update app_private.library_policy set environment_active_imports={previous_import_limit}; select 1;')
