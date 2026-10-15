// Slow runs are explicit. Record evidence, never silently turn a stale result into a pass.
import {spawn, execFileSync} from 'node:child_process';
import {readFileSync, readdirSync, mkdirSync, writeFileSync, createWriteStream, existsSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url)); process.chdir(root);
const [tier='fast',...extra]=process.argv.slice(2);
const dir='.artifacts/test-tiers';mkdirSync(dir,{recursive:true});
const files=execFileSync('git',['ls-files','--cached','--others','--exclude-standard','-z'],{encoding:'utf8'}).split('\0')
 .filter(p=>p && /^(apps\/web\/|apps\/apple\/|supabase\/functions\/_shared\/reader\/|tests\/|scripts\/(test-tiers|fetch-reader-corpus|build-arxiv-compiler|arxiv-compiler)|package)/.test(p)).sort();
const inputHash=createHash('sha256');
for(const path of files)if(existsSync(path)){inputHash.update(path+'\0');inputHash.update(readFileSync(path));}
const fingerprint=inputHash.digest('hex');
if(tier==='status'){
 for(const name of ['fast','slow','corpus','native']){
  const path=`${dir}/${name}.json`;
  if(!existsSync(path)){console.log(`${name}: no saved run`);continue;}
  const r=JSON.parse(readFileSync(path));
  console.log(`${name}: ${r.ok?'passed':'FAILED'} ${r.finishedAt}; ${r.fingerprint===fingerprint?'source unchanged':'source changed since run'}; ${r.seconds}s`);
 }
 process.exit(0);
}
const commands={
 fast:[['compiler freshness',process.execPath,['scripts/build-arxiv-compiler.mjs','--check'],root],
  ['device PDF compiler freshness',process.execPath,['scripts/build-device-pdf-compiler.mjs','--check'],root],
  ['backend',process.execPath,['--test',...readdirSync('tests/backend').filter(p=>p.endsWith('.test.ts')).map(p=>'tests/backend/'+p)],root],
  ['operations',process.execPath,['--test','tests/operations/web-deployment.test.mjs','tests/operations/arxiv-acknowledgement.test.mjs','tests/operations/arxiv-egress-scan.test.mjs'],root],
  // Servers must not contact arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md): report mode fails only on a new call site.
  ['arxiv egress scan',process.execPath,['scripts/check-arxiv-egress.mjs'],root],
  ['browser units','npm',['run','test:fast'],root+'apps/web']],
 slow:[['reader journeys','npm',['run','e2e','--','arxiv-compiler.spec.ts','arxiv-html.spec.ts','device-pdf.spec.ts',...extra],root+'apps/web']],
 corpus:[['real paper corpus','npm',['run','e2e','--','--config','reader-corpus.playwright.config.ts',...extra],root+'apps/web']],
 native:[['iPad integration','xcodebuild',['test','-project','apps/apple/ScienceReader.xcodeproj','-scheme','ScienceReader',
  '-destination','platform=iOS Simulator,name=iPad Pro 13-inch (M5)','-derivedDataPath','.artifacts/reader-integration-build',
  '-only-testing:ScienceReaderTests/ArxivHTMLReaderTests','-only-testing:ScienceReaderTests/PDFUploadTests',...extra],root]],
};
if(!commands[tier])throw Error('Choose fast, slow, corpus, native, or status');
if(tier==='fast'&&extra.length)throw Error('For targeted tests use test:backend or apps/web test:fast.');
const report={tier,fingerprint,selection:extra,node:process.version,platform:process.platform,startedAt:new Date().toISOString(),steps:[],ok:true};
const start=Date.now();
for(const [name,command,args,cwd] of commands[tier]){
 const log=`${dir}/${tier}-${name.replaceAll(' ','-')}.log`, stream=createWriteStream(log), stepStart=Date.now();
 console.log(`${name} … (${log})`);
 const result=await new Promise(resolve=>{
  const child=spawn(command,args,{cwd,env:process.env,stdio:['ignore','pipe','pipe']});
  child.stdout.pipe(stream,{end:false});child.stderr.pipe(stream,{end:false});
  child.on('error',error=>{stream.write(String(error));resolve(1);});child.on('close',code=>resolve(code??1));
 });
 await new Promise(resolve=>stream.end(resolve));
 const step={name,exitCode:result,seconds:Math.round((Date.now()-stepStart)/100)/10,log};report.steps.push(step);
 console.log(`${name}: ${result===0?'passed':'FAILED'} (${step.seconds}s)`);
 if(result!==0){report.ok=false;console.error(readFileSync(log,'utf8').split('\n').slice(-45).join('\n'));break;}
}
report.finishedAt=new Date().toISOString();report.seconds=Math.round((Date.now()-start)/100)/10;
writeFileSync(`${dir}/${tier}.json`,JSON.stringify(report,null,2)+'\n');
process.exitCode=report.ok?0:1;
