import { fromBase64, fromUtf8, toBase64, type Bytes } from './bytes';
import { verifyBundle, type VerifiedBundle } from './bundle';
import { sourceReference, type SourcePaperReference } from './events';
import { arxivPreparationMessage } from './arxiv-reader-error';
export class ArxivReaderError extends Error {}
let nextRequest = 0;
const abort = (signal: AbortSignal) => signal.throwIfAborted();
const wait = (ms: number, signal: AbortSignal) => new Promise<void>((resolve,reject) => {
 abort(signal); const stop = () => {clearTimeout(timer);reject(signal.reason);};
 const timer = setTimeout(() => {signal.removeEventListener('abort',stop);resolve();},Math.max(0,ms)); signal.addEventListener('abort',stop,{once:true});
});
export const arxivHTMLURL = (ref: SourcePaperReference): string => {sourceReference(ref);return `https://arxiv.org/html/${ref.sourceID}v${ref.revision}`;};
export function admitsArxivAsset(url: string, base: string): boolean {
 try { const u=new URL(url);return u.origin === 'https://arxiv.org' && !u.username && !u.password && !u.search && !u.hash &&
  !/%/.test(url) && !url.includes('\\') && u.href === url && u.pathname.startsWith(new URL(base).pathname+'/') && /\.(png|jpe?g|svg)$/i.test(u.pathname); } catch {return false;}
}
async function retrieve(url: string, maximum: number, html: boolean, parentSignal: AbortSignal): Promise<Bytes> {
 const signal=AbortSignal.any([parentSignal,AbortSignal.timeout(90000)]);
 const scheduled=Math.max(Date.now(),nextRequest);nextRequest=scheduled+3000;await wait(scheduled-Date.now(),signal);
 let response: Response;
 try { response=await fetch(url,{credentials:'omit',redirect:'error',cache:'no-store',referrerPolicy:'no-referrer',signal}); }
 catch(error) {abort(signal);throw new ArxivReaderError('Couldn’t retrieve this paper from arXiv. Check your connection and try again.');}
 if ([429,503].includes(response.status)) {
  const retry=response.headers.get('retry-after'),seconds=retry && /^\d+$/.test(retry)?Number(retry):Math.max(60,(Date.parse(retry??'')-Date.now())/1000 || 60);
  nextRequest=Math.max(nextRequest,Date.now()+Math.min(86400,Math.max(3,seconds))*1000);
  await response.body?.cancel();throw new ArxivReaderError('arXiv is busy. Try preparing this paper again later.');
 }
 const type=response.headers.get('content-type')?.split(';')[0].trim().toLowerCase();
 if (!response.ok || response.url !== url || !response.body || !(html?['text/html','application/xhtml+xml']:['image/png','image/jpeg','image/svg+xml']).includes(type??'')) {
  await response.body?.cancel();throw new ArxivReaderError('HTML reader unavailable for this version. You can still download its PDF on this device.');
 }
 if (Number(response.headers.get('content-length')??0)>maximum) {await response.body.cancel();throw new ArxivReaderError('This paper exceeds the device reader’s preparation limits.');}
 const reader=response.body.getReader(),chunks:Uint8Array[]=[];let size=0;
 try {while(true){abort(signal);const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>maximum)throw new ArxivReaderError('This paper exceeds the device reader’s preparation limits.');chunks.push(value);}}
 finally {await reader.cancel().catch(()=>{});}
 const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}return bytes;
}
export async function prepareArxivReader(reference: SourcePaperReference, signal: AbortSignal, progress?: (n:number)=>void): Promise<VerifiedBundle> {
 const ref=sourceReference(reference),url=arxivHTMLURL(ref);
 const html=await retrieve(url,2097152,true,signal);abort(signal);
 const {default:compiler}=await import('virtual:arxiv-compiler');abort(signal);
 const frame=document.createElement('iframe');frame.hidden=true;frame.sandbox.add('allow-scripts');
 frame.srcdoc=`<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src '${compiler.hash}'; img-src data:; connect-src 'none'; style-src 'none'; base-uri 'none'"><script>${compiler.script}</script>`;
 const loaded=new Promise<void>((resolve,reject)=> {frame.onload=()=>resolve();frame.onerror=()=>reject(new ArxivReaderError('The device compiler could not start.'));});
 document.body.append(frame);
 const call = async (method:'assets'|'prepare',inputs?:{url:string;base64:string}[]):Promise<unknown> => {
  abort(signal);
  return await new Promise((resolve,reject)=>{
   const channel=new MessageChannel();let timer:ReturnType<typeof setTimeout>;
   const cleanup=()=>{clearTimeout(timer);channel.port1.close();signal.removeEventListener('abort',stop);};
   const stop=()=>{cleanup();reject(signal.reason);};
   timer=setTimeout(()=>{cleanup();reject(new ArxivReaderError('Preparing this paper took too long. Try opening it again. You can still download its PDF on this device.'));},90000);
   signal.addEventListener('abort',stop,{once:true});
   channel.port1.onmessage=e=>{cleanup();e.data?.ok?resolve(e.data.result):reject(new ArxivReaderError(arxivPreparationMessage(e.data?.failure)));};
   frame.contentWindow!.postMessage({method,source:toBase64(html),sourceID:ref.sourceID,revision:ref.revision,inputs},'*',[channel.port2]);
  });
 };
 try {
  await Promise.race([loaded,wait(15000,signal).then(()=>{throw new ArxivReaderError('The device compiler could not start.');})]);
  const assets=await call('assets');if(!Array.isArray(assets)||assets.length>512||new Set(assets).size!==assets.length)throw new ArxivReaderError('Invalid paper assets.');
  let total=html.length;const inputs:{url:string;base64:string}[]=[];
  for(const [i,asset] of assets.entries()){
   if(typeof asset!=='string'||!admitsArxivAsset(asset,url))throw new ArxivReaderError('Invalid paper assets.');
   const bytes=await retrieve(asset,Math.min(16777216,33554432-total),false,signal);total+=bytes.length;inputs.push({url:asset,base64:toBase64(bytes)});progress?.((i+1)/(assets.length+1));
  }
  const p=await call('prepare',inputs) as {manifest:string;manifestSHA256:string;members:{path:string;base64:string}[]};
  abort(signal);
  if(!p||typeof p.manifest!=='string'||p.manifest.length>349528||!Array.isArray(p.members)||p.members.length>512)throw new ArxivReaderError('Invalid reader bundle.');
  const members=new Map<string,Bytes>();total=0;
  for(const m of p.members){if(typeof m.path!=='string'||typeof m.base64!=='string'||m.base64.length>22369624||members.has(m.path))throw new ArxivReaderError('Invalid reader bundle.');const bytes=fromBase64(m.base64);total+=bytes.length;if(total>33554432)throw new ArxivReaderError('Reader bundle is too large.');members.set(m.path,bytes);}
  const bundle=await verifyBundle(fromBase64(p.manifest),p.manifestSHA256,members);
  const provenance=JSON.parse(fromUtf8(members.get(bundle.manifest.source.provenance_path)!));
  if(provenance.source.url!==url)throw new ArxivReaderError('Wrong source revision.');abort(signal);progress?.(1);return bundle;
 } finally {frame.remove();}
}

export function localChatContext(ref:SourcePaperReference,bundle:VerifiedBundle):import('./chat').LocalPaperContext {
 const raw=bundle.contents.get(bundle.manifest.source.provenance_path);
 if(bundle.manifest.source.kind!=='arxiv-html'||!raw)throw new ArxivReaderError('Open this paper to prepare its HTML reader first.');
 const provenance=JSON.parse(fromUtf8(raw));
 if(provenance.source.url!==arxivHTMLURL(ref))throw new ArxivReaderError('The reader does not match this paper revision.');
 const text=bundle.index.blocks.map(b=>b.text).join('\n\n');
 if(!text.trim()||new TextEncoder().encode(text).length>2097152)throw new ArxivReaderError('This paper exceeds the chat context limit.');
 return {format:'reader-local-context-v1',membership_id:ref.membershipID,source:'arxiv',source_id:ref.sourceID,revision:ref.revision,
  manifest_sha256:bundle.manifestSHA256,source_sha256:bundle.manifest.source.sha256,text};
}
