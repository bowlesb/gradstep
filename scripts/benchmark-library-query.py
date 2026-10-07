#!/usr/bin/env python3
"""Disposable, synthetic library v4 query microbenchmark; never a capacity change.

Uses only 127.0.0.1:55431 and a newly generated science_reader_test_* database.
The 10k/50k fixtures are trusted read-model rows, not imports through product
quotas. No production policy, migration source, or existing database is edited.
Run: python3 scripts/benchmark-library-query.py [--samples 3]
"""

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import platform
import re
import statistics
import subprocess
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE = ['-h', '127.0.0.1', '-p', '55431']
BIN = pathlib.Path(os.environ.get('SCIENCE_READER_PG_BIN',
    '/Users/benbowlwes/textbrain/scripts/.pgtools/postgresql-18.4.0-aarch64-apple-darwin/bin'))
ENV = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
ENV['PGPASSFILE'] = os.devnull
QUERY_BUDGET_MS = 5000
PAGE_BUDGET_BYTES = 1048576
CATALOG_ROWS = 5000
MAX_METADATA_BYTES = 32768
WORDS = 'neural attention graph embeddings transformers diffusion tokens optimizer gradient tensor loss dropout batch normalization learning probability'


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def json_literal(value):
    return literal(json.dumps(value, ensure_ascii=False)) + '::jsonb'


def ident(value):
    if not re.fullmatch(r'science_reader_test_[0-9a-f]{12}_query_bench', value):
        raise ValueError('Refusing a non-disposable database name')
    return '"' + value + '"'


FIXTURE_SQL = r"""
create schema bench_local;
create function bench_local.id(label text,n integer) returns uuid language sql immutable as $$
 select md5(label||':'||n::text)::uuid
$$;
-- Deterministic, moderately incompressible filler avoids measuring only repeated
-- characters. These hashes have no relationship to real papers or user content.
create function bench_local.filler(seed integer,n integer) returns text language sql immutable as $$
 select left(string_agg(md5(seed::text||':'||i::text),'' order by i),n)
 from generate_series(1,(n+31)/32) i
$$;
create function bench_local.metadata(n integer) returns jsonb language plpgsql as $$
declare m jsonb; t text; authors jsonb; wanted integer; prefix text;
begin
 prefix:='neural attention graph embeddings transformers diffusion tokens optimizer gradient tensor loss dropout batch normalization learning probability ';
 if n%97=0 then prefix:=prefix||'quux9needle '; end if;
 if n%233=0 then prefix:=prefix||'100% _literal back\slash '; end if;
 t:=case when n%5=0 then repeat('X',64)||' '||lpad((5001-n)::text,5,'0')||' collision'
  else 'Research '||lpad(n::text,5,'0')||' attention and graph learning' end;
 if n%10=0 then
  t:=left(t||bench_local.filler(n,2000),1900);
  select jsonb_agg('Author '||lpad(i::text,3,'0')||' '||bench_local.filler(n+i,90) order by i)
   into authors from generate_series(1,64) i;
 else authors:=jsonb_build_array('Author One','Author Two','Author Three','Author Four'); end if;
 m:=jsonb_build_object('title',t,'authors',authors,'categories',jsonb_build_array('cs.LG','cs.AI'),
  'venue',case when n%10=0 then bench_local.filler(n,512) else 'Synthetic ML Conference' end,
  'published_at',case when n%13=0 then null else (1995+n%31)::text||'-01-03' end,'abstract','');
 m:=jsonb_set(m,'{abstract}',to_jsonb(prefix));
 wanted:=case when n%10=0 then 32768-octet_length(m::text) else 1450-length(prefix) end;
 if wanted<0 or wanted+length(prefix)>24000 then raise exception 'invalid synthetic abstract budget %',wanted; end if;
 m:=jsonb_set(m,'{abstract}',to_jsonb(prefix||bench_local.filler(n,wanted)));
 perform app_private.check_catalog_metadata(m);
 if n%10=0 and octet_length(m::text)<>32768 then raise exception 'max metadata not exact'; end if;
 return m;
end $$;

create table bench_local.metadata_seed as
 select n,bench_local.id('metadata',n) metadata_id,bench_local.id('version',n) version_id,
  bench_local.id('publication',n) publication_id,'2410.'||lpad(n::text,5,'0') source_id,
  bench_local.metadata(n) metadata from generate_series(1,5000) n;
insert into app_private.publications(id,title) select publication_id,metadata->>'title' from bench_local.metadata_seed;
insert into app_private.publication_versions(id,publication_id,source,revision)
 select version_id,publication_id,'arxiv','1' from bench_local.metadata_seed;
insert into app_private.catalog_metadata(id,version_id,source_id,source_revision,metadata,metadata_sha256)
 select metadata_id,version_id,source_id,1,metadata,sha256(convert_to(metadata::text,'UTF8')) from bench_local.metadata_seed;

create function bench_local.measure(q jsonb,c jsonb) returns jsonb language plpgsql as $$
declare started timestamptz; page jsonb; bytes integer; elapsed numeric;
begin
 started:=clock_timestamp(); page:=public.v4_library_query(q,c,50); bytes:=octet_length(page::text);
 elapsed:=extract(epoch from clock_timestamp()-started)*1000;
 return jsonb_build_object('server_rpc_and_json_ms',elapsed,'response_bytes',bytes,
  'rows',jsonb_array_length(page->'rows'),'has_more',page->'has_more','next_cursor',page->'next_cursor',
  'ids',coalesce((select jsonb_agg(x->'state'->>'id') from jsonb_array_elements(page->'rows') x),'[]'::jsonb));
end $$;
grant usage on schema bench_local to authenticated;
grant execute on function bench_local.measure(jsonb,jsonb) to authenticated;
"""


def fixture_rows(account, label, start, end, all_visible=False):
    return f"""insert into app_private.library_v4_entries(account_id,kind,id,created_seq,state_seq,metadata_id,entry)
    select {literal(account)}::uuid,'item',bench_local.id({literal(label)},i),i,i,m.metadata_id,
     jsonb_build_object('kind','item','id',bench_local.id({literal(label)},i),'created_seq',i,'state_seq',i,
      'metadata_id',m.metadata_id,'visible',{'true' if all_visible else 'i%20<>0'},'archived',{'false' if all_visible else 'i%10=1'},'source','arxiv','source_id',m.source_id,
      'source_revision',1,'document_id',bench_local.id({literal(label + '-document')},i),'version_id',m.version_id,
      'approval_id',bench_local.id({literal(label + '-approval')},i),'membership_revision',1,'last_remove_seq',0,
      'added_at','2026-10-07T00:00:00Z','metadata_recorded_at','2026-10-07T00:00:00Z',
      'source_url','https://arxiv.org/abs/'||m.source_id||'v1','scope','shared_catalog','page_count',16,
      'original_object_id',bench_local.id({literal(label + '-object')},i),'artifact_id',null,
      'readiness','pdf_ready','original_availability','available','render_availability','unverified',
      'original_availability_revision',1,'render_availability_revision',0,
      'tags',jsonb_build_array(case when m.n%5=0 then 'Collision' else 'Machine learning' end),
      'user_tags',jsonb_build_array('Reading group'))
    from generate_series({start},{end}) i join bench_local.metadata_seed m on m.n=1+(i-1)%5000;
    update app_private.library_sync_state set last_seq={end} where account_id={literal(account)};
    """


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--samples', type=int, default=3, choices=range(1,11))
    parser.add_argument('--compare-variants', action='store_true', help='Also compare isolated private-function experiments inside the disposable DB')
    args = parser.parse_args()
    target = 'science_reader_test_' + uuid.uuid4().hex[:12] + '_query_bench'
    if BASE != ['-h', '127.0.0.1', '-p', '55431']:
        raise ValueError('Refusing a non-loopback or non-test port')
    ident(target)
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    artifact = ROOT / '.artifacts/library-v4-20261007' / ('query-benchmark-' + stamp)
    artifact.parent.mkdir(parents=True, exist_ok=True)
    sources = [ROOT/'tests/database/bootstrap.sql', *[p for p in sorted((ROOT/'supabase/migrations').glob('*.sql'))
        if p.name <= '202610070032_library_query.sql']]
    snapshots = [(p, p.read_text()) for p in sources]
    if not any(p.name == '202610070032_library_query.sql' for p, _ in snapshots):
        raise ValueError('Migration 032 source is required')
    report = {'started_at':stamp,'database':target,'endpoint':'127.0.0.1:55431',
        'conditions':{'platform':platform.platform(),'cpu_count':os.cpu_count(),'load_average_start':os.getloadavg(),
            'notes':['Shared developer machine; other Xcode work may be running. No absolute performance promise.',
                'Fresh populated DB with warm OS/PostgreSQL caches; not a cold-start benchmark.',
                'Server latency includes RPC and JSON size serialization, excludes HTTP and client rendering.',
                'Command wall latency includes a fresh psql process/loopback connection, but returns only measurement fields.',
                'Trusted synthetic read-model rows bypass creation quotas; policy values are unchanged.',
                '5000 metadata IDs repeat across retained entries; useful for query scaling, not a unique-paper distribution model.']},
        'budgets_before_run':{'each_server_query_ms':QUERY_BUDGET_MS,'each_command_wall_ms':QUERY_BUDGET_MS,
            'response_bytes':PAGE_BUDGET_BYTES,'statement_timeout_ms':20000},
        'samples_per_case':args.samples,'experimental_variants_requested':args.compare_variants,
        'sources':{str(p.relative_to(ROOT)):hashlib.sha256(s.encode()).hexdigest() for p,s in snapshots},
        'datasets':[],'cases':[],'plans':[],'failures':[],'cleanup':False}
    plan_logs = []
    created = False

    def binary(name, params, **kwargs):
        return subprocess.run([str(BIN/name),*BASE,'--no-password',*params],env=ENV,check=True,**kwargs)

    def sql(source, timeout=60, want_stderr=False):
        started = time.perf_counter()
        result = binary('psql',['-X','-qAt','-v','ON_ERROR_STOP=1','-d',target],
            input="set timezone='UTC'; set statement_timeout='20s'; set lock_timeout='5s';\n"+source,
            text=True,capture_output=True,timeout=timeout)
        return (result.stdout.strip(),result.stderr,(time.perf_counter()-started)*1000) if want_stderr else result.stdout.strip()

    def value(source, **kwargs):
        return sql(source,**kwargs).splitlines()[-1]

    def save():
        artifact.with_suffix('.json').write_text(json.dumps(report,indent=2)+'\n')
        artifact.with_name(artifact.name+'-plans.txt').write_text('\n\n'.join(plan_logs)+'\n')

    def storage():
        return json.loads(value("""select jsonb_agg(jsonb_build_object('table',c.relname,
         'table_and_toast_bytes',pg_table_size(c.oid),'index_bytes',pg_indexes_size(c.oid),
         'total_bytes',pg_total_relation_size(c.oid)) order by c.relname)
         from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='app_private'
          and c.relname in ('catalog_metadata','library_v4_entries','library_query_metadata','library_query_entries');"""))

    def execute_case(account, query, cursor=None, explain=False):
        prefix = ""
        if explain:
            prefix = """load 'auto_explain'; set auto_explain.log_min_duration=0;
             set auto_explain.log_nested_statements=on; set auto_explain.log_analyze=on;
             set auto_explain.log_buffers=on; set auto_explain.log_timing=off;
             set auto_explain.log_format='json'; set auto_explain.log_level='notice'; set client_min_messages='notice';"""
        cursor_sql = 'null' if cursor is None else json_literal(cursor)
        output, stderr, wall = sql(prefix+f"set role authenticated; select set_config('request.jwt.claim.sub',{literal(account)},false);"
            +f"select bench_local.measure({json_literal(query)},{cursor_sql});",timeout=30,want_stderr=True)
        result = json.loads(output.splitlines()[-1])
        result['command_wall_ms'] = round(wall,3)
        return result,stderr

    def reference(account, query, offset=0):
        # Independent full-title ordering reads the canonical metadata, without
        # the production 64-character prefix or precomputed title_key.
        sort = query.get('sort','recent')
        direction = query.get('direction','asc' if sort=='title' else 'desc')
        if sort=='title':
            order = f"app_private.library_search_normalize(cm.metadata->>'title') collate \"C\" {direction}"
        elif sort=='year':
            order = f"(cm.metadata->>'published_at' is null) asc,left(cm.metadata->>'published_at',4)::integer {direction}"
        else:
            order = 'q.created_seq '+direction
        where = f"q.account_id={literal(account)} and q.visible and not q.archived"
        if query.get('tag'):
            where += f" and {literal(query['tag'])}=any(q.effective_tags)"
        return json.loads(value(f"""select coalesce(jsonb_agg(id order by n),'[]'::jsonb) from (
          select q.id,row_number() over(order by {order},q.id {direction},q.kind {direction}) n
          from app_private.library_query_entries q join app_private.catalog_metadata cm on cm.id=q.metadata_id
          where {where} order by {order},q.id {direction},q.kind {direction} offset {offset} limit 50) rows;"""))

    def collect_plans(label, account, query, cursor=None):
        try:
            _, logs = execute_case(account,query,cursor,True)
            plan_logs.append(label+'\n'+logs)
            decoder = json.JSONDecoder()
            plans = []
            probes = []
            for match in re.finditer(r'plan:\s*\n?(\{)',logs):
                try:
                    parsed,_ = decoder.raw_decode(logs[match.start(1):])
                except json.JSONDecodeError:
                    continue
                if 'with candidates as materialized' in parsed.get('Query Text',''):
                    plans.append(parsed)
                if 'bounded_account' in parsed.get('Query Text','') and 'select count(*)<=50' in parsed.get('Query Text',''):
                    probes.append(parsed)
            def nodes(node):
                yield node
                for child in node.get('Plans',[]):
                    yield from nodes(child)
            observations = []
            for plan in plans:
                ns = list(nodes(plan['Plan']))
                observations.append({'top':{k:plan['Plan'].get(k) for k in ['Node Type','Actual Rows','Shared Hit Blocks',
                    'Shared Read Blocks','Temp Read Blocks','Temp Written Blocks']},
                    'scans':[{'node':n.get('Node Type'),'relation':n.get('Relation Name'),'index':n.get('Index Name'),
                        'rows':n.get('Actual Rows'),'loops':n.get('Actual Loops'),'removed':n.get('Rows Removed by Filter'),
                        'index_condition':n.get('Index Cond'),'filter':n.get('Filter')}
                        for n in ns if 'Scan' in n.get('Node Type','')],
                    'sorts':[{k:n.get(k) for k in ['Node Type','Sort Key','Sort Method','Sort Space Used','Sort Space Type']}
                        for n in ns if 'Sort' in n.get('Node Type','')]})
            report['plans'].append({'case':label,'candidate_plans':len(plans),'observations':observations,
                'small_library_probe_plans':probes})
        except (subprocess.CalledProcessError,subprocess.TimeoutExpired) as error:
            report['plans'].append({'case':label,'error':str(getattr(error,'stderr',None) or error)})
        save()

    def benchmark(label, account, query, cursor=None, expected=None):
        case = {'case':label,'query':query,'continuation':cursor is not None,'samples':[],'load_average':os.getloadavg()}
        report['cases'].append(case)
        for _ in range(args.samples):
            try:
                sample,_ = execute_case(account,query,cursor)
                sample['correct_order'] = None if expected is None else sample['ids']==expected
                if expected is not None and sample['correct_order'] is not True:
                    report['failures'].append(label+': full reference ordering mismatch')
                if sample['server_rpc_and_json_ms']>=QUERY_BUDGET_MS or sample['command_wall_ms']>=QUERY_BUDGET_MS:
                    report['failures'].append(label+': exceeds preregistered 5 s query budget')
                if sample['response_bytes']>PAGE_BUDGET_BYTES:
                    report['failures'].append(label+': response exceeds 1 MiB')
                case['samples'].append(sample)
            except (subprocess.CalledProcessError,subprocess.TimeoutExpired) as error:
                detail = str(getattr(error,'stderr',None) or error)
                case['samples'].append({'error':detail})
                report['failures'].append(label+': query failed '+detail[:300])
                break
        completed = [x for x in case['samples'] if 'server_rpc_and_json_ms' in x]
        if completed:
            case['summary'] = {'median_server_ms':statistics.median(x['server_rpc_and_json_ms'] for x in completed),
                'max_server_ms':max(x['server_rpc_and_json_ms'] for x in completed),
                'max_command_wall_ms':max(x['command_wall_ms'] for x in completed),
                'max_response_bytes':max(x['response_bytes'] for x in completed),'rows':completed[0]['rows']}
            print(label, json.dumps(case['summary']),flush=True)
        save()
        return completed[0] if completed else None

    try:
        print(f'Budgets fixed before run: each query <{QUERY_BUDGET_MS} ms; page <=1 MiB. Target {target}',flush=True)
        binary('createdb',[target],capture_output=True,text=True,timeout=30)
        created = True
        binary('psql',['-X','-qAt','-v','ON_ERROR_STOP=1','-d','postgres','-c',
            f'alter database {ident(target)} set timezone to \'UTC\''],capture_output=True,text=True,timeout=30)
        for path,source in snapshots:
            sql(source)
        report['postgres'] = json.loads(value("select jsonb_build_object('version',version(),'shared_buffers',current_setting('shared_buffers'),"
            "'work_mem',current_setting('work_mem'),'jit',current_setting('jit'),'search_version',app_private.library_search_version());"))
        report['policy_before'] = json.loads(value('select to_jsonb(p) from app_private.library_policy p;'))
        print('Schemas installed; seeding shared synthetic metadata',flush=True)
        sql("set statement_timeout='180s';"+FIXTURE_SQL,timeout=200)
        report['metadata'] = json.loads(value("select jsonb_build_object('rows',count(*),'encoded_bytes',sum(octet_length(metadata::text)),"
            "'max_encoded_bytes',max(octet_length(metadata::text)),'exact_32k_records',count(*) filter(where octet_length(metadata::text)=32768)) from app_private.catalog_metadata;"))
        assert report['metadata']['rows']==CATALOG_ROWS and report['metadata']['max_encoded_bytes']==MAX_METADATA_BYTES
        assert report['metadata']['encoded_bytes']<=report['policy_before']['metadata_bytes']
        accounts = {}
        for size in [20,50,51,10000,50000]:
            account = str(uuid.uuid5(uuid.NAMESPACE_URL,'timestep-library-query-benchmark-'+str(size)))
            accounts[size] = account
            sql(f'insert into auth.users(id) values({literal(account)});')
            started = time.perf_counter()
            for start in range(1,size+1,1000):
                sql("set statement_timeout='120s';"+fixture_rows(account,'account-'+str(size),start,min(start+999,size),size in [50,51]),timeout=140)
                if min(start+999,size)%10000==0:
                    print(f'Seeded {min(start+999,size)}/{size} retained entries',flush=True)
            sql('analyze app_private.catalog_metadata; analyze app_private.library_query_metadata; analyze app_private.library_v4_entries; analyze app_private.library_query_entries;')
            dataset = json.loads(value(f"""select jsonb_build_object('retained_entries',count(*),
              'visible',count(*) filter(where visible),'active',count(*) filter(where visible and not archived),
              'query_row_logical_bytes',sum(pg_column_size(q))) from app_private.library_query_entries q where account_id={literal(account)};"""))
            dataset.update({'account_id':account,'requested_size':size,'fixture_build_seconds':time.perf_counter()-started,'storage':storage()})
            report['datasets'].append(dataset)
            save()
        print('Running query cases; first samples are warm from fixture population, not cold-cache claims',flush=True)
        for size,account in accounts.items():
            for sort in ['recent','title','year']:
                query = {'sort':sort}
                first = benchmark(f'{size}/{sort}/first',account,query,expected=reference(account,query))
                if first and first['next_cursor']:
                    benchmark(f'{size}/{sort}/second',account,query,first['next_cursor'],reference(account,query,first['rows']))
                    # A deep anchor is reconstructed from a valid server-issued
                    # cursor header and independently ordered existing row ID.
                    # This is not a measurement of scrolling through all pages.
                    offset = size//2
                    cursor = dict(first['next_cursor'],id=reference(account,query,offset-1)[0],kind='item')
                    benchmark(f'{size}/{sort}/deep-{offset}',account,query,cursor,reference(account,query,offset))
                    if sort=='title' and size==50000:
                        collect_plans(f'{size}/{sort}/deep-{offset}',account,query,cursor)
                    if sort=='recent' and size==50000:
                        collect_plans(f'{size}/{sort}/second',account,query,first['next_cursor'])
                        collect_plans(f'{size}/{sort}/deep-{offset}',account,query,cursor)
            common_search_ids=reference(account,{})
            for name,query in [('and',{'text':'attention transformers'}),('rare',{'text':'quux9needle'}),
                ('no-match',{'text':'absenttokenzzzxxyy'}),('short-1',{'text':'a'}),('short-2',{'text':'ne'}),
                ('short-1-sparse',{'text':'q'}),('short-2-no-match',{'text':'zz'}),
                ('punctuation',{'text':'%'}),('worst-16',{'text':WORDS})]:
                expected=[] if name in ['no-match','short-2-no-match'] else common_search_ids if name in ['and','short-1','short-2','worst-16'] else None
                benchmark(f'{size}/search/{name}',account,query,expected=expected)
                if (size in [20,50000] and name in ['no-match','short-1','short-1-sparse','short-2-no-match','punctuation','worst-16']) or (size in [50,51] and name=='worst-16'):
                    collect_plans(f'{size}/search/{name}',account,query)
            for direction in ['asc','desc']:
                query = {'sort':'title','direction':direction,'tag':'Collision'}
                first = benchmark(f'{size}/prefix-collision/{direction}/first',account,query,expected=reference(account,query))
                if first and first['next_cursor']:
                    benchmark(f'{size}/prefix-collision/{direction}/second',account,query,first['next_cursor'],reference(account,query,first['rows']))
            if size==50000:
                collect_plans(f'{size}/recent/first',account,{'sort':'recent'})
                collect_plans(f'{size}/prefix-collision/asc',account,{'sort':'title','direction':'asc','tag':'Collision'})

        if args.compare_variants:
            # Query-only experiments in the disposable DB. Restore afterwards;
            # migration files and hosted function definitions remain untouched.
            definition=sql("select pg_get_functiondef('app_private.library_query_page(uuid,jsonb,jsonb,integer)'::regprocedure);")
            global_predicate="predicates:=predicates||format(' and (q.own_search like $2[%s] or q.metadata_id in (select sm.metadata_id from app_private.library_query_metadata sm where sm.search_text like $2[%s]))',j,j);"
            scoped_predicate="predicates:=predicates||format(' and (q.own_search like $2[%s] or m.search_text like $2[%s])',j,j);"
            if definition.count(global_predicate)!=1:
                raise AssertionError('Query source changed: refusing an ambiguous experiment rewrite')
            scoped_definition=definition.replace(global_predicate,scoped_predicate)
            report['experimental_variants']={'account_joined_search':hashlib.sha256(scoped_definition.encode()).hexdigest()}
            try:
                sql(scoped_definition)
                for size,account in accounts.items():
                    for name,query in [('and',{'text':'attention transformers'}),('rare',{'text':'quux9needle'}),
                        ('no-match',{'text':'absenttokenzzzxxyy'}),('worst-16',{'text':WORDS})]:
                        benchmark(f'joined-variant/{size}/search/{name}',account,query,expected=[] if name=='no-match' else None)
                        if size in [20,50000] and name in ['no-match','worst-16']:
                            collect_plans(f'joined-variant/{size}/search/{name}',account,query)
                marker="comparison:=case when direction='asc' then '>' else '<' end;"
                if definition.count(marker)!=1:
                    raise AssertionError('Query source changed: refusing an ambiguous title experiment rewrite')
                coarse_definition=definition.replace(marker,marker+"\n  if spec->>'sort'='title' and direction='asc' then\n   predicates:=predicates||' and (q.title_missing,q.title_prefix)>=($5,$6)';\n  end if;")
                report['experimental_variants']['coarse_title_asc']=hashlib.sha256(coarse_definition.encode()).hexdigest()
                sql(coarse_definition)
                for size in [10000,50000]:
                    account=accounts[size]
                    query={'sort':'title'}
                    first,_=execute_case(account,query)
                    offset=size//2
                    cursor=dict(first['next_cursor'],id=reference(account,query,offset-1)[0],kind='item')
                    benchmark(f'coarse-title-variant/{size}/deep-{offset}',account,query,cursor,reference(account,query,offset))
                    collect_plans(f'coarse-title-variant/{size}/deep-{offset}',account,query,cursor)
            finally:
                sql(definition)
        report['policy_after'] = json.loads(value('select to_jsonb(p) from app_private.library_policy p;'))
        if report['policy_after']!=report['policy_before']:
            report['failures'].append('Product policy changed during benchmark')
        report['final_storage'] = storage()
        report['index_sizes'] = json.loads(value("""select jsonb_agg(jsonb_build_object('table',relname,'index',indexrelname,
          'bytes',pg_relation_size(indexrelid),'scan_count',idx_scan) order by relname,indexrelname)
          from pg_stat_user_indexes where schemaname='app_private'
           and relname in ('catalog_metadata','library_v4_entries','library_query_metadata','library_query_entries');"""))
    except Exception as error:
        report['failures'].append(str(getattr(error,'stderr',None) or error))
        print('BENCHMARK ERROR:',report['failures'][-1],flush=True)
    finally:
        if created:
            try:
                binary('dropdb',['--force',target],capture_output=True,text=True,timeout=30)
                report['cleanup'] = True
            except Exception as error:
                report['failures'].append('Cleanup failed: '+str(error))
        report['finished_at'] = dt.datetime.now(dt.timezone.utc).isoformat()
        report['conditions']['load_average_end'] = os.getloadavg()
        report['failures'] = list(dict.fromkeys(report['failures']))
        save()
        lines = ['# Local library-query microbenchmark','',f"Run: {stamp}; disposable DB cleaned: {report['cleanup']}.",'',
            'Synthetic read-model scaling only. Existing product quotas unchanged. Shared developer machine; warm caches; no production latency promise.',
            '',f'Preregistered limits: each query <{QUERY_BUDGET_MS} ms, each page ≤{PAGE_BUDGET_BYTES} bytes. {args.samples} samples per case.','',
            '| Case | Rows | Median server ms | Maximum server ms | Maximum command ms | Page bytes |',
            '|---|---:|---:|---:|---:|---:|']
        for case in report['cases']:
            if 'summary' in case:
                s=case['summary']
                lines.append(f"| {case['case']} | {s['rows']} | {s['median_server_ms']:.2f} | {s['max_server_ms']:.2f} | {s['max_command_wall_ms']:.2f} | {s['max_response_bytes']} |")
        lines += ['','Failures:']+[f'- {failure}' for failure in report['failures'] or ['None.']]
        lines += ['','Full fixture definitions, source hashes, storage bytes, individual samples and plan observations are in the companion JSON; nested plans are in the plans text file.']
        artifact.with_suffix('.md').write_text('\n'.join(lines)+'\n')
        print('Evidence:',artifact.with_suffix('.json'),flush=True)
    return 1 if report['failures'] else 0


if __name__=='__main__':
    raise SystemExit(main())
