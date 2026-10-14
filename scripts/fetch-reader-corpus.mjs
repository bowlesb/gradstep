// Explicit opt-in acquisition on the developer's device. Never called by tests,
// deployment, hosted workflows or a server. No credentials or paid providers.
import {readFileSync, writeFileSync, mkdirSync, existsSync, renameSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {arxivHTMLAssets} from '../supabase/functions/_shared/reader/arxiv-html.ts';

const root = fileURLToPath(new URL('../', import.meta.url));
process.chdir(root);
if (!process.argv.includes('--on-this-device')) throw Error('Use --on-this-device on your local computer; PDFs must never be downloaded by a hosted runner.');
if (process.env.CI || process.env.K_SERVICE || process.env.GITHUB_ACTIONS) throw Error('Local-device corpus acquisition only.');
const papers = JSON.parse(readFileSync('tests/corpus/reader.json')).papers;
const cache = '.artifacts/reader-corpus';
const lockPath = 'tests/corpus/reader-lock.json';
const update = process.argv.includes('--update-lock');
const lock = existsSync(lockPath) ? JSON.parse(readFileSync(lockPath)) : {format:1,papers:[]};
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
let lastRequest = 0;
async function acquire(url, file, maximum, mime, pinned) {
  mkdirSync(file.slice(0,file.lastIndexOf('/')), {recursive:true});
  let bytes;
  if (existsSync(file)) bytes = readFileSync(file);
  else {
    await new Promise(resolve => setTimeout(resolve, Math.max(0, 3100-(Date.now()-lastRequest))));
    lastRequest = Date.now();
    const response = await fetch(url, {redirect:'error', signal:AbortSignal.timeout(60000), headers:{'User-Agent':'Gradstep-local-reader-compatibility/1.0'}});
    if (!response.ok || !mime.test(response.headers.get('content-type') ?? '')) throw Error(`Unexpected source response ${response.status}: ${url}`);
    const chunks=[]; let count=0;
    for await (const chunk of response.body) {
      count+=chunk.length; if(count>maximum) throw Error(`Corpus download exceeds bound: ${url}`);
      chunks.push(chunk);
    }
    bytes=Buffer.concat(chunks);
  }
  if (!bytes.length || bytes.length>maximum) throw Error(`Invalid corpus length: ${url}`);
  const record={url,bytes:bytes.length,sha256:hash(bytes)};
  if (!update && (!pinned || pinned.url!==url || pinned.bytes!==record.bytes || pinned.sha256!==record.sha256))
    throw Error(`Source changed or not pinned: ${url}. Review before using --update-lock.`);
  if (!existsSync(file)) {writeFileSync(file+'.partial',bytes);renameSync(file+'.partial',file);}
  return record;
}
for (const paper of papers) {
  const key=`${paper.id}v${paper.revision}`, dir=`${cache}/${key}`, url=`https://arxiv.org/html/${key}`;
  const old=lock.papers.find(p=>p.key===key);
  const html=await acquire(url,`${dir}/source.html`,8*1024*1024,/^text\/html/,old?.html);
  // A rejected source is still a useful corpus case; don't fetch undeclared assets.
  let assets=[], acquisitionFailure;
  try {assets=arxivHTMLAssets(readFileSync(`${dir}/source.html`,'utf8'),url);}
  catch(error) {acquisitionFailure=error.message;}
  const imageInputs=[];
  for(const asset of assets) imageInputs.push(await acquire(asset,`${dir}/${hash(asset)}`,16*1024*1024,/^image\//,old?.assets.find(a=>a.url===asset)));
  const pdf=await acquire(`https://arxiv.org/pdf/${key}`,`${dir}/paper.pdf`,64*1024*1024,/^application\/pdf/,old?.pdf);
  if (readFileSync(`${dir}/paper.pdf`).subarray(0,5).toString()!=='%PDF-') throw Error('Non-PDF corpus response');
  const row={key,html,assets:imageInputs,pdf,...(acquisitionFailure?{acquisitionFailure}:{})};
  if(update){lock.papers=lock.papers.filter(p=>p.key!==key);lock.papers.push(row);writeFileSync(lockPath,JSON.stringify(lock,null,2)+'\n');}
  console.log(`${key}: HTML ${html.bytes} bytes, ${imageInputs.length} assets, PDF ${pdf.bytes} bytes (local only)`);
}
