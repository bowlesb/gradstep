import type { Metadata, Entry } from './library';
import type { ReaderPaper } from './reader-paper';
export interface LocalPDFPaper {
 kind:'local_pdf'; id:string; visible:true; metadata:Metadata; page_count:number; added_at:number; archived:boolean; user_tags:string[]; available:boolean;
 source_id?:never;source_url?:never;source_revision?:never;tags?:never;hidden_tags?:never;scope?:never;
}
export type LibraryPaper=ReaderPaper|LocalPDFPaper;
export type ClientEntry=Entry|LocalPDFPaper;
export function isLocalPDF(e:ClientEntry):e is LocalPDFPaper{return e.kind==='local_pdf';}
