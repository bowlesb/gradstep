import {useEffect,useMemo,useRef,useState,useSyncExternalStore} from 'react';
import type {ChatSession} from '../lib/chat-session';
import type {CatalogController} from './useCatalogs';
import {catalogEvent,documentCatalogKey} from '../lib/library-catalogs';
import {localPDFMembership,type LocalPDFMembership,type PrivateEvent} from '../lib/events';
import {readPDF,titleForPDF} from '../lib/pdf-upload';
import type {LocalPDFPaper} from '../lib/device-pdf';

async function inspect(file:File,signal:AbortSignal):Promise<number>{
 const bytes=await readPDF(file,signal);signal.throwIfAborted();
 const worker=new Worker(new URL('../lib/device-pdf-worker.ts',import.meta.url),{type:'module'});
 try{return await new Promise<number>((resolve,reject)=>{
  const finish=(pages?:number)=>{clearTimeout(timer);signal.removeEventListener('abort',stop);pages?resolve(pages):reject(new Error('This PDF could not be opened. Choose an unencrypted PDF with at most 250 pages.'));};
  const stop=()=>finish(),timer=setTimeout(stop,20000);signal.addEventListener('abort',stop,{once:true});
  worker.onerror=stop;worker.onmessage=e=>finish(e.data?.ok?e.data.pages:undefined);
  worker.postMessage(bytes.buffer,[bytes.buffer]);
 });}finally{worker.terminate();}
}
export function useDevicePDFs(chat:ChatSession|null,catalogs?:CatalogController){
 const version=useSyncExternalStore(chat?.history.subscribe??(()=>()=>{}),chat?.history.getVersion??(()=>0));
 const pendingBytes=useRef(0);
 const files=useRef(new Map<string,{file:File;url:string}>()),[generation,changed]=useState(0);
 const [issue,setIssue]=useState<string|null>(null);
 useEffect(()=>{const clear=()=>{for(const f of files.current.values())URL.revokeObjectURL(f.url);files.current.clear();};chat?.signal.addEventListener('abort',clear,{once:true});return()=>{clear();chat?.signal.removeEventListener('abort',clear);};},[chat]);
 const rows=useMemo(()=>{
  if(!chat)return [];
  const state=chat.history.state,ids=new Set([...state.events.values()].filter(e=>e.payload.kind==='local_paper').map(e=>e.payload.entityID));
  const result:LocalPDFPaper[]=[];
  for(const id of ids){const event=state.revisions(id)[0]?.payload;if(!event||event.kind!=='local_paper')continue;
   const m=localPDFMembership(event);result.push({kind:'local_pdf',id,visible:true,metadata:{title:m.title,authors:[],categories:[]},page_count:m.pageCount,added_at:m.createdAt,archived:m.archived,user_tags:m.tags,available:files.current.has(id)});
  }return result;
 },[chat,version,generation]);
 const add=async(file:File,existing?:LocalPDFPaper)=>{
  if(!chat||chat.signal.aborted)throw Error('Sign in to add this PDF.');
  const retained=[...files.current.values()].reduce((n,f)=>n+f.file.size,0);
  if(files.current.size>=128 && !existing || retained+pendingBytes.current+file.size>268435456)throw Error('This tab has reached its local PDF limit. Remove a local copy or reopen the tab before adding another PDF.');
  const destination=catalogs?.currentID;
  pendingBytes.current+=file.size;
  try {
  const pages=await inspect(file,chat.signal);chat.signal.throwIfAborted();
  const id=existing?.id??crypto.randomUUID();
  if(existing && pages!==existing.page_count)throw Error('This PDF has a different page count. Choose the original file or add it as a new paper.');
  if(!existing){
   const member:LocalPDFMembership={format:'device-pdf-membership-v1',title:titleForPDF(file).display_name,pageCount:pages,createdAt:Date.now(),archived:false,tags:[]};
   const events:{id:string;event:PrivateEvent}[]=[{id:crypto.randomUUID(),event:{kind:'local_paper',entityID:id,parents:[],text:JSON.stringify(member),createdAt:member.createdAt}}];
   if(destination&&catalogs?.currentState().catalogFor(documentCatalogKey(id))!==destination)events.push({id:crypto.randomUUID(),event:catalogEvent(chat.history.state,[{action:'assign',catalogID:destination,paperKey:documentCatalogKey(id)}])});
   await chat.history.commit(events);
  }
  chat.signal.throwIfAborted();const old=files.current.get(id);if(old)URL.revokeObjectURL(old.url);
  files.current.set(id,{file,url:URL.createObjectURL(file)});changed(v=>v+1);void chat.history.sync().catch(()=>{});return id;
  } finally {pendingBytes.current-=file.size;}
 };
 const open=(paper:LocalPDFPaper)=>{
  const saved=files.current.get(paper.id);
  if(saved){window.open(saved.url,'_blank','noopener,noreferrer');return;}
  const input=document.createElement('input');input.type='file';input.accept='application/pdf,.pdf';
  input.onchange=()=>{const file=input.files?.[0];if(file)void add(file,paper).then(()=>setIssue('PDF ready on this device. Open the paper to view it.')).catch(e=>setIssue(e instanceof Error?e.message:'Couldn’t open this PDF.'));};input.click();
 };
 const mutate=async(paper:LocalPDFPaper,change:{archived?:boolean;tags?:string[];remove?:boolean})=>{
  if(!chat||chat.signal.aborted)throw Error('Sign in to edit this paper.');
  const prior=chat.history.state.revisions(paper.id);if(!prior.length)throw Error('This paper is no longer in your library.');
  const member=localPDFMembership(prior[0].payload);
  const event:PrivateEvent={kind:change.remove?'tombstone':'local_paper',entityID:paper.id,parents:prior.map(e=>e.id),createdAt:Date.now()};
  if(!change.remove)event.text=JSON.stringify({...member,archived:change.archived??member.archived,tags:change.tags??member.tags});
  await chat.history.commit([{id:crypto.randomUUID(),event}]);chat.signal.throwIfAborted();
  if(change.remove){const old=files.current.get(paper.id);if(old)URL.revokeObjectURL(old.url);files.current.delete(paper.id);changed(v=>v+1);}
  void chat.history.sync().catch(()=>{});return null;
 };
 return {rows,add,open,mutate,issue,clearIssue:()=>setIssue(null)};
}
export type DevicePDFs=ReturnType<typeof useDevicePDFs>;
