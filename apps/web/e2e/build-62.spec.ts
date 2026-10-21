// Build 62 owner feedback in the browser (docs/OWNER_FEEDBACK.md "Build 62"): the reader's ⋯ › Reader version details
// instead of a banner (READER_VERSIONS.md), with Update this paper keeping the copy on screen until the new one is ready;
// and Your assets › Equation explanations / Figure explanations, this tab's, each reopening its paper there without a
// new request. Local fixtures only.
import {readFileSync} from 'node:fs';
import {expect,test,type APIRequestContext,type Page} from '@playwright/test';
import shipped from '../../apple/ScienceReader/Resources/arxiv-reader-build.json' with {type:'json'};
import {RECOVERY_CODE} from './fixture-keys.mjs';
import {fixtureOrigin} from './environment';
import {durableKeys} from './key-capability';
const html=readFileSync(new URL('../../../tests/fixtures/reader-arxiv/source.html',import.meta.url));
const raster=readFileSync(new URL('../../../tests/fixtures/reader-mathpix/figure-exif.jpg',import.meta.url));
const member='58000000-0000-4000-8000-000000000003';
const SHOTS='../../.artifacts/web-build62';

async function signIn(page:Page){
 await page.goto('/');await page.getByTestId('email').fill('returning@example.test');await page.getByTestId('send-code').click();
 await page.getByTestId('code').fill('123456');await page.getByTestId('verify').click();
 await page.getByTestId('use-recovery-code').click();await page.getByTestId('recovery-code').fill(RECOVERY_CODE);await page.getByTestId('recover').click();
}

test('Reader version details: this paper’s version and this browser’s; an older copy updates in place, and a failed update says why',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 await request.post(`${fixtureOrigin}/__reset`);
 // The DPO item opens from the server's copy while arXiv is unreachable (an older reader's copy); then arXiv answers.
 let arxiv:'down'|'up'='down';
 const source=html.toString('utf8').replace('2601.01234v2/figure.jpg','2305.18290v3/figure.jpg');
 await page.route('https://arxiv.org/**',async route=>{
  if(arxiv==='down')return route.abort();
  const url=route.request().url(),headers={'access-control-allow-origin':'*'};
  if(url==='https://arxiv.org/html/2305.18290v3')return route.fulfill({status:200,contentType:'text/html',headers,body:source});
  if(url==='https://arxiv.org/html/2305.18290v3/figure.jpg')return route.fulfill({status:200,contentType:'image/jpeg',headers,body:raster});
  return route.fulfill({status:404,headers,body:''});
 });
 await signIn(page);
 await page.getByTestId('library-table').getByRole('link',{name:/^Direct Preference Optimization/}).click();
 const frame=page.frameLocator('[data-testid=reader-frame]');
 await expect(frame.locator('h1').first()).toBeVisible({timeout:20000});
 const before=await frame.locator('h1').first().textContent();
 // No banner over a working reader (owner, build 62): the details are in the paper's ⋯.
 await expect(page.getByText(/newer reader|prepared again/i)).toHaveCount(0);
 await page.locator('.reader-actions').getByRole('button',{name:/^Actions for/}).click();
 const item=page.getByRole('menu',{name:'Paper actions'}).getByRole('menuitem',{name:'Reader version details'});
 await expect(page.getByRole('menu',{name:'Paper actions'}).getByRole('menuitem').first()).toHaveText('Reader version details');
 await item.click();
 const sheet=page.getByRole('dialog',{name:'Reader version'});
 await expect(sheet.getByTestId('reader-version-paper')).toHaveText('An earlier version');
 await expect(sheet.getByTestId('reader-version-browser')).toHaveText(`Version ${shipped.revision}`);
 await expect(sheet.getByTestId('reader-version-changes').locator('li').first()).toContainText(`Version ${shipped.revision}`);
 await page.screenshot({path:`${SHOTS}/version-details-${test.info().project.name}.png`});

 // arXiv unreachable: the update fails with its reason and code; the copy being read stays.
 await sheet.getByTestId('reader-version-update').click();
 await expect(sheet.getByTestId('reader-version-failure')).toContainText('Couldn’t retrieve this paper from arXiv.');
 await expect(sheet.getByTestId('reader-version-failure')).toContainText('Code: retrieval');
 await expect(frame.locator('h1').first()).toHaveText(before!);
 await page.screenshot({path:`${SHOTS}/version-update-failed-${test.info().project.name}.png`});

 // arXiv answers: prepared again with this browser's reader, replacing the copy in place.
 arxiv='up';
 await sheet.getByTestId('reader-version-update').click();
 await expect(sheet.getByTestId('reader-version-latest')).toHaveText('Updated. This paper uses the latest reader.',{timeout:20000});
 await expect(sheet.getByTestId('reader-version-paper')).toHaveText(`Version ${shipped.revision}`);
 await expect(sheet.getByTestId('reader-version-update')).toHaveCount(0);await expect(sheet.getByTestId('reader-version-failure')).toHaveCount(0);
 await page.emulateMedia({colorScheme:'dark'});
 await page.screenshot({path:`${SHOTS}/version-updated-${test.info().project.name}-dark.png`});
 await page.emulateMedia({colorScheme:'light'});
 await sheet.getByTestId('reader-version-close').click();await expect(sheet).toBeHidden();
 await expect(frame.locator('h1').first()).toHaveText('Authored HTML fixture',{timeout:20000});
 // Opened again: the latest reader, nothing to update.
 await page.locator('.reader-actions').getByRole('button',{name:/^Actions for/}).click();
 await page.getByRole('menuitem',{name:'Reader version details'}).click();
 await expect(sheet.getByTestId('reader-version-latest')).toBeVisible();await expect(sheet.getByTestId('reader-version-changes')).toHaveCount(0);
});

/** The authored arXiv fixture as a source membership (the official HTML this browser prepares). */
async function openFixture(page:Page,request:APIRequestContext){
 await request.post(`${fixtureOrigin}/__reset`);
 await page.route('https://arxiv.org/**',async route=>{
  const url=route.request().url(),headers={'access-control-allow-origin':'*'};
  if(url==='https://arxiv.org/html/2601.01234v2')await route.fulfill({status:200,contentType:'text/html',headers,body:html});
  else if(url==='https://arxiv.org/html/2601.01234v2/figure.jpg')await route.fulfill({status:200,contentType:'image/jpeg',headers,body:raster});
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
 await page.route(`${fixtureOrigin}/rest/v1/rpc/v3_library_changes`,async route=>{const response=await route.fetch(),body=await response.json();body.changes=[];body.has_more=false;body.next_cursor=body.through;await route.fulfill({response,json:body});});
 await signIn(page);
 await page.getByTestId('library-table').getByRole('link',{name:'Authored HTML fixture',exact:true}).click();
}

test('Your assets › Equation and Figure explanations list this tab’s, newest first, and each reopens there without a new request',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 await openFixture(page,request);
 const frame=page.frameLocator('[data-testid=reader-frame]');
 const display=frame.locator('.reader-display[data-reader-equation]').first();
 await expect(display).toBeVisible({timeout:20000});
 const chats=async()=>(await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json()).requests as Record<string,unknown>[];

 // A tapped equation also offers Copy as Text: the formula as the paper writes it (B10, the apps' equation menu).
 if(test.info().project.name!=='webkit')await page.context().grantPermissions(['clipboard-read','clipboard-write']);
 await display.click();await page.getByTestId('equation-copy').click();
 await expect(page.locator('.toast')).toHaveText('Copied.');
 if(test.info().project.name!=='webkit')expect(await page.evaluate(()=>navigator.clipboard.readText())).toMatch(/\\\[|\\\(|\\begin/);
 // An equation explained (AI Explainer from its menu, after the consent), then a figure.
 await display.click();await page.getByTestId('equation-open').click();
 const view=page.getByTestId('equation-view');
 // AI Explainer asks which model first (B7): Default.
 await expect(page.getByRole('dialog',{name:'AI model'})).toBeVisible();await page.getByTestId('explainer-default').click();
 await view.getByRole('button',{name:'Allow and explain'}).click();
 await expect(view.getByTestId('equation-summary')).toBeVisible();
 await view.getByTestId('equation-close').click();await expect(view).toBeHidden();
 await page.getByTestId('figures').click();
 const viewer=page.getByRole('dialog',{name:'Figures'});
 await viewer.getByRole('list',{name:'Figures'}).getByRole('button').first().click();
 await viewer.getByTestId('figure-explain').click();await page.getByTestId('explainer-default').click();
 await expect(viewer.getByTestId('figure-walkthrough').locator('.figure-section')).toHaveCount(3);
 await viewer.getByTestId('figure-close').click();await expect(viewer).toBeHidden();
 expect(await chats()).toHaveLength(2);

 // From the library: the account menu's lists name each with its paper; a row opens the paper there.
 await page.getByTestId('back-to-library').click();await expect(page.getByTestId('library-table')).toBeVisible();
 await page.getByTestId('account-menu').click();await page.getByTestId('assets-equations').click();
 let kept=page.getByRole('dialog',{name:'Equation explanations'});
 await expect(kept.getByTestId('explanations-list').getByRole('button')).toHaveCount(1);
 await expect(kept.getByTestId('explanations-list').getByRole('button').first()).toContainText('Equation (1)');
 await expect(kept.getByTestId('explanations-list').getByRole('button').first()).toContainText('Authored HTML fixture');
 await page.screenshot({path:`${SHOTS}/equation-explanations-${test.info().project.name}.png`});
 await kept.getByTestId('explanations-list').getByRole('button').first().click();
 await expect(kept).toBeHidden();
 await expect(view.getByRole('heading',{name:'Equation (1)'})).toBeVisible({timeout:20000});
 await expect(view.getByTestId('equation-summary')).toBeVisible();await expect(view.getByTestId('equation-explain')).toHaveCount(0);
 await view.getByTestId('equation-close').click();

 await page.getByTestId('back-to-library').click();await expect(page.getByTestId('library-table')).toBeVisible();
 await page.emulateMedia({colorScheme:'dark'});
 await page.getByTestId('account-menu').click();await page.getByTestId('assets-figures').click();
 kept=page.getByRole('dialog',{name:'Figure explanations'});
 await expect(kept.getByTestId('explanations-list').getByRole('button')).toHaveCount(1);
 await expect(kept.getByTestId('explanations-list').getByRole('button').first()).toContainText('Figure 1');
 await page.screenshot({path:`${SHOTS}/figure-explanations-${test.info().project.name}-dark.png`});
 await page.emulateMedia({colorScheme:'light'});
 await kept.getByTestId('explanations-list').getByRole('button').first().click();
 await expect(viewer.getByTestId('figure-walkthrough').locator('.figure-section')).toHaveCount(3,{timeout:20000});
 await expect(viewer.getByTestId('figure-explain')).toHaveCount(0);
 expect(await chats()).toHaveLength(2);
});
