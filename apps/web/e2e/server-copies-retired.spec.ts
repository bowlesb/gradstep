// The server's paper copies were deleted on 2026-10-16 (docs/architecture/DATA_HANDLING_AND_COSTS.md "Server paper
// copies: retired"): the library projection says unavailable and reader-artifact answers 403 reader_unavailable.
// A legacy arXiv item still opens from arXiv on this device and its questions send this device's text; one whose
// revision has no arXiv HTML offers the PDF from arXiv, never "isn't ready" and never the server; a paper from
// another site says it has no reading copy.
import {readFileSync} from 'node:fs';
import {expect,test,type Page} from '@playwright/test';
import {RECOVERY_CODE} from './fixture-keys.mjs';
import {fixtureOrigin} from './environment';
import {durableKeys} from './key-capability';
const html=readFileSync(new URL('../../../tests/fixtures/reader-arxiv/source.html',import.meta.url));
const raster=readFileSync(new URL('../../../tests/fixtures/reader-mathpix/figure-exif.jpg',import.meta.url));
const legacy='aaaaaaaa-0000-4000-8000-000000000001', web='aaaaaaaa-0000-4000-8000-0000000000ee';

/** The returning account's library after retirement: its DPO item renamed to the authored HTML revision, with the
 * server copy unavailable at a newer revision (ids kept), and a paper from another site in the same state. */
async function retiredLibrary(page:Page,{render='unavailable'}:{render?:string}={}){
 const artifacts:string[]=[];
 await page.route(`${fixtureOrigin}/functions/v1/reader-artifact**`,async route=>{artifacts.push(route.request().url());
  await route.fulfill({status:403,contentType:'application/json',headers:{'access-control-allow-origin':'*'},body:JSON.stringify({code:'reader_unavailable'})});});
 await page.route(`${fixtureOrigin}/rest/v1/rpc/v3_library_page`,async route=>{
  const response=await route.fetch(),body=await response.json();
  const row=body.entries.find((e:{kind:string;id:string})=>e.kind==='item'&&e.id===legacy);
  const state={readiness:render==='available'?'converted_ready':'unavailable',render_availability:render,original_availability:render,
   render_availability_revision:2,original_availability_revision:2};
  const item={...row,...state,source_id:'2601.01234',source_revision:2,source_url:'https://arxiv.org/abs/2601.01234v2',
   metadata:{title:'A paper from before the HTML reader',authors:['Fixture author'],categories:['cs.LG']}};
  const other={...row,...state,id:web,document_id:'cccccccc-0000-4000-8000-0000000000ee',source:'web',
   source_id:'openalex:W2741809807',source_revision:1,source_url:'https://example.org/paper',metadata:{title:'An open-access paper from another site',authors:['Other author'],categories:[]}};
  body.entries=[item,other];body.has_more=false;
  body.next_cursor={format:2,account_id:body.account_id,through:body.baseline_cursor,created_seq:other.created_seq,id:web,kind:'item'};
  await route.fulfill({response,json:body});
 });
 await page.route(`${fixtureOrigin}/rest/v1/rpc/v3_library_changes`,async route=>{const response=await route.fetch(),body=await response.json();body.changes=[];body.has_more=false;body.next_cursor=body.through;await route.fulfill({response,json:body});});
 await page.goto('/');await page.getByTestId('email').fill('returning@example.test');await page.getByTestId('send-code').click();
 await page.getByTestId('code').fill('123456');await page.getByTestId('verify').click();
 await page.getByTestId('use-recovery-code').click();await page.getByTestId('recovery-code').fill(RECOVERY_CODE);await page.getByTestId('recover').click();
 await expect(page.getByTestId('library-table')).toBeVisible({timeout:20000});
 return artifacts;
}

test('a legacy arXiv item opens from arXiv and asks with this device\'s text; nothing asks the server for a copy',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 await request.post(`${fixtureOrigin}/__reset`);
 await page.route('https://arxiv.org/**',async route=>{
  const url=route.request().url();
  if(url==='https://arxiv.org/html/2601.01234v2')await route.fulfill({status:200,contentType:'text/html',headers:{'access-control-allow-origin':'*'},body:html});
  else if(url==='https://arxiv.org/html/2601.01234v2/figure.jpg')await route.fulfill({status:200,contentType:'image/jpeg',headers:{'access-control-allow-origin':'*'},body:raster});
  else throw Error('Unexpected source acquisition '+url);
 });
 const artifacts=await retiredLibrary(page);
 const table=page.getByTestId('library-table');
 // The row opens, and says it downloads from arXiv when opened.
 const legacyRow=table.getByTestId('paper-row').filter({hasText:'A paper from before the HTML reader'});
 await expect(legacyRow.getByTestId('device-badge')).toHaveAttribute('aria-label','Not on this device yet; downloads when you open it');
 await table.getByRole('link',{name:'A paper from before the HTML reader',exact:true}).click();
 const frame=page.frameLocator('[data-testid=reader-frame]');
 await expect(frame.locator('math').first()).toBeVisible({timeout:20000});
 if(!await page.getByTestId('chat-pane').isVisible())await page.getByTestId('ask').click();
 await page.getByRole('textbox',{name:'Message',exact:true}).fill('Explain the authored equation.');
 await page.getByRole('button',{name:'Send',exact:true}).click();
 await page.getByRole('button',{name:'Allow and get answer'}).click();
 await expect(page.getByTestId('chat-pane').getByRole('region',{name:'Conversation'})).toContainText('objective');
 const evidence=await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json();
 const asked=evidence.requests.at(-1);
 expect(asked.mode).toBe('paper');expect(asked.document_id).toBeUndefined();
 expect(asked.local_context).toMatchObject({format:'reader-local-context-v2',membership_id:legacy,source_id:'2601.01234',revision:2});
 expect(artifacts).toEqual([]);
});

for(const render of ['unavailable','available'])
test(`a legacy arXiv item without arXiv HTML offers the PDF from arXiv (library says ${render})`,async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 await request.post(`${fixtureOrigin}/__reset`);
 await page.route('https://arxiv.org/**',async route=>{await route.fulfill({status:404,contentType:'text/html',headers:{'access-control-allow-origin':'*'},body:'<p>No HTML</p>'});});
 const artifacts=await retiredLibrary(page,{render});
 await page.getByTestId('library-table').getByRole('link',{name:'A paper from before the HTML reader',exact:true}).click();
 await expect(page.getByRole('heading',{name:'No web version of this paper'})).toBeVisible({timeout:20000});
 await expect(page.getByTestId('reader-open-pdf')).toHaveAttribute('href','https://arxiv.org/pdf/2601.01234v2');
 await expect(page.getByText('isn’t ready to read yet')).toHaveCount(0);
 // A stale "available" asks the server once and keeps arXiv's answer when it has no copy; "unavailable" never asks.
 expect(artifacts.length).toBe(render==='available'?1:0);
});

test('a paper from another site says it has no reading copy and does not open',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 await request.post(`${fixtureOrigin}/__reset`);
 await page.route('https://arxiv.org/**',async route=>{throw Error('Unexpected arXiv request '+route.request().url());});
 const artifacts=await retiredLibrary(page);
 const row=page.getByTestId('library-table').getByTestId('paper-row').filter({hasText:'An open-access paper from another site'});
 await expect(row).toContainText('No reading copy');
 await expect(row.getByTestId('device-badge')).toHaveAttribute('aria-label','No readable copy on this device');
 await expect(row.getByRole('link',{name:'An open-access paper from another site',exact:true})).toHaveCount(0);
 expect(artifacts).toEqual([]);
});
