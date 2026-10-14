import {readFileSync} from 'node:fs';
import {expect,test} from '@playwright/test';
import {RECOVERY_CODE} from './fixture-keys.mjs';
import {fixtureOrigin} from './environment';
import {durableKeys} from './key-capability';
const html=readFileSync(new URL('../../../tests/fixtures/reader-arxiv/source.html',import.meta.url));
const raster=readFileSync(new URL('../../../tests/fixtures/reader-mathpix/figure-exif.jpg',import.meta.url));
const member='58000000-0000-4000-8000-000000000003';
test('official pinned HTML opens in the existing reader without any PDF, OCR or artifact request',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 await request.post(`${fixtureOrigin}/__reset`);
 let sourceRequests=0,pdfRequests=0,artifacts=0;
 page.on('request',r=>{if(/upload-pdf|\/pdf\//.test(r.url()))pdfRequests++;if(r.url().includes('/reader-artifact'))artifacts++;});
 await page.route('https://arxiv.org/**',async route=>{
  const url=route.request().url();sourceRequests++;
  if(url==='https://arxiv.org/html/2601.01234v2')await route.fulfill({status:200,contentType:'text/html',headers:{'access-control-allow-origin':'*'},body:html});
  else if(url==='https://arxiv.org/html/2601.01234v2/figure.jpg')await route.fulfill({status:200,contentType:'image/jpeg',headers:{'access-control-allow-origin':'*'},body:raster});
  else throw Error('Unexpected source acquisition '+url);
 });
 await page.route(`${fixtureOrigin}/rest/v1/rpc/v3_library_page`,async route=>{
  const response=await route.fetch(),body=await response.json();
  const row=body.entries.find((e:{kind:string})=>e.kind==='item');
  body.entries=[{kind:'import',id:member,created_seq:row.created_seq,state_seq:row.state_seq,intent_revision:1,visible:true,phase:'source_only',source:'arxiv',source_id:'2601.01234',requested_revision:2,source_revision:2,
   metadata_id:row.metadata_id,version_id:row.version_id,metadata_recorded_at:row.metadata_recorded_at,source_url:'https://arxiv.org/abs/2601.01234v2',retryable:false,metadata:{title:'Authored HTML fixture',authors:['Fixture author'],categories:['cs.LG']}}];
  body.has_more=false;body.next_cursor={format:2,account_id:body.account_id,through:body.baseline_cursor,created_seq:row.created_seq,id:member,kind:'import'};
  await route.fulfill({response,json:body});
 });
 // Keep the complete fixture baseline stable while this one synthetic membership is presented.
 await page.route(`${fixtureOrigin}/rest/v1/rpc/v3_library_changes`,async route=>{const response=await route.fetch(),body=await response.json();body.changes=[];body.has_more=false;body.next_cursor=body.through;await route.fulfill({response,json:body});});
 await page.goto('/');await page.getByTestId('email').fill('returning@example.test');await page.getByTestId('send-code').click();
 await page.getByTestId('code').fill('123456');await page.getByTestId('verify').click();
 await page.getByTestId('use-recovery-code').click();await page.getByTestId('recovery-code').fill(RECOVERY_CODE);await page.getByTestId('recover').click();
 await page.getByTestId('library-table').getByRole('link',{name:'Authored HTML fixture',exact:true}).click();
 const frame=page.frameLocator('[data-testid=reader-frame]');
 await expect(frame.locator('math').first()).toBeVisible({timeout:20000});
 await expect(frame.locator('img').first()).toBeVisible();
 await expect(frame.locator('[data-reader-block]')).not.toHaveCount(0);
 expect(sourceRequests).toBe(2);expect(pdfRequests).toBe(0);expect(artifacts).toBe(0);
 if(!await page.getByTestId('chat-pane').isVisible())await page.getByTestId('ask').click();
 await page.getByRole('textbox',{name:'Message',exact:true}).fill('Explain the authored equation.');
 await page.getByRole('button',{name:'Send',exact:true}).click();
 await page.getByRole('button',{name:'Allow and get answer'}).click();
 await expect(page.getByTestId('chat-pane').getByRole('region',{name:'Conversation'})).toContainText('objective');
 const evidence=await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json();
 expect(evidence.requests[0].mode).toBe('paper');expect(evidence.requests[0].document_id).toBeUndefined();
 expect(evidence.requests[0].local_context).toMatchObject({format:'reader-local-context-v1',membership_id:member,source_id:'2601.01234',revision:2});
 expect(JSON.stringify(evidence.events)).not.toContain('Explain the authored equation');
 expect(pdfRequests).toBe(0);expect(artifacts).toBe(0);
 await page.screenshot({path:`../../.artifacts/html-browser-${test.info().project.name}.png`});
});
