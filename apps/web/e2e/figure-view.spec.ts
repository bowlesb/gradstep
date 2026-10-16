// The figure view (docs/architecture/FIGURE_VIEW.md): the figure page offers Explain and Ask in chat side by side and
// asks nothing of the AI on opening; Explain (after the chat's consent) walks through the figure part by part with a
// crop where the model drew a box; a part's ⋯ explains it more simply, shows it in the paper (with Back) or starts a chat
// draft about it. Both requests are the chat's own (its capabilities, with figure_view, and exactly this figure).
import {readFileSync} from 'node:fs';
import {expect,test,type APIRequestContext,type Page} from '@playwright/test';
import {RECOVERY_CODE} from './fixture-keys.mjs';
import {fixtureOrigin} from './environment';
import {durableKeys} from './key-capability';
const html=readFileSync(new URL('../../../tests/fixtures/reader-arxiv/source.html',import.meta.url));
const raster=readFileSync(new URL('../../../tests/fixtures/reader-mathpix/figure-exif.jpg',import.meta.url));
const member='58000000-0000-4000-8000-000000000003';
// The authored arXiv fixture as a source membership (the official HTML this browser prepares), as the equation journey.
async function openFixture(page:Page,request:APIRequestContext){
 await request.post(`${fixtureOrigin}/__reset`);
 await page.route('https://arxiv.org/**',async route=>{
  const url=route.request().url();
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
 await page.route(`${fixtureOrigin}/rest/v1/rpc/v3_library_changes`,async route=>{const response=await route.fetch(),body=await response.json();body.changes=[];body.has_more=false;body.next_cursor=body.through;await route.fulfill({response,json:body});});
 await page.goto('/');await page.getByTestId('email').fill('returning@example.test');await page.getByTestId('send-code').click();
 await page.getByTestId('code').fill('123456');await page.getByTestId('verify').click();
 await page.getByTestId('use-recovery-code').click();await page.getByTestId('recovery-code').fill(RECOVERY_CODE);await page.getByTestId('recover').click();
 await page.getByTestId('library-table').getByRole('link',{name:'Authored HTML fixture',exact:true}).click();
}
/** The figure page from Contents › Figures › its row (the same page a tapped figure and the gallery open). */
async function openFigure(page:Page){
 const tabs=page.getByRole('tablist',{name:'Show',exact:true});
 await expect(page.getByTestId('contents')).toBeEnabled();
 if(!await tabs.isVisible())await page.getByTestId('contents').click();
 await tabs.getByRole('tab',{name:'Figures'}).click();
 await page.getByTestId('contents-figure-0').click();
 const viewer=page.getByRole('dialog',{name:'Figures'});
 await expect(viewer.frameLocator('iframe.figure-frame').locator('figcaption')).toContainText('A test figure.');
 return viewer;
}

test('a figure is explained only on request, part by part with its crop; a part goes simpler, up close, into the paper and into the chat',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 const errors:string[]=[];page.on('pageerror',e=>errors.push(String(e)));
 await openFixture(page,request);
 const frame=page.frameLocator('[data-testid=reader-frame]');
 await expect(frame.locator('figure').first()).toBeVisible({timeout:20000});
 const chats=async()=>(await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json()).requests as Record<string,any>[];

 // The figure page: Explain and Ask in chat side by side under the figure; nothing is asked on opening.
 let viewer=await openFigure(page);
 const explain=viewer.getByTestId('figure-explain'),ask=viewer.getByTestId('figure-ask');
 await expect(explain).toHaveText('Explain');await expect(ask).toHaveText('Ask in chat');
 const [explainBox,askBox]=[(await explain.boundingBox())!,(await ask.boundingBox())!];
 expect(Math.abs(explainBox.y-askBox.y)).toBeLessThan(2);expect(explainBox.x).toBeLessThan(askBox.x);
 await expect(viewer.getByTestId('figure-walkthrough')).toHaveCount(0);
 await page.waitForTimeout(500);expect(await chats()).toHaveLength(0);
 await page.screenshot({path:`../../.artifacts/figure-view-opened-${test.info().project.name}.png`});

 // Explain asks the chat's own consent first; nothing is sent before it.
 await explain.click();
 await expect(viewer.getByTestId('figure-consent')).toBeVisible();expect(await chats()).toHaveLength(0);
 await viewer.getByRole('button',{name:'Allow and explain'}).click();
 const walk=viewer.getByTestId('figure-walkthrough');
 await expect(viewer.getByTestId('figure-summary')).toContainText('The figure compares two pipelines');
 await expect(walk.locator('.figure-section')).toHaveCount(3);
 await expect(viewer.getByTestId('figure-section-0').locator('h4')).toHaveText('(a)The three-stage pipeline');
 await expect(viewer.getByTestId('figure-section-2').locator('h4')).toHaveText('Legend');
 // The one boxed part carries its crop (the right half of the image that was sent); the others none.
 await expect(walk.getByTestId('figure-crop')).toHaveCount(1);
 const crop=viewer.getByTestId('figure-section-1').getByTestId('figure-crop');
 await expect(crop).toBeVisible();
 expect(await crop.evaluate(e=>{const s=getComputedStyle(e);return [s.backgroundSize,s.backgroundPositionX,s.backgroundPositionY,s.backgroundImage.startsWith('url("data:image/jpeg;base64,')];})).toEqual(['200% 100%','100%','0%',true]);
 // Math is typeset, [¶N] is a link; Explain has gone, Ask in chat stays; no credit counts (owner, build 59).
 await expect(viewer.getByTestId('figure-section-1').locator('math')).toBeVisible();
 await expect(viewer.getByTestId('figure-section-0').locator('.cite')).toHaveText('¶2');
 await expect(explain).toHaveCount(0);await expect(ask).toBeVisible();
 await expect(viewer).not.toContainText(/\d+\s+credits?\b/);
 // The figure gets smaller while its walkthrough shows, so the words are in view.
 expect((await viewer.locator('iframe.figure-frame').boundingBox())!.height).toBeLessThan(470);
 await expect(viewer.getByRole('heading',{name:'What it shows'})).toBeInViewport();
 let sent=await chats();
 expect(sent).toHaveLength(1);
 expect(sent[0]).toMatchObject({action:'figure',mode:'paper',consent_version:'cloud-ai-v4',selection:{quote:'Figure 1: A test figure.'},messages:[{role:'user',text:'Figure 1'}],
  local_context:{format:'reader-local-context-v2',membership_id:member}});
 expect(sent[0].capabilities).toContain('figure_view');expect(sent[0].figures).toHaveLength(1);
 expect(sent[0].figures[0]).toMatchObject({id:'F1',media_type:'image/jpeg'});
 for(const key of ['topic_title','follow_ups','document_id'])expect(sent[0]).not.toHaveProperty(key);
 await page.screenshot({path:`../../.artifacts/figure-view-${test.info().project.name}.png`});

 // A part's ⋯: Explain more simply streams under that part.
 await viewer.getByTestId('figure-section-menu-0').click();
 const menu=page.getByRole('menu',{name:'(a) · The three-stage pipeline: options'});
 await expect(menu.getByRole('menuitem')).toHaveText(['Explain more simply','Extract the subfigure and more context','Show in the paper','Ask in chat about this']);
 await menu.getByRole('menuitem',{name:'Explain more simply'}).click();
 const simpler=viewer.getByTestId('figure-section-0').getByTestId('figure-simpler');
 await expect(simpler).toContainText('is a second network that learns to score answers');
 await expect(simpler.locator('strong')).toHaveText('reward model');
 sent=await chats();
 expect(sent[1]).toMatchObject({action:'figure_simpler',selection:{quote:'Read left to right: preference data trains a **reward model**, which then scores samples for reinforcement learning [¶2].'},
  messages:[{role:'user',text:'Figure 1 (a)'}]});
 expect(sent[1].capabilities).toEqual(sent[0].capabilities);expect(sent[1].figures).toHaveLength(1);
 await page.screenshot({path:`../../.artifacts/figure-view-simpler-${test.info().project.name}.png`});
 // Extract the subfigure and more context (owner, TestFlight 62): a loader under the part, then its crop and the closer
 // reading; a part with no region (the Legend) gets the words and says it couldn't crop.
 await viewer.getByTestId('figure-section-menu-0').click();
 await page.getByRole('menu').getByRole('menuitem',{name:'Extract the subfigure and more context'}).click();
 const closer=viewer.getByTestId('figure-section-0').getByTestId('figure-detail');
 await expect(closer.getByRole('status')).toHaveText('Extracting this part…');
 await expect(closer).toContainText('three boxes joined by arrows');
 const closerCrop=closer.getByTestId('figure-detail-crop');
 await expect(closerCrop).toBeVisible();
 expect(await closerCrop.evaluate(e=>{const s=getComputedStyle(e);return [s.backgroundSize,s.backgroundPositionX,s.backgroundPositionY];})).toEqual(['200% 100%','0%','0%']);
 await expect(closer.getByTestId('figure-detail-no-crop')).toHaveCount(0);
 await expect(viewer).not.toContainText(/\d+\s+credits?\b/);
 sent=await chats();
 expect(sent[2]).toMatchObject({action:'figure_detail',selection:{quote:'(a) The three-stage pipeline\nRead left to right: preference data trains a **reward model**, which then scores samples for reinforcement learning [¶2].'},
  messages:[{role:'user',text:'Figure 1 (a)'}]});
 expect(sent[2].capabilities).toEqual(sent[0].capabilities);expect(sent[2].figures).toHaveLength(1);
 for(const key of ['topic_title','follow_ups'])expect(sent[2]).not.toHaveProperty(key);
 await closer.scrollIntoViewIfNeeded();
 await page.screenshot({path:`../../.artifacts/figure-view-detail-${test.info().project.name}.png`});
 await viewer.getByTestId('figure-section-menu-2').click();
 await page.getByRole('menu').getByRole('menuitem',{name:'Extract the subfigure and more context'}).click();
 const legend=viewer.getByTestId('figure-section-2').getByTestId('figure-detail');
 await expect(legend.getByTestId('figure-detail-no-crop')).toBeVisible();
 await expect(legend).toContainText('arrows for data flow');await expect(legend.getByTestId('figure-detail-crop')).toHaveCount(0);
 // Dark: the page, the parts and the crop follow the app's appearance.
 await page.emulateMedia({colorScheme:'dark'});
 await viewer.getByTestId('figure-section-1').scrollIntoViewIfNeeded();
 await page.screenshot({path:`../../.artifacts/figure-view-${test.info().project.name}-dark.png`});
 await page.emulateMedia({colorScheme:'light'});

 // Show in the paper: the page closes and the paper lands on the part's paragraph, with Back unless it was in view.
 await viewer.getByTestId('figure-section-menu-0').click();
 await page.getByRole('menu').getByRole('menuitem',{name:'Show in the paper'}).click();
 await expect(viewer).toBeHidden();

 // Reopened: the walkthrough and the simpler part come back without a new request.
 viewer=await openFigure(page);
 await expect(viewer.getByTestId('figure-walkthrough').locator('.figure-section')).toHaveCount(3);
 await expect(viewer.getByTestId('figure-section-0').getByTestId('figure-simpler')).toContainText('second network');
 await expect(viewer.getByTestId('figure-section-0').getByTestId('figure-detail-crop')).toBeVisible();
 await expect(viewer.getByTestId('figure-explain')).toHaveCount(0);
 expect(await chats()).toHaveLength(4);

 // Ask in chat about this: an unsent draft about that part, the composer focused; nothing is sent.
 await viewer.getByTestId('figure-section-menu-2').click();
 await page.getByRole('menu').getByRole('menuitem',{name:'Ask in chat about this'}).click();
 await expect(viewer).toBeHidden();
 const composer=page.getByRole('textbox',{name:'Message',exact:true});
 await expect(composer).toBeVisible();await expect(composer).toHaveValue('About “Arrows show where data flows; the trophy marks the preferred response.”: ');
 await expect(composer).toBeFocused();
 expect(await chats()).toHaveLength(4);
 expect(errors).toEqual([]);
});

test('a failed walkthrough says so and can be tried again; the figure page’s Ask in chat drafts about the caption',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 await openFixture(page,request);
 await expect(page.frameLocator('[data-testid=reader-frame]').locator('figure').first()).toBeVisible({timeout:20000});
 // The provider fails the first walkthrough (nothing charged); Try again asks once more.
 let failures=1;
 await page.route(`${fixtureOrigin}/functions/v1/chat`,async route=>{
  if(route.request().method()==='POST'&&failures>0){failures--;await route.fulfill({status:200,headers:{'content-type':'text/event-stream','access-control-allow-origin':'*'},
   body:'event: error\ndata: {"code":"provider_unavailable","credits":0,"charged":false,"reason":"provider"}\n\n'});return;}
  await route.fallback();
 });
 let viewer=await openFigure(page);
 await viewer.getByTestId('figure-explain').click();
 if(await viewer.getByTestId('figure-consent').isVisible())await viewer.getByRole('button',{name:'Allow and explain'}).click();
 await expect(viewer.getByTestId('figure-issue')).toContainText('The AI service couldn’t finish this answer. Try again.');
 await viewer.getByTestId('figure-retry').click();
 await expect(viewer.getByTestId('figure-walkthrough').locator('.figure-section')).toHaveCount(3);
 await expect(viewer.getByTestId('figure-issue')).toHaveCount(0);
 await viewer.getByTestId('figure-ask').click();
 await expect(viewer).toBeHidden();
 await expect(page.getByRole('textbox',{name:'Message',exact:true})).toHaveValue('About “Figure 1: A test figure.”: ');
});

test('without a walkthrough the words show as the description; cut off at its length, it says it wasn’t charged',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 await openFixture(page,request);
 await expect(page.frameLocator('[data-testid=reader-frame]').locator('figure').first()).toBeVisible({timeout:20000});
 await page.route(`${fixtureOrigin}/functions/v1/chat`,async route=>{
  if(route.request().method()!=='POST')return route.fallback();
  await route.fulfill({status:200,headers:{'content-type':'text/event-stream','access-control-allow-origin':'*'},
   body:'event: delta\ndata: {"text":"The figure shows **two pipelines** side by side [¶2]."}\n\nevent: done\ndata: {"stop_reason":"max_tokens","credits":0,"charged":false,"reason":"limit"}\n\n'});
 });
 const viewer=await openFigure(page);
 await viewer.getByTestId('figure-explain').click();
 if(await viewer.getByTestId('figure-consent').isVisible())await viewer.getByRole('button',{name:'Allow and explain'}).click();
 await expect(viewer.getByTestId('figure-words')).toContainText('The figure shows two pipelines side by side');
 await expect(viewer.getByTestId('figure-walkthrough').locator('.figure-section')).toHaveCount(0);
 await expect(viewer.getByTestId('figure-note')).toHaveText('Interrupted · not charged');
 await expect(viewer).not.toContainText(/\d+\s+credits?\b/);
});
