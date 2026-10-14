// Opt-in, offline replay of pinned official sources. See docs/TESTING.md.
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {expect,test} from '@playwright/test';
import {validateReaderBundle} from '../../../supabase/functions/_shared/reader/validate';
import {durableKeys} from './key-capability';
import {choosePDF,guardLocalContent,signInReader} from './device-reader-helpers';

const root=new URL('../../../',import.meta.url);
// READER_CORPUS_SET=<name> replays tests/corpus/<name>.json with its lock (an ad-hoc audit list); default: the pinned corpus.
const corpusSet=/^[a-z0-9-]{1,40}$/.test(process.env.READER_CORPUS_SET??'')?process.env.READER_CORPUS_SET:'reader';
const papers=JSON.parse(readFileSync(new URL(`tests/corpus/${corpusSet}.json`,root),'utf8')).papers;
const lock=JSON.parse(readFileSync(new URL(`tests/corpus/${corpusSet}-lock.json`,root),'utf8'));
const script=readFileSync(new URL('apps/web/public/arxiv-reader.js',root),'utf8')+'\n'+readFileSync(new URL('apps/web/src/reader/arxiv-compiler-host.js',root),'utf8');
const hash='sha256-'+createHash('sha256').update(script).digest('base64');
function input(key:string,name:string,record:{bytes:number;sha256:string}) {
 const bytes=readFileSync(new URL(`.artifacts/reader-corpus/${key}/${name}`,root));
 expect(bytes.length).toBe(record.bytes);expect(createHash('sha256').update(bytes).digest('hex')).toBe(record.sha256);
 return bytes;
}
for(const paper of papers) {
 const key=`${paper.id}v${paper.revision}`,pinned=lock.papers.find((p:{key:string})=>p.key===key);
 test(`${key}: exact HTML → isolated compiler → independent validator → rendered math and figures`,async({page},info)=>{
  const network:string[]=[];
  await page.route('https://**',route=>{network.push(route.request().url());return route.abort();});
  await page.goto('/');
  const source=input(key,'source.html',pinned.html).toString('base64');
  const inputs=pinned.assets.map((a:{url:string;bytes:number;sha256:string})=>({url:a.url,base64:input(key,createHash('sha256').update(a.url).digest('hex'),a).toString('base64')}));
  const result=await page.evaluate(async({script,hash,source,inputs,paper})=>{
   const frame=document.createElement('iframe');frame.sandbox.add('allow-scripts');
   frame.srcdoc=`<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src '${hash}'; img-src data:; connect-src 'none'; style-src 'none'; base-uri 'none'"><script>${script}</script>`;
   const loaded=new Promise<void>(resolve=>{frame.onload=()=>resolve();});document.body.append(frame);await loaded;
   try{return await new Promise<any>((resolve,reject)=>{
    const c=new MessageChannel(),timer=setTimeout(()=>{c.port1.close();reject(Error('compiler timeout'));},90000);
    c.port1.onmessage=e=>{clearTimeout(timer);c.port1.close();resolve(e.data);};
    frame.contentWindow!.postMessage({method:'prepare',source,sourceID:paper.id,revision:paper.revision,inputs},'*',[c.port2]);
   });}finally{frame.remove();}
  },{script,hash,source,inputs,paper});
  expect(network).toEqual([]);
  if(paper.expectedFailure){
   expect(result).toEqual({ok:false,failure:paper.expectedFailure});
   info.annotations.push({type:'unsupported-source',description:paper.reason});return;
  }
  expect(result.ok,JSON.stringify({key,failure:result.failure})).toBe(true);
  const bundle=result.result,members=new Map<string,Buffer>(bundle.members.map((m:{path:string;base64:string})=>[m.path,Buffer.from(m.base64,'base64')]));
  const checked=validateReaderBundle(Buffer.from(bundle.manifest,'base64'),members,bundle.manifestSHA256);
  expect(checked.provenance.source.url).toBe(pinned.html.url);
  const counts={blocks:checked.index.blocks.length,equations:checked.index.equations.length,figures:checked.index.figures.length};
  if(paper.counts)expect(counts).toEqual(paper.counts);
  // The pinned corpus is chosen for coverage; an ad-hoc audit set only has to compile, verify and render.
  if(corpusSet==='reader'){expect(counts.blocks).toBeGreaterThan(100);expect(counts.equations).toBeGreaterThan(20);expect(counts.figures).toBeGreaterThan(0);}
  let html=members.get('index.html')!.toString();
  const manifest=JSON.parse(Buffer.from(bundle.manifest,'base64').toString());
  for(const m of manifest.members.filter((m:{role:string})=>m.role==='image'))html=html.replaceAll(`src="${m.path}"`,`src="data:${m.media_type};base64,${members.get(m.path)!.toString('base64')}"`);
  html=html.replace('<link rel="stylesheet" href="reader.css">',`<style>${members.get('reader.css')!.toString()}</style>`);
  // Like frameDocument, reading uses admitted data URLs, not bundle-relative fetches.
  html=html.replace("img-src 'self'","img-src data:");
  await page.evaluate(html=>{const f=document.createElement('iframe');f.id='corpus-render';f.sandbox.add('allow-same-origin');f.style.cssText='width:100%;height:900px';document.body.replaceChildren(f);f.srcdoc=html;},html);
  const frame=page.frameLocator('#corpus-render');await expect(frame.locator('math').first()).toBeVisible();
  await expect.poll(()=>frame.locator('img').evaluateAll(images=>images.every(i=>(i as HTMLImageElement).complete&&(i as HTMLImageElement).naturalWidth>0))).toBe(true);
  expect(await frame.locator('a[href^="#"]').evaluateAll(links=>links.every(a=>!!a.ownerDocument.getElementById(a.getAttribute('href')!.slice(1))))).toBe(true);
  expect(await frame.locator('math').count()).toBe(counts.equations);
  await info.attach('coverage',{body:JSON.stringify({key,...counts,members:members.size,network},null,2),contentType:'application/json'});
 });
 test(`${key}: original PDF imports locally and membership reopens without file upload`,async({page,request},info)=>{
  test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys; compiler coverage still runs.');
  const guard=guardLocalContent(page);await signInReader(page,request);
  const pdf=input(key,'paper.pdf',pinned.pdf),title=`Corpus ${key}`;
  const dialog=await choosePDF(page,title+'.pdf',pdf);
  await expect(page.getByTestId('add-outcome')).toContainText('PDF stays on this device',{timeout:30000});
  await dialog.getByRole('button',{name:'Done',exact:true}).click();
  const row=page.getByTestId('paper-row').filter({hasText:title});await expect(row).toBeVisible();
  await page.reload();await expect(row).toContainText('Choose PDF on this device');
  guard.assertPrivate([title,pdf.subarray(0,120).toString('base64')]);
  await info.attach('local-pdf',{body:JSON.stringify({key,bytes:pdf.length,sha256:pinned.pdf.sha256,uploaded:false}),contentType:'application/json'});
 });
}
