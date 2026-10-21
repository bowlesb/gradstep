// The figure view (docs/architecture/FIGURE_VIEW.md): the figure page's one top row offers Explain in Chat and AI
// Explainer beside the X (owner, build 62) and asks nothing of the AI on opening; AI Explainer (after the chat's consent)
// walks through the figure part by part with a crop where the model drew a box, under a heading that switches to the
// paper's other figures; a part's ⋯ explains it more simply, shows it in the paper (with Back) or starts a chat draft
// about it. A figure reference in the text offers the same two actions. Both requests are the chat's own (its
// capabilities, with figure_view, and exactly this figure).
import {readFileSync} from 'node:fs';
import {expect,test,type APIRequestContext,type Page} from '@playwright/test';
import {RECOVERY_CODE} from './fixture-keys.mjs';
import {fixtureOrigin} from './environment';
import {durableKeys} from './key-capability';
const html=readFileSync(new URL('../../../tests/fixtures/reader-arxiv/source.html',import.meta.url));
const raster=readFileSync(new URL('../../../tests/fixtures/reader-mathpix/figure-exif.jpg',import.meta.url));
const member='58000000-0000-4000-8000-000000000003';
// A second figure, for the walkthrough's heading menu.
const twoFigures=html.toString('utf8').replace('<figure id="tab1">','<figure id="S1.F2"><img src="2601.01234v2/figure.jpg"><figcaption>Figure 2: A second figure.</figcaption></figure><figure id="tab1">');
// The authored arXiv fixture as a source membership (the official HTML this browser prepares), as the equation journey.
async function openFixture(page:Page,request:APIRequestContext,source:Buffer|string=html){
 await request.post(`${fixtureOrigin}/__reset`);
 await page.route('https://arxiv.org/**',async route=>{
  const url=route.request().url();
  if(url==='https://arxiv.org/html/2601.01234v2')await route.fulfill({status:200,contentType:'text/html',headers:{'access-control-allow-origin':'*'},body:source});
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
 await openFixture(page,request,twoFigures);
 const frame=page.frameLocator('[data-testid=reader-frame]');
 await expect(frame.locator('figure').first()).toBeVisible({timeout:20000});
 const chats=async()=>(await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json()).requests as Record<string,any>[];

 // The figure page: Explain in Chat and AI Explainer in the top row with the X on the right (owner, build 62), above the
 // figure; no Done, no action bar under it; nothing is asked on opening.
 let viewer=await openFigure(page);
 const explain=viewer.getByTestId('figure-explain'),ask=viewer.getByTestId('figure-ask'),close=viewer.getByTestId('figure-close');
 await expect(explain).toHaveText('AI Explainer');await expect(ask).toHaveText('Chat about Figure');await expect(close).toHaveAccessibleName('Close');
 const [explainBox,askBox,closeBox,figureBox]=[(await explain.boundingBox())!,(await ask.boundingBox())!,(await close.boundingBox())!,(await viewer.locator('iframe.figure-frame').boundingBox())!];
 const middle=(b:{y:number;height:number})=>b.y+b.height/2;
 expect(Math.abs(middle(explainBox)-middle(askBox))).toBeLessThan(2);expect(Math.abs(middle(closeBox)-middle(askBox))).toBeLessThan(3);
 expect(askBox.x).toBeLessThan(explainBox.x);expect(explainBox.x).toBeLessThan(closeBox.x);expect(askBox.y+askBox.height).toBeLessThanOrEqual(figureBox.y);
 await expect(viewer.getByRole('button',{name:'Done'})).toHaveCount(0);
 await expect(viewer.getByTestId('figure-walkthrough')).toHaveCount(0);
 await page.waitForTimeout(500);expect(await chats()).toHaveLength(0);
 await page.screenshot({path:`../../.artifacts/figure-view-opened-${test.info().project.name}.png`});

 // Explain asks the chat's own consent first; nothing is sent before it.
 // AI Explainer asks which model first (B7, the apps' AIChoiceView): Default; then the consent; nothing is sent before.
 await explain.click();
 await expect(page.getByRole('dialog',{name:'AI model'})).toBeVisible();expect(await chats()).toHaveLength(0);
 await page.screenshot({path:`../../.artifacts/figure-view-model-choice-${test.info().project.name}.png`});
 await page.getByTestId('explainer-default').click();
 await expect(viewer.getByTestId('figure-consent')).toBeVisible();expect(await chats()).toHaveLength(0);
 await viewer.getByRole('button',{name:'Allow and explain'}).click();
 await expect(viewer.getByTestId('explainer-model-name')).toBeVisible();
 const walk=viewer.getByTestId('figure-walkthrough');
 await expect(viewer.getByTestId('figure-summary')).toContainText('The figure compares two pipelines');
 await expect(walk.locator('.figure-section')).toHaveCount(3);
 await expect(viewer.getByTestId('figure-section-0').locator('h4')).toHaveText('Panel · (a)The three-stage pipeline');
 await expect(viewer.getByTestId('figure-section-2').locator('h4')).toHaveText('PanelLegend');
 // The one boxed part carries its crop (the right half of the image that was sent); the others none.
 await expect(walk.getByTestId('figure-crop')).toHaveCount(1);
 await expect(walk.getByTestId('figure-coverage-fallback')).toContainText('whole figure above');
 await viewer.getByRole('button',{name:'Open fullscreen',exact:true}).first().click();
 const full=page.locator('.fullscreen-figure');
 await expect(full).toBeVisible();
 await expect(full.locator('iframe')).toBeVisible();
 await full.getByRole('button',{name:'Close',exact:true}).click();
 await expect(viewer.getByTestId('figure-summary')).toBeVisible();
 const crop=viewer.getByTestId('figure-section-1').getByTestId('figure-crop');
 await expect(crop).toBeVisible();
 // The authored bitmap is 12 pixels wide: the 2% margin rounds outward to 7 complete pixels, not a fractional 6.24.
 expect(await crop.locator('.figure-crop').evaluate(e=>{const s=getComputedStyle(e);return [s.backgroundSize,s.backgroundPositionX,s.backgroundPositionY,s.backgroundImage.startsWith('url("data:image/jpeg;base64,')];})).toEqual(['171.43% 100%','100%','0%',true]);
 // Math is typeset, [¶N] is a link; AI Explainer has gone, Explain in Chat stays; no credit counts (owner, build 59).
 await expect(viewer.getByTestId('figure-section-1').locator('math')).toBeVisible();
 await expect(viewer.getByTestId('figure-section-0').locator('.cite')).toHaveText('¶2');
 await expect(explain).toHaveCount(0);await expect(ask).toBeVisible();
 await expect(viewer.getByTestId('figure-walkthrough')).not.toContainText(/\d+\s+credits?\b/);
 // The figure gets smaller while its walkthrough shows, so the words are in view.
 expect((await viewer.locator('iframe.figure-frame').boundingBox())!.height).toBeLessThan(470);
 await expect(viewer.getByRole('heading',{name:'What it shows'})).toBeInViewport();
 await crop.locator('..').getByRole('button',{name:'Zoom into crop'}).click(); await expect(crop).toHaveAttribute('data-scale','1.5');
 await crop.locator('..').getByRole('button',{name:'Zoom out of crop'}).click(); await expect(crop).toHaveAttribute('data-scale','1');
 let sent=await chats();
 expect(sent).toHaveLength(1);
 expect(sent[0]).toMatchObject({action:'figure',mode:'paper',consent_version:'cloud-ai-v6',selection:{quote:'Figure 1: A test figure.'},messages:[{role:'user',text:'Figure 1'}],
  local_context:{format:'reader-local-context-v2',membership_id:member}});
 expect(sent[0].capabilities).toContain('figure_view');expect(sent[0].figures).toHaveLength(1);
 expect(sent[0].figures[0]).toMatchObject({id:'F1',media_type:'image/jpeg'});
 for(const key of ['topic_title','follow_ups','document_id'])expect(sent[0]).not.toHaveProperty(key);
 await page.screenshot({path:`../../.artifacts/figure-view-${test.info().project.name}.png`});
 // The explainer's heading is a menu of the paper's figures (owner, build 62); one switched to waits for AI Explainer,
 // and switching back shows the kept walkthrough without a new request.
 const heading=viewer.getByTestId('figure-heading');
 await expect(heading).toHaveText('Figure 1');
 await heading.click();
 await expect(page.getByRole('menu').getByRole('menuitemradio')).toHaveText(['Figure 1','Figure 2']);
 await expect(page.getByRole('menu').getByRole('menuitemradio',{name:'Figure 1'})).toHaveAttribute('aria-checked','true');
 await page.screenshot({path:`../../.artifacts/figure-view-heading-${test.info().project.name}.png`});
 await page.getByRole('menu').getByRole('menuitemradio',{name:'Figure 2'}).click();
 await expect(viewer.frameLocator('iframe.figure-frame').locator('figcaption')).toContainText('A second figure.');
 await expect(viewer.getByTestId('figure-walkthrough')).toHaveCount(0);await expect(viewer.getByTestId('figure-explain')).toBeVisible();
 expect(await chats()).toHaveLength(1);
 await viewer.getByRole('button',{name:'Previous figure'}).click();
 await expect(viewer.getByTestId('figure-walkthrough').locator('.figure-section')).toHaveCount(3);
 expect(await chats()).toHaveLength(1);

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
 expect(await closerCrop.locator('.figure-crop').evaluate(e=>{const s=getComputedStyle(e);return [s.backgroundSize,s.backgroundPositionX,s.backgroundPositionY];})).toEqual(['171.43% 100%','0%','0%']);
 await expect(closer.getByTestId('figure-detail-no-crop')).toHaveCount(0);
 await expect(viewer.getByTestId('figure-walkthrough')).not.toContainText(/\d+\s+credits?\b/);
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
 await expect(page.getByTestId('explainer-return')).toHaveText('Back to Figure Explainer');
 await page.getByTestId('explainer-return').click();
 viewer=page.getByRole('dialog',{name:'Figures'});
 await expect(viewer.getByTestId('figure-walkthrough').locator('.figure-section')).toHaveCount(3);
 await expect(viewer.getByTestId('figure-section-0').getByTestId('figure-simpler')).toContainText('second network');
 await expect(viewer.getByTestId('figure-section-0').getByTestId('figure-detail-crop')).toBeVisible();
 await expect(viewer.getByTestId('figure-explain')).toHaveCount(0);
 expect(await chats()).toHaveLength(4);

 // Ask in chat about this: an unsent draft about that part, the composer focused; nothing is sent.
 await viewer.getByTestId('figure-section-menu-2').click();
 await page.getByRole('menu').getByRole('menuitem',{name:'Ask in chat about this'}).click();
 await expect(viewer).toBeVisible();
 const composer=viewer.getByTestId('contextual-chat').getByRole('textbox',{name:'Message',exact:true});
 await expect(composer).toBeVisible();await expect(composer).toHaveValue('About this part: Arrows show where data flows; the trophy marks the preferred response. ');
 await expect(composer).toBeFocused();
 expect(await chats()).toHaveLength(4);
 await composer.fill('Explain the arrows.'); await viewer.getByTestId('contextual-chat').getByRole('button',{name:'Send',exact:true}).click();
 await expect(viewer.getByTestId('contextual-chat').locator('.chat-message.assistant')).toBeVisible();
 const followUp=(await chats()).at(-1)!; expect(followUp.figures).toHaveLength(1); expect(followUp.selection.quote).toContain('Figure 1');
 const countBeforePromotion=(await chats()).length;
 await composer.fill('What does the arrow mean here?');
 await viewer.getByRole('button',{name:'Open in Chat',exact:true}).click();
 await expect(viewer).toBeHidden();
 const continued=page.getByRole('textbox',{name:'Message',exact:true});
 await expect(continued).toHaveValue('What does the arrow mean here?');
 await expect(page.getByTestId('promoted-context')).toBeVisible();
 expect((await chats()).length).toBe(countBeforePromotion);
 await page.screenshot({path:`../../.artifacts/feedback/build70-20261018/promoted-${test.info().project.name}.png`});
 expect(errors).toEqual([]);
});

// Build 73 (AHYZ): "Clicked back to chat and somehow got here": a promoted explainer chat read as a new chat. It is named
// for its figure; a citation from it and Back to chat return to that same chat; only one Back shows at a time (the most
// recent origin wins).
test('a promoted explainer chat keeps its figure’s name; Back to chat returns to it; one Back at a time',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 await openFixture(page,request);
 await expect(page.frameLocator('[data-testid=reader-frame]').locator('figure').first()).toBeVisible({timeout:20000});
 let viewer=await openFigure(page);
 await viewer.getByTestId('figure-explain').click();
 await viewer.getByRole('button',{name:'Allow and explain'}).click();
 await expect(viewer.getByTestId('figure-walkthrough').locator('.figure-section')).toHaveCount(3);
 await viewer.getByRole('button',{name:'Open in Chat',exact:true}).click();
 await expect(viewer).toBeHidden();
 const pane=page.getByTestId('chat-pane');
 await expect(pane.getByTestId('promoted-context')).toBeVisible();
 await expect(pane.getByTestId('chat-title')).toHaveText('Figure 1');
 const field=pane.getByRole('textbox',{name:'Message',exact:true});
 const composer=await field.getAttribute('data-composer-id');
 await page.screenshot({path:`../../.artifacts/feedback-20261021/browser/b1-promoted-title-${test.info().project.name}-light.png`});
 await page.emulateMedia({colorScheme:'dark'});
 await page.screenshot({path:`../../.artifacts/feedback-20261021/browser/b1-promoted-title-${test.info().project.name}-dark.png`});
 await page.emulateMedia({colorScheme:'light'});
 test.skip(test.info().project.name==='desktop','Beside the paper the chat stays open: there is no Back to chat.');
 // A citation in the promoted explanation closes the drawer and offers Back to chat, not an explainer's Back.
 await pane.getByTestId('promoted-context').locator('.cite').first().click();
 const chatBack=page.getByTestId('chat-back'),explainerBack=page.getByTestId('explainer-return');
 await expect(chatBack).toBeVisible();await expect(explainerBack).toHaveCount(0);
 // An explainer's own citation then wins: Back to Figure Explainer, and no Back to chat beside it.
 viewer=await openFigure(page);
 await viewer.getByTestId('figure-section-0').locator('.cite').first().click();
 await expect(viewer).toBeHidden();
 await expect(explainerBack).toHaveText('Back to Figure Explainer');await expect(chatBack).toHaveCount(0);
 // The chat's citation again wins over the explainer's Back.
 await page.getByTestId('ask').click();
 await expect(pane.getByTestId('chat-title')).toHaveText('Figure 1');
 await pane.getByTestId('promoted-context').locator('.cite').first().click();
 await expect(chatBack).toBeVisible();await expect(explainerBack).toHaveCount(0);
 await page.screenshot({path:`../../.artifacts/feedback-20261021/browser/b1-chat-back-${test.info().project.name}-light.png`});
 // Back to chat: the same promoted chat, named for its figure, its composer unchanged.
 await chatBack.click();
 await expect(pane.getByTestId('promoted-context')).toBeVisible();
 await expect(pane.getByTestId('chat-title')).toHaveText('Figure 1');
 await expect(field).toHaveAttribute('data-composer-id',composer!);
});

test('Find lists occurrences and jumps without rewriting verified paper text',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 await openFixture(page,request,twoFigures);
 const frame=page.frameLocator('[data-testid=reader-frame]');
 await expect(frame.locator('h1').first()).toBeVisible();
 const before=await frame.locator('body').innerHTML();
 await page.getByTestId('find').click();await page.getByTestId('find-input').fill('figure');
 await expect(page.getByTestId('find-count')).toHaveText(/\d+ of [2-9]\d*/);
 await page.getByRole('button',{name:'List occurrences'}).click();
 const matches=page.getByRole('list',{name:'Occurrences'}).getByRole('button');
 const count=await matches.count();expect(count).toBeGreaterThan(1);
 await matches.last().click();await expect(page.getByTestId('find-count')).toHaveText(`${count} of ${count}`);
 const iframe=page.getByTestId('reader-frame');
 const top=(await iframe.boundingBox())!.y+await frame.locator('body').evaluate(()=>{
   const range=(CSS.highlights.get('gradstep-find-current') as any).values().next().value as Range;
   (window as any).__findTestRange=range;return range.getBoundingClientRect().top;
 });
 await page.getByRole('search',{name:'Find in paper'}).getByRole('button',{name:'Done'}).click();
 expect(await frame.locator('body').innerHTML()).toBe(before);
 const afterTop=(await iframe.boundingBox())!.y+await frame.locator('body').evaluate(()=>(window as any).__findTestRange.getBoundingClientRect().top);
 // Closing the bar changes viewport height. When that leaves a short paper scrolled to its end (the phone's
 // destination bar since Notes makes this fixture reach it), scrollY clamps: the match must still be in view there.
 const end=await frame.locator('body').evaluate(()=>{const r=(window as any).__findTestRange.getBoundingClientRect();
   return {bottom:Math.abs(scrollY+innerHeight-document.documentElement.scrollHeight)<1,visible:r.top>=0&&r.bottom<=innerHeight};});
 if(end.bottom&&Math.abs(afterTop-top)>=3)expect(end.visible).toBe(true);else expect(Math.abs(afterTop-top)).toBeLessThan(3);
});

test('a failed walkthrough says so and can be tried again; the figure page’s Explain in Chat drafts about the caption',async({page,request})=>{
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
 // The walkthrough's panel loads with the first figure page: the consent shows once it has.
 await page.getByTestId('explainer-default').click();await viewer.getByRole('button',{name:'Allow and explain'}).click();
 await expect(viewer.getByTestId('figure-issue')).toContainText('The AI service couldn’t finish this answer. Try again.');
 await viewer.getByTestId('figure-retry').click();
 await expect(viewer.getByTestId('figure-walkthrough').locator('.figure-section')).toHaveCount(3);
 await expect(viewer.getByTestId('figure-issue')).toHaveCount(0);
 await viewer.getByTestId('figure-ask').click();
 await expect(viewer).toBeVisible();
 await expect(viewer.getByTestId('contextual-chat').getByRole('textbox',{name:'Message',exact:true})).toBeFocused();
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
 // The walkthrough's panel loads with the first figure page: the consent shows once it has.
 await page.getByTestId('explainer-default').click();await viewer.getByRole('button',{name:'Allow and explain'}).click();
 await expect(viewer.getByTestId('figure-words')).toContainText('The figure shows two pipelines side by side');
 await expect(viewer.getByTestId('figure-walkthrough').locator('.figure-section')).toHaveCount(0);
 await expect(viewer.getByTestId('figure-note')).toHaveText('Interrupted · not charged');
 await expect(viewer.getByTestId('figure-walkthrough')).not.toContainText(/\d+\s+credits?\b/);
});

test('a figure reference in the text offers Explain in Chat and AI Explainer; AI Explainer opens its page and asks at once',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 // "Figure 1" in the text as most papers print it (no anchor): the reader links it to its figure (FIGURE REFERENCES).
 await openFixture(page,request,html.toString('utf8').replace('<a href="#S1.F1">Figure 1</a>','Figure 1'));
 const frame=page.frameLocator('[data-testid=reader-frame]');
 const link=frame.locator('.sr-cite[data-sr-figure]').first();
 await expect(link).toBeAttached({timeout:20000});await link.scrollIntoViewIfNeeded();await link.click();
 const detail=page.getByRole('dialog',{name:'Figure 1'});
 await expect(detail.getByTestId('figure-reference-ask')).toHaveText('Chat about Figure');
 await expect(detail.getByTestId('figure-reference-explain')).toHaveText('AI Explainer');
 // Peers with the same weight (owner, build 76: "Confusing that only one is purple").
 const look=(id:string)=>detail.getByTestId(id).evaluate(e=>{const s=getComputedStyle(e);return [s.color,s.backgroundColor,s.borderColor].join('|');});
 expect(await look('figure-reference-explain')).toBe(await look('figure-reference-ask'));
 await expect(detail.getByRole('button',{name:'Discuss in chat'})).toHaveCount(0);await expect(detail.getByRole('button',{name:'Done'})).toHaveCount(0);
 await expect(detail.getByTestId('figure-reference-go')).toBeVisible();
 await page.screenshot({path:`../../.artifacts/figure-reference-${test.info().project.name}.png`});
 await detail.getByTestId('figure-reference-explain').click();
 const viewer=page.getByRole('dialog',{name:'Figures'});
 // Asked at once: the model (B7), the chat's consent, then the walkthrough.
 await page.getByTestId('explainer-default').click();
 await expect(viewer.getByTestId('figure-consent')).toBeVisible();
 await viewer.getByRole('button',{name:'Allow and explain'}).click();
 await expect(viewer.getByTestId('figure-walkthrough').locator('.figure-section')).toHaveCount(3);
 await expect(viewer.getByTestId('figure-explain')).toHaveCount(0);
 await page.emulateMedia({colorScheme:'dark'});
 await page.screenshot({path:`../../.artifacts/figure-reference-explained-${test.info().project.name}-dark.png`});
 await page.emulateMedia({colorScheme:'light'});
 await viewer.getByTestId('figure-close').click();await expect(viewer).toBeHidden();
});


test('concept and related-work cards keep distinct titles and paper provenance without crop actions',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 await openFixture(page,request);
 await page.route(`${fixtureOrigin}/functions/v1/chat`,async route=>{
  const answer={format:'figure-walkthrough-v1',summary:'Two ways to interpret the figure.',sections:[
   {kind:'concept',label:'',title:'Preference learning',text:'The context of this result [¶2].',paragraphs:[2]},
   {kind:'related_work',label:'',title:'Earlier reward-model methods',text:'The supplied paper describes this comparison [¶2].',paragraphs:[2]}
  ]};
  await route.fulfill({status:200,contentType:'text/event-stream',body:`event: figure\ndata: ${JSON.stringify(answer)}\n\nevent: done\ndata: {"stop_reason":"end_turn","credits":2,"charged":true}\n\n`});
 });
 const viewer=await openFigure(page);await viewer.getByTestId('figure-explain').click();
 await page.getByTestId('explainer-default').click();await viewer.getByRole('button',{name:'Allow and explain'}).click();
 const concept=viewer.getByTestId('figure-section-0'),related=viewer.getByTestId('figure-section-1');
 await expect(concept.locator('h4')).toHaveText('ConceptPreference learning');
 await expect(related.locator('h4')).toHaveText('Related workEarlier reward-model methods');
 await expect(related).toContainText('As described in this paper');
 await expect(viewer.getByTestId('figure-crop')).toHaveCount(0);
 await viewer.getByTestId('figure-section-menu-1').click();
 await expect(viewer.getByTestId('figure-detail-item')).toHaveCount(0);
 await page.keyboard.press('Escape');
 await page.screenshot({path:`../../.artifacts/figure-card-kinds-${test.info().project.name}.png`});
});
