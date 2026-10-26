// Slow runs are explicit. Record evidence, never silently turn a stale result into a pass.
// Each tier fingerprints the sources it actually tests (review D5, 2026-10-21): `test:status` says "source changed"
// after an edit anywhere a tier reads, including Edge functions, migrations, the admin site, services and scripts.
import {spawn, execFileSync} from 'node:child_process';
import {readFileSync, readdirSync, mkdirSync, writeFileSync, createWriteStream, existsSync, statSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url)); process.chdir(root);
const [tier='fast',...extra]=process.argv.slice(2);
const dir='.artifacts/test-tiers';mkdirSync(dir,{recursive:true});
const TIERS=['fast','ops','database','slow','corpus','native'];
// What each tier tests. `package` covers the root package.json and package-lock.json.
const SCOPES={
 fast:/^(apps\/web\/|apps\/admin\/|apps\/apple\/ScienceReader\/Resources\/pdf-position-matcher\.js$|supabase\/functions\/|supabase\/migrations\/|services\/|scripts\/|tests\/(backend|operations|corpus|fixtures|local-ai|model-bakeoff|reader)\/|infra\/|package)/,
 ops:/^(scripts\/|tests\/operations\/|tests\/database\/bootstrap\.sql|supabase\/|services\/|infra\/|package)/,
 database:/^(supabase\/migrations\/|tests\/database\/|scripts\/(test-database|pg_tools)\.py|package)/,
 slow:/^(apps\/web\/|supabase\/functions\/_shared\/|tests\/|scripts\/(test-tiers|fetch-reader-corpus|build-arxiv-compiler|arxiv-compiler)|package)/,
 corpus:/^(apps\/web\/|supabase\/functions\/_shared\/|tests\/|scripts\/(test-tiers|fetch-reader-corpus|build-arxiv-compiler|arxiv-compiler)|package)/,
 native:/^(apps\/apple\/|supabase\/functions\/_shared\/reader\/|tests\/|scripts\/(test-tiers|fetch-reader-corpus|build-arxiv-compiler|arxiv-compiler)|package)/,
};
const listed=execFileSync('git',['ls-files','--cached','--others','--exclude-standard','-z'],{encoding:'utf8'}).split('\0').filter(Boolean).sort();
function fingerprint(name){
 const hash=createHash('sha256');
 // Files only: a worktree's linked dependency folders (node_modules, DeviceModels) are listed as untracked entries.
 for(const path of listed)if(SCOPES[name].test(path)&&existsSync(path)&&statSync(path).isFile()){hash.update(path+'\0');hash.update(readFileSync(path));}
 return hash.digest('hex');
}
if(tier==='status'){
 for(const name of TIERS){
  const path=`${dir}/${name}.json`;
  if(!existsSync(path)){console.log(`${name}: no saved run`);continue;}
  const r=JSON.parse(readFileSync(path));
  console.log(`${name}: ${r.ok?'passed':'FAILED'} ${r.finishedAt}; ${r.fingerprint===fingerprint(name)?'source unchanged':'source changed since run'}; ${r.seconds}s`);
 }
 process.exit(0);
}
const bin=name=>root+'node_modules/.bin/'+name;
const edgeEntries=readdirSync('supabase/functions').filter(name=>existsSync(`supabase/functions/${name}/index.ts`)).map(name=>`supabase/functions/${name}/index.ts`);
const nodeOperations=readdirSync('tests/operations').filter(p=>p.endsWith('.test.mjs')).map(p=>'tests/operations/'+p);
// [name, command, args, cwd, kind]: `kind` names the runner whose report must show tests ran and none were skipped.
const commands={
 fast:[['compiler freshness',process.execPath,['scripts/build-arxiv-compiler.mjs','--check'],root],
  ['PDF position matcher',process.execPath,['--test','tests/reader/pdf-position-matcher.test.mjs'],root,'node'],
  ['device PDF compiler freshness',process.execPath,['scripts/build-device-pdf-compiler.mjs','--check'],root],
  ['backend',process.execPath,['--test',...readdirSync('tests/backend').filter(p=>p.endsWith('.test.ts')).map(p=>'tests/backend/'+p)],root,'node'],
  ['operations',process.execPath,['--test',...nodeOperations],root,'node'],
  // Deploy, restore, readiness and spending operators (Python), without the ones that need the local database.
  ['operations (Python)','python3',['scripts/test-ops.py','--no-database'],root],
  // Servers never contact arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md): block mode fails on any server call site.
  ['arxiv egress scan',process.execPath,['scripts/check-arxiv-egress.mjs','--block'],root],
  // Every deployed Edge entry point type-checks strictly against the locked dependencies.
  ['edge type check',bin('deno'),['check','--frozen','--config','supabase/functions/deno.json',...edgeEntries],root],
  ['admin type check',bin('tsc'),['--noEmit','-p','apps/admin/tsconfig.json'],root],
  ['browser units','npm',['run','test:fast'],root+'apps/web','vitest']],
 // Every operations contract, including the restore quarantine against the local PostgreSQL 18 server.
 ops:[['operations (Python)','python3',['scripts/test-ops.py'],root],
  ['operations',process.execPath,['--test',...nodeOperations],root,'node']],
 database:[['database','python3',['scripts/test-database.py',...extra],root]],
 slow:[['reader journeys','npm',['run','e2e','--','arxiv-compiler.spec.ts','arxiv-html.spec.ts','device-pdf.spec.ts',...extra],root+'apps/web']],
 corpus:[['source metadata on the corpus',process.execPath,['--test','tests/corpus/source-metadata.test.ts'],root],
  ['real paper corpus','npm',['run','e2e','--','--config','reader-corpus.playwright.config.ts',...extra],root+'apps/web']],
 native:[['iPad integration','xcodebuild',['test','-project','apps/apple/ScienceReader.xcodeproj','-scheme','ScienceReader',
  '-destination','platform=iOS Simulator,name=iPad Pro 13-inch (M5)','-derivedDataPath','.artifacts/reader-integration-build',
  'SWIFT_OPTIMIZATION_LEVEL=-O','SWIFT_COMPILATION_MODE=wholemodule',
  '-only-testing:ScienceReaderTests/ArxivHTMLReaderTests','-only-testing:ScienceReaderTests/PDFUploadTests',...extra],root]],
};
if(!commands[tier])throw Error(`Choose ${TIERS.join(', ')}, or status`);
if((tier==='fast'||tier==='ops')&&extra.length)throw Error('For targeted tests use test:backend, apps/web test:fast or python3 -m unittest.');
/** A runner that exited 0 but ran nothing, or skipped something, is not a pass (fast, ops and database tiers). */
function quietGap(kind,text){
 if(kind==='node'){
  const count=name=>Number(new RegExp(`^ℹ ${name} (\\d+)$`,'m').exec(text)?.[1]??NaN);
  if(!(count('tests')>0))return 'no tests ran';
  if(count('skipped')>0||count('todo')>0)return `${count('skipped')} skipped, ${count('todo')} todo`;
 }
 if(kind==='vitest'){
  const line=/^\s*Tests\s+(.*)$/m.exec(text)?.[1];
  if(!line||!/\d+ passed/.test(line))return 'no tests ran';
  if(/skipped|todo/.test(line))return line.trim();
 }
 return null;
}
const report={tier,fingerprint:fingerprint(tier),selection:extra,node:process.version,platform:process.platform,startedAt:new Date().toISOString(),steps:[],ok:true};
const start=Date.now();
for(const [name,command,args,cwd,kind] of commands[tier]){
 const log=`${dir}/${tier}-${name.replaceAll(' ','-').replace(/[()]/g,'')}.log`, stream=createWriteStream(log), stepStart=Date.now();
 console.log(`${name} … (${log})`);
 const code=await new Promise(resolve=>{
  const child=spawn(command,args,{cwd,env:process.env,stdio:['ignore','pipe','pipe']});
  child.stdout.pipe(stream,{end:false});child.stderr.pipe(stream,{end:false});
  child.on('error',error=>{stream.write(String(error));resolve(1);});child.on('close',code=>resolve(code??1));
 });
 await new Promise(resolve=>stream.end(resolve));
 const gap=code===0&&kind&&['fast','ops','database'].includes(tier)?quietGap(kind,readFileSync(log,'utf8')):null;
 const step={name,exitCode:code,...(gap?{gap}:{}),seconds:Math.round((Date.now()-stepStart)/100)/10,log};report.steps.push(step);
 const ok=code===0&&!gap;
 console.log(`${name}: ${ok?'passed':`FAILED${gap?` (${gap})`:''}`} (${step.seconds}s)`);
 if(!ok){report.ok=false;console.error(readFileSync(log,'utf8').split('\n').slice(-45).join('\n'));break;}
}
report.finishedAt=new Date().toISOString();report.seconds=Math.round((Date.now()-start)/100)/10;
writeFileSync(`${dir}/${tier}.json`,JSON.stringify(report,null,2)+'\n');
process.exitCode=report.ok?0:1;
