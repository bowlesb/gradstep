import { PDFDocument } from 'pdf-lib';
self.onmessage=async(event:MessageEvent<ArrayBuffer>)=>{
 try{
  const bytes=new Uint8Array(event.data);
  if(bytes.length<5||bytes.length>67108864)throw Error('size');
  const pdf=await PDFDocument.load(bytes,{ignoreEncryption:false,updateMetadata:false});
  const pages=pdf.getPageCount();if(pages<1||pages>250)throw Error('pages');
  self.postMessage({ok:true,pages});
 }catch{self.postMessage({ok:false});}
};
