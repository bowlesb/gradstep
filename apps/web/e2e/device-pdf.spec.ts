import {test,expect} from '@playwright/test';
import {PDFDocument,degrees} from 'pdf-lib';
import {RECOVERY_CODE} from './fixture-keys.mjs';
import {fixtureOrigin} from './environment';
import {durableKeys} from './key-capability';
import {readFileSync,readdirSync} from 'node:fs';
import {choosePDF,guardLocalContent,signInReader} from './device-reader-helpers';

test('chosen PDF stays local; encrypted membership survives reload without pretending the file synced',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 await request.post(`${fixtureOrigin}/__reset`);
 const forbidden:string[]=[];
 page.on('request',r=>{if(/upload-pdf|\/storage\/|begin_pdf_upload|pdf_upload_part/.test(r.url()))forbidden.push(r.url());});
 await page.goto('/');await page.getByTestId('email').fill('returning@example.test');await page.getByTestId('send-code').click();
 await page.getByTestId('code').fill('123456');await page.getByTestId('verify').click();
 await page.getByTestId('use-recovery-code').click();await page.getByTestId('recovery-code').fill(RECOVERY_CODE);await page.getByTestId('recover').click();
 await expect(page.getByTestId('library-table')).toBeVisible();await page.getByRole('button',{name:'Add paper',exact:true}).click();
 const pdf=await PDFDocument.create();pdf.addPage().drawText('Device-only authored paper');
 await page.getByRole('dialog',{name:'Add paper'}).locator('input[type=file]').setInputFiles({name:'Device-only authored paper.pdf',mimeType:'application/pdf',buffer:Buffer.from(await pdf.save())});
 await page.getByRole('button',{name:'Add PDF',exact:true}).click();
 await expect(page.getByTestId('add-outcome')).toContainText('The PDF stays on this device');
 await page.getByRole('dialog',{name:'Add paper'}).getByRole('button',{name:'Done',exact:true}).click();
 await expect(page.getByTestId('library-table')).toContainText('Device-only authored paper');
 await expect.poll(async()=> (await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json()).events.length).toBeGreaterThan(0);
 const evidence=await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json();
 expect(JSON.stringify(evidence.events)).not.toContain('Device-only authored');expect(forbidden).toEqual([]);
 await page.reload();
 const row=page.getByTestId('paper-row').filter({hasText:'Device-only authored paper'});
 await expect(row).toBeVisible();await expect(row).toContainText('Choose PDF on this device');
 expect(forbidden).toEqual([]);
});

test('local PDF inspection worker handles image-only, rotated, object-stream and rejected documents',async({page})=>{
 const files=[];
 for(const kind of ['text','image-only','rotated','250-pages','251-pages','zero-pages']){
  const pdf=await PDFDocument.create();
  const count=kind==='250-pages'?250:kind==='251-pages'?251:kind==='zero-pages'?0:3;
  for(let i=0;i<count;i++){
   const p=pdf.addPage([200,300]);
   if(kind==='image-only')p.drawImage(await pdf.embedJpg(new Uint8Array(readFileSync(new URL('../../../tests/fixtures/reader-mathpix/figure-exif.jpg',import.meta.url)))),{x:0,y:0,width:150,height:150});
   else p.drawText(`Private local corpus page ${i+1}`);
   if(kind==='rotated')p.setRotation(degrees(90));
  }
  files.push({kind,bytes:[...await pdf.save({useObjectStreams:kind!=='text',addDefaultPage:false})],expected:count>0&&count<=250?{ok:true,pages:count}:{ok:false}});
 }
 files.push({kind:'damaged',bytes:[...Buffer.from('%PDF-1.7\nnot a document')],expected:{ok:false}});
 const asset=readdirSync(new URL('../dist-e2e/assets/',import.meta.url)).find(p=>p.startsWith('device-pdf-worker-')&&p.endsWith('.js'))!;
 expect(asset).toBeTruthy();await page.goto('/');
 const network:string[]=[];await page.route('https://**',route=>{network.push(route.request().url());return route.abort();});
 for(const file of files){
  const result=await page.evaluate(async({asset,bytes})=>{
   const worker=new Worker(`/assets/${asset}`,{type:'module'});
   try{return await new Promise((resolve,reject)=>{
    const timer=setTimeout(()=>reject(Error('PDF worker timeout')),20000);
    worker.onmessage=e=>{clearTimeout(timer);resolve(e.data);};worker.onerror=()=>{clearTimeout(timer);reject(Error('PDF worker error'));};
    const data=new Uint8Array(bytes);worker.postMessage(data.buffer,[data.buffer]);
   });}finally{worker.terminate();}
  },{asset,bytes:file.bytes});
  expect(result,file.kind).toEqual(file.expected);
 }
 expect(network).toEqual([]);
});

test('invalid PDF creates no membership; reselection preserves identity and refuses a different page count',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 const guard=guardLocalContent(page);await signInReader(page,request);
 const before=await page.getByTestId('paper-row').count();
 const bad=await choosePDF(page,'Malformed private file.pdf',Buffer.from('%PDF-1.7\ngarbage'));
 await expect(bad.getByRole('alert')).toContainText('could not be opened');
 await bad.getByRole('button',{name:'Cancel',exact:true}).click();
 await expect(page.getByTestId('paper-row')).toHaveCount(before);
 const pdf=await PDFDocument.create();pdf.addPage().drawText('Local private content canary');
 const bytes=Buffer.from(await pdf.save()),title='Reselected local PDF';
 const dialog=await choosePDF(page,title+'.pdf',bytes);
 await expect(page.getByTestId('add-outcome')).toContainText('PDF stays on this device');
 await dialog.getByRole('button',{name:'Done',exact:true}).click();
 const row=page.getByTestId('paper-row').filter({hasText:title});
 await expect(row).toBeVisible();
 await page.reload();await expect(row).toContainText('Choose PDF on this device');
 const choose=async(buffer:Buffer)=>{const waiting=page.waitForEvent('filechooser');await row.getByRole('link',{name:title,exact:true}).click();await (await waiting).setFiles({name:title+'.pdf',mimeType:'application/pdf',buffer});};
 pdf.addPage();await choose(Buffer.from(await pdf.save()));
 await expect(page.getByText('This PDF has a different page count.',{exact:false})).toBeVisible();
 await choose(bytes);await expect(row).not.toContainText('Choose PDF on this device');
 await expect(page.getByTestId('paper-row')).toHaveCount(before+1);
 guard.assertPrivate([title,'Local private content canary','Malformed private file']);
});
