import type { LibraryPaper } from './device-pdf';
export type PublicPaperLink={kind:'arxiv'|'doi';identity:string};
const arxiv=/^(?:\d{4}\.\d{4,5}|[a-z-]+(?:\.[A-Z]{2})?\/\d{7})(?:v\d{1,4})?$/;
const doi=/^10\.\d{4,9}\/[^\s?#]+$/;
export function parsePublicPaperLink(raw:string):PublicPaperLink|null {
  try {const u=new URL(raw,'https://app.gradstep.ai');if(u.origin!=='https://app.gradstep.ai'||u.search||u.username||u.password||raw.length>1000)return null;
    const match=/^\/p\/(arxiv|doi)\/(.+)$/.exec(u.pathname);if(!match)return null;const identity=decodeURIComponent(match[2]);
    return identity.length<=300 && (match[1]==='arxiv'?arxiv:doi).test(identity)?{kind:match[1] as PublicPaperLink['kind'],identity}:null;
  } catch{return null;}
}
export function paperShareLinks(p:LibraryPaper):{source:string|null;gradstep:string|null} {
  let link:PublicPaperLink|null=null,source:string|null=null;
  if(p.source_id && arxiv.test(p.source_id))link={kind:'arxiv',identity:p.source_id+(p.source_revision?'v'+p.source_revision:'')};
  if('source_url' in p && typeof p.source_url==='string')try{const u=new URL(p.source_url);if(['https:','http:'].includes(u.protocol)&&!u.username&&!u.password)source=u.href;if(u.hostname==='doi.org'&&doi.test(u.pathname.slice(1)))link={kind:'doi',identity:u.pathname.slice(1)};}catch{}
  if(link)return {source:link.kind==='arxiv'?`https://arxiv.org/abs/${link.identity}`:`https://doi.org/${link.identity}`,gradstep:`https://app.gradstep.ai/p/${link.kind}/${encodeURIComponent(link.identity)}`};
  return {source,gradstep:null};
}
export async function sharePublicURL(url:string) {
  if(navigator.share)await navigator.share({url}); else await navigator.clipboard.writeText(url);
}
