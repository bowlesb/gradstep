"""Verify populated pre-034 holds survive the provider accounting upgrade.

Uses a fresh disposable loopback database, real credit reservations and valid
historical OCR/tag rows. No network provider or hosted database is contacted.
"""
import json
import os
import pathlib
import subprocess
import uuid


def verify(bin_path, db, base, root):
    if list(base) != ['-h', '127.0.0.1', '-p', '55431'] or not db.startswith('science_reader_test_'):
        raise ValueError('Disposable loopback database required')
    target = db + '_provider_upgrade'
    if len(target) > 63 or not all(c.isalnum() or c == '_' for c in target):
        raise ValueError('Invalid disposable database name')
    env = {key: value for key, value in os.environ.items() if not key.startswith('PG')}

    def run(binary, args, **kwargs):
        return subprocess.run([str(bin_path / binary), *base, *args], env=env, check=True, **kwargs)

    def sql(source):
        result = run('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', target], input=source,
                     text=True, capture_output=True, timeout=30)
        return result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ''

    def budget():
        return json.loads(sql("select jsonb_build_array(spent_microusd,reserved_microusd) from app_private.platform_budgets "
                              "where period=date_trunc('month',now() at time zone 'UTC')::date;"))

    account, claim, paper, document, run_id, attempt, operation, tag_operation = [str(uuid.uuid4()) for _ in range(8)]
    run('createdb', [target])
    try:
        sql((root / 'tests/database/bootstrap.sql').read_text())
        for migration in sorted((root / 'supabase/migrations').glob('*.sql')):
            if migration.name >= '202610070034':
                break
            sql(migration.read_text())
        sql(f"""insert into auth.users values('{account}');
          set role service_role;
          select public.worker_set_platform_budget(date_trunc('month',now() at time zone 'UTC')::date,1000000,true);
          select public.worker_grant_credits('{account}','adjustment','provider-upgrade',100,now()-interval '1 day',null,'Fixture');
          select public.worker_reserve_operation('{account}','{operation}','ocr',sha256('ocr-upgrade'),'beta-credits-v1',4,20000);
          select public.worker_mark_submitted('{account}','{operation}');
          select public.worker_reserve_operation('{account}','{tag_operation}','metadata',sha256('tag-upgrade'),'beta-credits-v1',0,10000);
          select public.worker_mark_submitted('{account}','{tag_operation}');
          reset role;
          insert into app_private.documents(id,sha256,scope,reuse_evidence,byte_count,page_count)
            values('{document}',sha256('upgrade-pdf'),'shared_catalog','{{"fixture":true}}',1000,4);
          insert into app_private.ocr_runs(id,document_id,provider,options_sha256)
            values('{run_id}','{document}','mathpix',sha256('upgrade-options'));
          insert into app_private.pipeline_papers(id,source_id,document_id,page_count,ocr_run_id,stage,claim_id,lease_until,generation)
            values('{paper}','2410.03401','{document}',4,'{run_id}','ocr_wait','{claim}',now()+interval '5 minutes',1);
          insert into app_private.ocr_attempts(id,paper_id,document_id,ocr_run_id,funder_account_id,operation_id,page_limit,state,provider_job_id,submitted_at)
            values('{attempt}','{paper}','{document}','{run_id}','{account}','{operation}',4,'submitted','upgrade_pdf_job',now());
          set role service_role;
          select public.worker_record_arxiv_metadata('2410.03401',1,'{{"title":"Upgrade fixture","authors":[],"categories":["cs.LG"]}}');
          reset role;
          insert into app_private.catalog_tags(version_id,claim_id,lease_until,operation_account_id,operation_id)
            select version_id,'{claim}',now()+interval '5 minutes','{account}','{tag_operation}'
            from app_private.catalog_metadata where id=(select id from app_private.catalog_metadata order by recorded_at desc limit 1);
        """)
        before = budget()
        assert before == [0, 30000], before
        sql((root / 'supabase/migrations/202610070034_provider_accounting.sql').read_text())
        assert budget() == before, 'Migration must not release or double-reserve existing money'
        mirrored = json.loads(sql("select jsonb_agg(jsonb_build_object('state',state,'reason',failure_code,'cap',ceiling_microusd) order by provider) "
                                  "from app_private.provider_attempts;"))
        assert mirrored == [
            {'state': 'unknown', 'reason': 'pre_accounting_tag_claim', 'cap': 10000},
            {'state': 'unknown', 'reason': 'pre_accounting_submission', 'cap': 20000}], mirrored
        assert sql("select bool_and(attempt_accounting) from app_private.metered_operations;") == 't'
        replay = json.loads(sql(f"set role service_role; select public.worker_provider_attempt_begin('{account}','{operation}','{attempt}',"
                                "'mathpix','paper_ocr','v3/pdf',sha256('ocr-upgrade'),20000,'{\"pages\":4}');"))
        assert replay['granted'] is False, 'A historical submission never becomes a new POST grant'

        # A customer refund leaves both unknown vendor holds intact.
        sql(f"set role service_role; select public.worker_settle_operation('{account}','{operation}',0,0); "
            f"select public.worker_settle_operation('{account}','{tag_operation}',0,0);")
        assert budget() == [0, 30000]
        assert sql(f"select sum(provider_liability_microusd) from app_private.metered_operations where account_id='{account}';") == '30000'

        # Late usage releases each corresponding hold exactly once. The original
        # immutable customer settlement and credit refund remain unchanged.
        finish = (f"set role service_role; select public.worker_provider_attempt_finish('{account}','{operation}','{attempt}',"
                  "'succeeded','upgrade_pdf_job',15000,'{\"pages\":3}',null);")
        sql(finish)
        assert budget() == [15000, 10000]
        sql(finish)
        assert budget() == [15000, 10000], 'Late callback replay double-counted cost'
        sql(f"set role service_role; select public.worker_provider_attempt_finish('{account}','{tag_operation}','{tag_operation}',"
            "'succeeded','upgrade_tag_response',3000,'{\"input_tokens\":900,\"output_tokens\":20}',null);")
        assert budget() == [18000, 0]
        assert sql(f"select sum(actual_credits) from app_private.metered_operations where account_id='{account}';") == '0'
        assert sql("select count(*) from app_private.provider_usage_events;") == '2'
        print('PASS provider upgrade: historical OCR/tag submissions stay quarantined, holds unchanged, refunds preserve liability, late usage exactly once', flush=True)
    except subprocess.CalledProcessError as error:
        raise AssertionError(error.stderr or error.stdout or str(error)) from error
    finally:
        run('dropdb', ['--force', target])


if __name__ == '__main__':
    root = pathlib.Path(__file__).resolve().parents[2]
    binaries = pathlib.Path(os.environ.get('SCIENCE_READER_PG_BIN',
        '/Users/benbowlwes/textbrain/scripts/.pgtools/postgresql-18.4.0-aarch64-apple-darwin/bin'))
    verify(binaries, 'science_reader_test_' + uuid.uuid4().hex[:12], ['-h', '127.0.0.1', '-p', '55431'], root)
