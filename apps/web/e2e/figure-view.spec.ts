// The figure view (docs/architecture/FIGURE_VIEW.md): the figure page's one top row offers Explain in Chat and AI
// Explainer beside the X (owner, build 62) and asks nothing of the AI on opening; AI Explainer (after the chat's consent)
// walks through the figure part by part with a crop where the model drew a box, under a heading that switches to the
// paper's other figures; a part's ⋯ explains it more simply, shows it in the paper (with Back) or starts a chat draft
// about it. A figure reference in the text offers the same two actions. Both requests are the chat's own (its
// capabilities, with figure_view, and exactly this figure).
import {existsSync,readFileSync} from 'node:fs';
import {expect,test,type APIRequestContext,type Page} from '@playwright/test';
import {RECOVERY_CODE} from './fixture-keys.mjs';
import {fixtureOrigin} from './environment';
import {durableKeys} from './key-capability';
const html=readFileSync(new URL('../../../tests/fixtures/reader-arxiv/source.html',import.meta.url));
const raster=readFileSync(new URL('../../../tests/fixtures/reader-mathpix/figure-exif.jpg',import.meta.url));
const member='58000000-0000-4000-8000-000000000003';
// A real two-plot figure (DPO's Figure 2, from the apps' bundled sample; 1360 × 501) for the completed crops.
const twoPlots=readFileSync(new URL('../../apple/ScienceReader/Resources/ReaderSamples/cd902bcdeeda373f6612f00221010f3fba918dcafbd500142d46ee53b2178a71/assets/71e93518051c67deb7400d9a48cc2ee6f96ed251dd2b8f916ab4fca9a702418c.jpg',import.meta.url));
// A second figure, for the walkthrough's heading menu.
const twoFigures=html.toString('utf8').replace('<figure id="tab1">','<figure id="S1.F2"><img src="2601.01234v2/figure.jpg"><figcaption>Figure 2: A second figure.</figcaption></figure><figure id="tab1">');
// The authored arXiv fixture as a source membership (the official HTML this browser prepares), as the equation journey.
/** A real arXiv paper, served from the sweep's cache on this Mac (its HTML and the assets the device compiler fetched,
 * `.artifacts/reader-sweep/`), as the library's source membership. */
type RealPaper={id:string;revision:number;title:string};
const sweep=new URL('../../../.artifacts/reader-sweep/',import.meta.url);
const sweepSource=(p:RealPaper)=>new URL(`sources/${p.id}v${p.revision}.html`,sweep);
async function openFixture(page:Page,request:APIRequestContext,source:Buffer|string=html,image:Buffer=raster,real?:RealPaper){
 await request.post(`${fixtureOrigin}/__reset`);
 const key=real?`${real.id}v${real.revision}`:'2601.01234v2';
 await page.route('https://arxiv.org/**',async route=>{
  const url=route.request().url();
  const headers={'access-control-allow-origin':'*'};
  if(url===`https://arxiv.org/html/${key}`)await route.fulfill({status:200,contentType:'text/html',headers,body:real?readFileSync(sweepSource(real)):source});
  else if(!real&&url==='https://arxiv.org/html/2601.01234v2/figure.jpg')await route.fulfill({status:200,contentType:'image/jpeg',headers,body:image});
  else if(real&&url.startsWith(`https://arxiv.org/html/${key}/`)){
   const name=encodeURIComponent(url.split('/').slice(-1)[0]),type=/\.svg$/i.test(name)?'image/svg+xml':/\.png$/i.test(name)?'image/png':'image/jpeg';
   await route.fulfill({status:200,contentType:type,headers,body:readFileSync(new URL(`assets/${key}/${name}`,sweep))});
  }
  else throw Error('Unexpected source acquisition '+url);
 });
 await page.route(`${fixtureOrigin}/rest/v1/rpc/v3_library_page`,async route=>{
  const response=await route.fetch(),body=await response.json();
  const row=body.entries.find((e:{kind:string})=>e.kind==='item');
  body.entries=[{kind:'import',id:member,created_seq:row.created_seq,state_seq:row.state_seq,intent_revision:1,visible:true,phase:'source_only',source:'arxiv',source_id:real?.id??'2601.01234',requested_revision:real?.revision??2,source_revision:real?.revision??2,
   metadata_id:row.metadata_id,version_id:row.version_id,metadata_recorded_at:row.metadata_recorded_at,source_url:`https://arxiv.org/abs/${key}`,retryable:false,metadata:{title:real?.title??'Authored HTML fixture',authors:['Fixture author'],categories:['cs.LG']}}];
  body.has_more=false;body.next_cursor={format:2,account_id:body.account_id,through:body.baseline_cursor,created_seq:row.created_seq,id:member,kind:'import'};
  await route.fulfill({response,json:body});
 });
 await page.route(`${fixtureOrigin}/rest/v1/rpc/v3_library_changes`,async route=>{const response=await route.fetch(),body=await response.json();body.changes=[];body.has_more=false;body.next_cursor=body.through;await route.fulfill({response,json:body});});
 await page.goto('/');await page.getByTestId('email').fill('returning@example.test');await page.getByTestId('send-code').click();
 await page.getByTestId('code').fill('123456');await page.getByTestId('verify').click();
 await page.getByTestId('use-recovery-code').click();await page.getByTestId('recovery-code').fill(RECOVERY_CODE);await page.getByTestId('recover').click();
 await page.getByTestId('library-table').getByRole('link',{name:real?.title??'Authored HTML fixture',exact:true}).click();
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

test('a figure is explained only on request, part by part with its crop; a part goes simpler (no Extract), into the paper and into the chat',async({page,request})=>{
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
 await expect(explain).toHaveText('AI Explainer');await expect(ask).toHaveText('Chat');await expect(ask).toHaveAccessibleName('Chat about Figure');await expect(close).toHaveAccessibleName('Close');
 // Build 78: words only, Snippet first when Notes is available ("use txt at top Snippet, Chat, AI Explainer").
 await expect(viewer.locator('.sheet-top-start .sheet-action svg')).toHaveCount(0);
 const [explainBox,askBox,closeBox,figureBox]=[(await explain.boundingBox())!,(await ask.boundingBox())!,(await close.boundingBox())!,(await viewer.locator('iframe.figure-frame').boundingBox())!];
 const middle=(b:{y:number;height:number})=>b.y+b.height/2;
 expect(Math.abs(middle(explainBox)-middle(askBox))).toBeLessThan(2);expect(Math.abs(middle(closeBox)-middle(askBox))).toBeLessThan(3);
 // The page covers the paper with the iPhone's sheet row (owner, 2026-10-22): ✕ first, then the words.
 expect(closeBox.x).toBeLessThan(askBox.x);expect(askBox.x).toBeLessThan(explainBox.x);expect(askBox.y+askBox.height).toBeLessThanOrEqual(figureBox.y);
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
 // The authored bitmap is 12 × 8 pixels and one block of ink: the completed part is exactly the right half (6 whole
 // pixels), framed tightly with 8 pixels of white margin (frame [−2, −8, 20, 16]); the card is a viewport into the whole
 // figure (its canvas, the image on its 8-pixel margin, starts 6 pixels left of the frame: FIGURE_VIEW.md "Parts as viewports").
 await expect(crop).toHaveAttribute('data-level','high');
 expect(await crop.locator('.viewport-canvas').evaluate(e=>[e.style.left,e.style.top,e.style.width,e.style.height,(e.querySelector('img') as HTMLImageElement).src.startsWith('data:image/jpeg;base64,')]))
  .toEqual(['-27.2727%','0%','127.273%','100%',true]);
 // Math is typeset, [¶N] is a link; AI Explainer has gone, Explain in Chat stays; no credit counts (owner, build 59).
 await expect(viewer.getByTestId('figure-section-1').locator('math')).toBeVisible();
 await expect(viewer.getByTestId('figure-section-0').locator('.cite')).toHaveText('¶2');
 await expect(explain).toHaveCount(0);await expect(ask).toBeVisible();
 await expect(viewer.getByTestId('figure-walkthrough')).not.toContainText(/\d+\s+credits?\b/);
 // The figure gets smaller while its walkthrough shows, so the words are in view.
 expect((await viewer.locator('iframe.figure-frame').boundingBox())!.height).toBeLessThan(470);
 await expect(viewer.getByRole('heading',{name:'What it shows'})).toBeInViewport();
 // The card never zooms in place (2026-10-22): no zoom controls, only Full screen.
 await expect(crop.locator('..').getByRole('button',{name:/Zoom/})).toHaveCount(0);
 await expect(crop.locator('..').getByRole('button',{name:'Full screen',exact:true})).toBeVisible();
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
 // Owner, 2026-10-21: no "Extract the subfigure and more context"; the walkthrough is the one AI result.
 await expect(menu.getByRole('menuitem')).toHaveText(['Explain more simply','Show in the paper','Ask in chat about this']);
 await page.screenshot({path:`../../.artifacts/figure-detail-removal/browser-part-menu-${test.info().project.name}.png`});
 await menu.getByRole('menuitem',{name:'Explain more simply'}).click();
 const simpler=viewer.getByTestId('figure-section-0').getByTestId('figure-simpler');
 await expect(simpler).toContainText('is a second network that learns to score answers');
 await expect(simpler.locator('strong')).toHaveText('reward model');
 sent=await chats();
 expect(sent[1]).toMatchObject({action:'figure_simpler',selection:{quote:'Read left to right: preference data trains a **reward model**, which then scores samples for reinforcement learning [¶2].'},
  messages:[{role:'user',text:'Figure 1 (a)'}]});
 expect(sent[1].capabilities).toEqual(sent[0].capabilities);expect(sent[1].figures).toHaveLength(1);
 await page.screenshot({path:`../../.artifacts/figure-view-simpler-${test.info().project.name}.png`});
 await expect(viewer.getByTestId('figure-walkthrough')).not.toContainText(/\d+\s+credits?\b/);
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
 await expect(viewer.getByTestId('figure-explain')).toHaveCount(0);
 expect(await chats()).toHaveLength(2);

 // Ask in chat about this: an unsent draft about that part, the composer focused; nothing is sent.
 await viewer.getByTestId('figure-section-menu-2').click();
 await page.getByRole('menu').getByRole('menuitem',{name:'Ask in chat about this'}).click();
 await expect(viewer).toBeVisible();
 const composer=viewer.getByTestId('contextual-chat').getByRole('textbox',{name:'Message',exact:true});
 await expect(composer).toBeVisible();await expect(composer).toHaveValue('About this part: Arrows show where data flows; the trophy marks the preferred response. ');
 await expect(composer).toBeFocused();
 expect(await chats()).toHaveLength(2);
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
 await page.getByTestId('explainer-default').click(); // AI Explainer asks which model first (B7)
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
 await expect(detail.getByTestId('figure-reference-ask')).toHaveText('Chat');await expect(detail.getByTestId('figure-reference-ask')).toHaveAccessibleName('Chat about Figure');
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
 await expect(page.getByRole('menu').getByRole('menuitem')).toHaveText(['Explain more simply','Show in the paper','Ask in chat about this']);
 await page.keyboard.press('Escape');
 await page.screenshot({path:`../../.artifacts/figure-card-kinds-${test.info().project.name}.png`});
});

// Owner, 2026-10-21: "ALWAYS include all pixels of the figure when it breaks it up into subplots" and "some margin around
// them". The walkthrough's boxes clip titles, tick labels and axis titles, as models write them; each crop is completed on
// this device (figure-crops.ts) and shown on a margin of background, with no coverage note since the crops hold all ink.
test('crops of a real two-plot figure are completed over the ink they cut and shown with a margin',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 // FIGURE_CROPS_STAGE=before names the screenshots of a build without the step (the assertions are soft so they're taken).
 const stage=process.env.FIGURE_CROPS_STAGE??'after',shot=(name:string)=>`../../.artifacts/figure-crops/${stage}-browser-${name}-${test.info().project.name}.png`;
 await openFixture(page,request,html,twoPlots);
 await request.post(`${fixtureOrigin}/__chat-fixture`,{data:{mode:'figure_panels'}});
 await expect(page.frameLocator('[data-testid=reader-frame]').locator('figure').first()).toBeVisible({timeout:20000});
 const viewer=await openFigure(page);
 await page.screenshot({path:shot('figure-page-light')});
 await viewer.getByTestId('figure-explain').click();
 await page.getByTestId('explainer-default').click();await viewer.getByRole('button',{name:'Allow and explain'}).click();
 const left=viewer.getByTestId('figure-section-0').getByTestId('figure-crop'),right=viewer.getByTestId('figure-section-1').getByTestId('figure-crop');
 await expect(left).toBeVisible();await expect(right).toBeVisible();await expect(viewer.getByTestId('figure-progress')).toHaveCount(0); // streamed: framed afresh once done
 await left.scrollIntoViewIfNeeded();
 await page.screenshot({path:shot('walkthrough-light')});
 await expect.soft(viewer.getByTestId('figure-coverage-fallback')).toHaveCount(0);
 // Completed on the 1360 × 501 image sent: [8, 8, 672, 492] and [704, 16, 1352, 496], each with 10 px of background on
 // every side; the clipped boxes with the old 2 % margin were 626 × 416 and 626 × 416.
 const aspect=async(l:typeof left)=>{const b=(await l.boundingBox())!;return b.width/b.height;};
 expect.soft(await aspect(left)).toBeCloseTo(684/504,1);expect.soft(await aspect(right)).toBeCloseTo(668/500,1);
 await page.emulateMedia({colorScheme:'dark'});
 await left.scrollIntoViewIfNeeded();
 await page.screenshot({path:shot('walkthrough-dark')});
 await page.emulateMedia({colorScheme:'light'});
});

// Owner, 2026-10-21: "we present it as a crop of the whole thing, that they can expand, rather than an actual crop".
// Parts are viewports into the whole figure (FIGURE_VIEW.md "Parts as viewports"), framed by confidence: a precise box
// tight (as a crop looked), a deliberately imprecise one (it starts inside the neighbouring plot) loosely with the part
// outlined. A tap expands a card to the whole figure; zooming out of a card reveals what is around the part.
test('parts are framed by confidence: an imprecise box is looser and outlined, and a card expands to the whole figure',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 // FIGURE_FRAMING_STAGE=before names the screenshots of a build without viewports (only the screenshots are taken then).
 const stage=process.env.FIGURE_FRAMING_STAGE??'after',after=stage==='after',shot=(name:string)=>`../../.artifacts/figure-framing/${stage}-browser-${name}-${test.info().project.name}.png`;
 await openFixture(page,request,html,twoPlots);
 await request.post(`${fixtureOrigin}/__chat-fixture`,{data:{mode:'figure_panels_loose'}});
 await expect(page.frameLocator('[data-testid=reader-frame]').locator('figure').first()).toBeVisible({timeout:20000});
 const viewer=await openFigure(page);
 await viewer.getByTestId('figure-explain').click();
 await page.getByTestId('explainer-default').click();await viewer.getByRole('button',{name:'Allow and explain'}).click();
 const left=viewer.getByTestId('figure-section-0').getByTestId('figure-crop'),right=viewer.getByTestId('figure-section-1').getByTestId('figure-crop');
 await expect(left).toBeVisible();await expect(right).toBeVisible();await expect(viewer.getByTestId('figure-progress')).toHaveCount(0); // streamed: framed afresh once done
 await left.scrollIntoViewIfNeeded();
 await page.screenshot({path:shot('walkthrough-left-light')});
 await right.scrollIntoViewIfNeeded();
 await page.screenshot({path:shot('walkthrough-right-light')});
 if(after){
  // The precise box: tight, its completed crop and margin (as the crop looked), no outline; the imprecise one: loose, outlined.
  await expect(left).toHaveAttribute('data-level','high');await expect(right).toHaveAttribute('data-level','medium');
  await expect(left.getByTestId('part-outline')).toBeHidden();await expect(right.getByTestId('part-outline')).toBeVisible();
  const aspect=async(l:typeof left)=>{const b=(await l.boundingBox())!;return b.width/b.height;};
  expect(await aspect(left)).toBeCloseTo(684/504,1);
  // Accessibility labels keep their meaning; the card is a control that opens the full screen.
  await expect(left).toHaveAccessibleName('Open Left plot · Reward against KL divergence, the part of the figure it describes full screen');
  await expect(left).toHaveAttribute('role','button');
  // A tap opens the imprecise part full screen, framed on the part, outlined; a double-click shows the whole figure.
  await right.click();
  const full=page.getByTestId('figure-fullscreen');
  await expect(full).toBeVisible();
  const whole=full.getByTestId('fullscreen-crop');
  await expect(whole).toHaveAttribute('data-view','part');
  await expect(whole.getByTestId('part-outline')).toBeVisible();
  await expect(full).toHaveAttribute('data-phase','open');
  await page.screenshot({path:shot('expanded-part-light')});
  await whole.dblclick();await expect(whole).toHaveAttribute('data-view','whole');
  await page.waitForTimeout(500);
  await page.screenshot({path:shot('expanded-whole-light')});
  await full.getByTestId('fullscreen-close').click();await expect(full).toHaveCount(0);
 }else{
  await right.locator('..').getByRole('button',{name:'Open fullscreen'}).click();
  await page.waitForTimeout(500);
  await page.screenshot({path:shot('expanded-light')});
  await page.locator('.fullscreen-figure').getByRole('button',{name:'Close',exact:true}).click();
 }
 await page.emulateMedia({colorScheme:'dark'});
 await left.scrollIntoViewIfNeeded();
 await page.screenshot({path:shot('walkthrough-left-dark')});
 await right.scrollIntoViewIfNeeded();
 await page.screenshot({path:shot('walkthrough-right-dark')});
 await page.emulateMedia({colorScheme:'light'});
 if(after){
  // A part's menu (owner, 2026-10-21: one AI result): no "Extract the subfigure"; Save snippet keeps what the card shows.
  await viewer.getByTestId('figure-section-menu-1').click();
  await expect(page.getByRole('menu').getByRole('menuitem')).toHaveText(['Explain more simply','Show in the paper','Save snippet','Ask in chat about this']);
  await page.screenshot({path:`../../.artifacts/figure-detail-removal/browser-panel-menu-${test.info().project.name}.png`});
  await page.keyboard.press('Escape');
 }
});

// Structure first (FIGURE_VIEW.md "Structure first"): a real multi-image arXiv figure — 2610.22353v1 Figure 3, three
// images with sub-captions (a)–(c) — compiled in this browser from the sweep's cached source. The walkthrough request tells
// the model the sub-figures after the caption; its parts (a), (b) (boxed on its band) and (c) are the figure's own images:
// exact, tight on their bands. Grouped, "(a) and (b)" plus (c) are two parts for three sub-figures (count disagreement):
// the group shows the whole figure, outlined, while (c) stays exact. Opt-in: needs `.artifacts/reader-sweep/` (the sweep and
// `node scripts/reader-device-compile.mjs --ids=2610.22353v1` fill it).
const moe:RealPaper={id:'2610.22353',revision:1,title:'Rethinking Routing Exploration in Modern Mixture-of-Experts'};
for(const grouped of [false,true])test(`a real multi-image figure's parts are its own sub-figures${grouped?' (grouped: the count disagrees)':''}`,async({page,request})=>{
 test.skip(!existsSync(sweepSource(moe)),'The sweep\'s cached 2610.22353v1 is not on this Mac.');
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 test.setTimeout(120_000);
 const shot=(name:string)=>`../../.artifacts/figure-structure/browser-${name}-${test.info().project.name}.png`;
 await openFixture(page,request,html,raster,moe);
 await request.post(`${fixtureOrigin}/__chat-fixture`,{data:{mode:grouped?'figure_subfigures_grouped':'figure_subfigures'}});
 await expect(page.frameLocator('[data-testid=reader-frame]').locator('figure').first()).toBeVisible({timeout:60000});
 const tabs=page.getByRole('tablist',{name:'Show',exact:true});
 await expect(page.getByTestId('contents')).toBeEnabled();
 if(!await tabs.isVisible())await page.getByTestId('contents').click();
 await tabs.getByRole('tab',{name:'Figures'}).click();
 await page.getByTestId('contents-figure-2').click();
 const viewer=page.getByRole('dialog',{name:'Figures'});
 await expect(viewer.frameLocator('iframe.figure-frame').locator('figcaption')).toContainText('Shared experts make MoE routing less exploratory');
 await viewer.getByTestId('figure-explain').click();
 await page.getByTestId('explainer-default').click();await viewer.getByRole('button',{name:'Allow and explain'}).click();
 await expect(viewer.getByTestId('figure-summary')).toContainText('shared experts make routing less exploratory');await expect(viewer.getByTestId('figure-progress')).toHaveCount(0);
 // The request: the caption, then the figure's own sub-figures and their bands in the composed image.
 const sent=(await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json()).requests as Record<string,any>[];
 expect(sent).toHaveLength(1);
 expect(sent[0].selection.quote).toBe('Figure 3: Shared experts make MoE routing less exploratory.\n\n'
  +"The image stacks this figure's 3 sub-figures top to bottom, each across its full width (y: fractions of the image's height):\n"
  +'- (a) Routing criticality: y 0.00–0.33\n- (b) Expert variance: y 0.34–0.66\n- (c) Router variance: y 0.67–1.00\n'
  +'Give each its own panel card, labelled as listed, in this order.');
 // The composed image (1187 × 2342) as sent, scaled to 763 × 1506; each band and 15 px of white margin.
 expect([sent[0].figures[0].width,sent[0].figures[0].height]).toEqual([763,1506]);
 const card=(i:number)=>viewer.getByTestId(`figure-section-${i}`).getByTestId('figure-crop');
 const aspect=async(l:ReturnType<typeof card>)=>{const b=(await l.boundingBox())!;return b.width/b.height;};
 const bandA=(763+30)/(0.33006*1506+30),bandB=(763+30)/((0.659693-0.340307)*1506+30);
 await expect(card(0)).toHaveCount(0);
 if(grouped){
  await expect(card(1)).toHaveAttribute('data-level','low');await expect(card(1)).not.toHaveAttribute('data-exact','true');
  await expect(card(1).getByTestId('part-outline')).toBeVisible();
  await expect(card(2)).toHaveAttribute('data-level','high');await expect(card(2)).toHaveAttribute('data-exact','true');
  expect(await aspect(card(2))).toBeCloseTo(bandA,1);
  await card(1).scrollIntoViewIfNeeded();await page.screenshot({path:shot('grouped-whole-light')});
  await card(2).scrollIntoViewIfNeeded();await page.screenshot({path:shot('grouped-c-exact-light')});
  return;
 }
 for(const i of [1,2,3]){await expect(card(i)).toHaveAttribute('data-level','high');await expect(card(i)).toHaveAttribute('data-exact','true');await expect(card(i).getByTestId('part-outline')).toBeHidden();}
 expect(await aspect(card(1))).toBeCloseTo(bandA,1);expect(await aspect(card(2))).toBeCloseTo(bandB,1);expect(await aspect(card(3))).toBeCloseTo(bandA,1);
 await expect(viewer.getByTestId('figure-coverage-fallback')).toHaveCount(0);
 for(const scheme of ['light','dark'] as const){
  await page.emulateMedia({colorScheme:scheme});
  for(const [i,name] of [[1,'a'],[2,'b'],[3,'c']] as const){await card(i).scrollIntoViewIfNeeded();await page.screenshot({path:shot(`walkthrough-${name}-${scheme}`)});}
 }
 await page.emulateMedia({colorScheme:'light'});
 // A tap expands a part to the whole figure, the part outlined.
 await card(2).click();
 const whole=page.getByTestId('figure-fullscreen').getByTestId('fullscreen-crop');
 await expect(whole).toHaveAttribute('data-view','part');await expect(whole.getByTestId('part-outline')).toBeVisible();
 await page.waitForTimeout(700);await page.screenshot({path:shot('expanded-b-light')});
 await page.getByTestId('figure-fullscreen').getByTestId('fullscreen-close').click();
});

// Owner, 2026-10-22: "very very slow … unusable at this speed. Also it needs a progress bar." The walkthrough streams
// (FIGURE_VIEW.md "Streamed walkthrough"): a progress bar and a skeleton at once, the summary as soon as it is written,
// then each part below the last, so nothing shown moves; the bar sits where the next part will appear and fades once
// done. The fixture streams step by step (figureStream 'step', POST /__figure-step), so every state is seen.
const streamShot=(name:string)=>`../../.artifacts/figure-streaming/browser-${name}-${test.info().project.name}.png`;
async function explainStreaming(page:Page,request:APIRequestContext,figureStream:'step'|'old'){
 await openFixture(page,request);
 await request.post(`${fixtureOrigin}/__chat-fixture`,{data:{figureStream}});
 await expect(page.frameLocator('[data-testid=reader-frame]').locator('figure').first()).toBeVisible({timeout:20000});
 const viewer=await openFigure(page);
 await viewer.getByTestId('figure-explain').click();
 await page.getByTestId('explainer-default').click();await viewer.getByRole('button',{name:'Allow and explain'}).click();
 return viewer;
}
const step=async(request:APIRequestContext,count=1)=>(await (await request.post(`${fixtureOrigin}/__figure-step`,{data:{count}})).json()) as {waiting:number;left:number};
/** Where an element is in the walkthrough (so the page's own scrolling doesn't count): its top and height. */
const within=(locator:ReturnType<Page['locator']>)=>locator.evaluate(e=>{const w=e.closest('[data-testid=figure-walkthrough]')!.getBoundingClientRect(),b=e.getBoundingClientRect();return {y:Math.round(b.top-w.top),height:Math.round(b.height)};});

test('the walkthrough streams under a progress bar: the summary first, then each part in order below it, nothing above moving',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 const viewer=await explainStreaming(page,request,'step');
 const walk=viewer.getByTestId('figure-walkthrough'),bar=viewer.getByRole('progressbar'),status=viewer.getByTestId('figure-progress-status');
 // At once: the bar (indeterminate while the model reads the figure), the summary's lines and a part's card as skeletons.
 await expect(bar).toBeVisible();
 await expect(viewer.getByTestId('figure-skeleton-summary')).toBeVisible();await expect(viewer.getByTestId('figure-skeleton-part')).toBeVisible();
 await expect(bar).toHaveAttribute('aria-label','Reading the figure…');await expect(bar).toHaveAttribute('aria-valuetext','Reading the figure…');
 await expect(bar).not.toHaveAttribute('aria-valuenow');
 await expect(status).toHaveAttribute('aria-live','polite');await expect(status).toHaveText('Reading the figure…');
 await expect(viewer.getByTestId('figure-progress').locator('.figure-progress-label')).toHaveText('Reading the figure…');
 // The indeterminate bar moves (not under Reduce Motion: the next journey).
 expect(await bar.locator('.figure-progress-fill').evaluate(e=>getComputedStyle(e).animationName)).toBe('figure-progress-slide');
 await page.screenshot({path:streamShot('reading-light')});
 await page.emulateMedia({colorScheme:'dark'});await page.screenshot({path:streamShot('reading-dark')});await page.emulateMedia({colorScheme:'light'});
 // The model announces three parts: the bar is determinate from the summary on, and never goes back.
 await step(request,2);
 await expect(bar).toHaveAttribute('aria-label','Writing the summary…');await expect(status).toHaveText('Writing the summary…');
 await expect(bar).toHaveAttribute('aria-valuenow',/^\d+$/);await expect(bar).toHaveAttribute('aria-valuemin','0');await expect(bar).toHaveAttribute('aria-valuemax','100');
 const value=async()=>Number(await bar.getAttribute('aria-valuenow'));
 let last=await value();
 // The summary before any part; the bar moves below it, with the next part's skeleton.
 await step(request,2);
 await expect(viewer.getByTestId('figure-summary')).toContainText('The figure compares two pipelines');
 await expect(viewer.getByTestId('figure-skeleton-summary')).toHaveCount(0);
 await expect(walk.locator('.figure-section')).toHaveCount(0);
 await expect(bar).toHaveAttribute('aria-label','Writing part 1 of 3…');
 expect(await value()).toBeGreaterThanOrEqual(last);last=await value();
 const summary=await within(viewer.getByTestId('figure-summary'));
 expect((await within(viewer.getByTestId('figure-progress'))).y).toBeGreaterThan(summary.y+summary.height-1);
 await page.screenshot({path:streamShot('summary-light')});
 // The first part, under the summary; its menu waits for the whole walkthrough.
 await step(request,3);
 const first=viewer.getByTestId('figure-section-0');
 await expect(first).toBeVisible();await expect(walk.locator('.figure-section')).toHaveCount(1);
 await expect(bar).toHaveAttribute('aria-label','Writing part 2 of 3…');await expect(status).toHaveText('Writing part 2 of 3…');
 expect(await value()).toBeGreaterThanOrEqual(last);last=await value();
 await expect(viewer.getByTestId('figure-section-menu-0')).toBeDisabled();
 const at0=await within(first);
 expect(at0.y).toBeGreaterThan(summary.y);expect(await within(viewer.getByTestId('figure-summary'))).toEqual(summary);
 expect((await within(viewer.getByTestId('figure-progress'))).y).toBeGreaterThan(at0.y+at0.height-1);
 await viewer.getByTestId('figure-progress').scrollIntoViewIfNeeded();
 await page.screenshot({path:streamShot('part-1-of-3-light')});
 await page.emulateMedia({colorScheme:'dark'});await page.screenshot({path:streamShot('part-1-of-3-dark')});await page.emulateMedia({colorScheme:'light'});
 // The second (it has a crop, its frame reserved as it appears) and the third, each below; nothing above moves.
 await step(request,3);
 await expect(walk.locator('.figure-section')).toHaveCount(2);
 await expect(viewer.getByTestId('figure-section-1').getByTestId('figure-crop')).toBeVisible();
 expect(await within(first)).toEqual(at0);expect(await within(viewer.getByTestId('figure-summary'))).toEqual(summary);
 const at1=await within(viewer.getByTestId('figure-section-1'));
 await expect(bar).toHaveAttribute('aria-label','Writing part 3 of 3…');
 expect(await value()).toBeGreaterThanOrEqual(last);
 await viewer.getByTestId('figure-progress').scrollIntoViewIfNeeded();
 await page.screenshot({path:streamShot('part-2-of-3-light')});
 await page.emulateMedia({colorScheme:'dark'});await page.screenshot({path:streamShot('part-2-of-3-dark')});await page.emulateMedia({colorScheme:'light'});
 await step(request,3);
 await expect(walk.locator('.figure-section')).toHaveCount(3);
 expect(await within(first)).toEqual(at0);expect(await within(viewer.getByTestId('figure-section-1'))).toEqual(at1);
 // Every announced part is in and the walkthrough isn't yet: no made-up value until it is done.
 await expect(bar).toHaveAttribute('aria-label','Writing part 4…');await expect(bar).not.toHaveAttribute('aria-valuenow');
 expect((await step(request)).left).toBe(0);
 // Done: the bar fades out, the parts' menus open, the note that needs the whole walkthrough shows; nothing moved.
 await expect(viewer.getByTestId('figure-progress')).toHaveCount(0);
 await expect(viewer.getByTestId('figure-skeleton-part')).toHaveCount(0);
 await expect(status).toHaveText('Done');
 await expect(viewer.getByTestId('figure-section-menu-0')).toBeEnabled();
 await expect(walk.getByTestId('figure-coverage-fallback')).toContainText('whole figure above');
 expect(await within(first)).toEqual(at0);expect(await within(viewer.getByTestId('figure-section-1'))).toEqual(at1);
 for(const scheme of ['light','dark'] as const){
  await page.emulateMedia({colorScheme:scheme});
  await viewer.getByTestId('figure-summary').scrollIntoViewIfNeeded();await page.screenshot({path:streamShot(`done-${scheme}`)});
  await viewer.getByTestId('figure-section-2').scrollIntoViewIfNeeded();await page.screenshot({path:streamShot(`done-end-${scheme}`)});
 }
 await page.emulateMedia({colorScheme:'light'});
 expect((await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json()).requests).toHaveLength(1);
});

test('under Reduce Motion the progress bar doesn’t move or fade',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 await page.emulateMedia({reducedMotion:'reduce'});
 const viewer=await explainStreaming(page,request,'step');
 const bar=viewer.getByRole('progressbar'),motion=()=>bar.locator('.figure-progress-fill').evaluate(e=>[getComputedStyle(e).animationName,getComputedStyle(e).transitionDuration]);
 await expect(bar).toHaveAttribute('aria-label','Reading the figure…');
 expect(await motion()).toEqual(['none','0s']);
 await page.screenshot({path:streamShot('reading-reduced-motion-light')});
 await step(request,7);
 await expect(viewer.getByTestId('figure-section-0')).toBeVisible();
 expect(await motion()).toEqual(['none','0s']);
 await step(request,20);
 await expect(viewer.getByTestId('figure-walkthrough').locator('.figure-section')).toHaveCount(3);
 // No fade: the bar goes with the walkthrough's end.
 await expect(viewer.getByTestId('figure-progress')).toHaveCount(0,{timeout:250});
});

test('a server without progress events still shows the walkthrough: Reading the figure…, then all of it',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 // A server before 2026-10-22 sends only the whole walkthrough; Reading comes from the stream's opening.
 const viewer=await explainStreaming(page,request,'old');
 const old=viewer.getByRole('progressbar');
 await expect(old).toHaveAttribute('aria-label','Reading the figure…');
 await expect(viewer.getByTestId('figure-skeleton-summary')).toBeVisible();
 await page.screenshot({path:streamShot('old-server-reading-light')});
 await expect(viewer.getByTestId('figure-summary')).toContainText('The figure compares two pipelines');
 await expect(viewer.getByTestId('figure-walkthrough').locator('.figure-section')).toHaveCount(3);
 await expect(viewer.getByTestId('figure-progress')).toHaveCount(0);
 await expect(viewer.getByTestId('figure-section-1').getByTestId('figure-crop')).toBeVisible();
 await page.screenshot({path:streamShot('old-server-done-light')});
});

// Owner, 2026-10-22: "when you try to click into a subfigure and zoom. The transition needs to be improved … whenever you
// try to interact with it, it becomes a full screen thing, with the outline fading away so you can see where the subfigure
// was in relation to the entire figure … with not really any in-between" (FIGURE_VIEW.md "Full screen on any interaction").
const fsShot=(name:string)=>`../../.artifacts/figure-fullscreen/web/${name}-${test.info().project.name}.png`;
async function partCards(page:Page,request:APIRequestContext){
 await openFixture(page,request,html,twoPlots);
 await request.post(`${fixtureOrigin}/__chat-fixture`,{data:{mode:'figure_panels_loose'}});
 await expect(page.frameLocator('[data-testid=reader-frame]').locator('figure').first()).toBeVisible({timeout:20000});
 const viewer=await openFigure(page);
 await viewer.getByTestId('figure-explain').click();
 await page.getByTestId('explainer-default').click();await viewer.getByRole('button',{name:'Allow and explain'}).click();
 const left=viewer.getByTestId('figure-section-0').getByTestId('figure-crop'),right=viewer.getByTestId('figure-section-1').getByTestId('figure-crop');
 await expect(right).toBeVisible();await expect(viewer.getByTestId('figure-progress')).toHaveCount(0);
 return {viewer,left,right};
}
/** What of the full-screen layer shows on screen: its clip (an inset) carried through its transform. */
const shownRect=(page:Page)=>page.getByTestId('figure-fullscreen-layer').evaluate(e=>{
 const cs=getComputedStyle(e),m=new DOMMatrixReadOnly(cs.transform==='none'?undefined:cs.transform);
 const n=(cs.clipPath.match(/inset\(([^)]*)\)/)?.[1]??'0px').split('round')[0].trim().split(/\s+/).map(parseFloat);
 const [t,r,b,l]=[n[0],n[1]??n[0],n[2]??n[0],n[3]??n[1]??n[0]],W=innerWidth,H=innerHeight;
 const a=m.transformPoint({x:l,y:t}),z=m.transformPoint({x:W-r,y:H-b});
 return {x:a.x,y:a.y,width:z.x-a.x,height:z.y-a.y};
});
const outlineOpacity=(page:Page)=>page.getByTestId('figure-fullscreen').getByTestId('part-outline').evaluate(e=>Number(getComputedStyle(e).opacity));

test('a part card opens full screen in one step from the card; its outline fades; a double tap toggles the whole figure; Esc goes back into the card',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 const {right}=await partCards(page,request);
 // The card is still: no zoom controls, the page scrolls over it; it says it opens full screen.
 await expect(right.locator('..').getByRole('button',{name:/Zoom/})).toHaveCount(0);
 expect(await right.evaluate(e=>getComputedStyle(e).touchAction)).toBe('pan-y');
 await right.scrollIntoViewIfNeeded();
 const card=(await right.boundingBox())!;
 // Freeze the transition at its start (Chromium's animation clock), then let it run slowly, to see each moment.
 const cdp=await page.context().newCDPSession(page);await cdp.send('Animation.enable');
 await cdp.send('Animation.setPlaybackRate',{playbackRate:0});
 await right.click();
 const full=page.getByTestId('figure-fullscreen'),stage=full.getByTestId('fullscreen-crop');
 await expect(full).toBeVisible();await expect(full).toHaveAttribute('data-phase','opening');
 // At its start the figure is exactly the card: where it was and as it framed the part.
 const start=await shownRect(page);
 for(const k of ['x','y','width','height'] as const) expect(Math.abs(start[k]-card[k]),k).toBeLessThan(2.5);
 await page.screenshot({path:fsShot('opening-start-light')});
 // About a third of the way: the card starts wider now that the figure page covers the paper (owner, 2026-10-22).
 await cdp.send('Animation.setPlaybackRate',{playbackRate:0.05});await page.waitForTimeout(1600);await cdp.send('Animation.setPlaybackRate',{playbackRate:0});
 const mid=await shownRect(page),viewport=page.viewportSize()!;
 expect(mid.width).toBeGreaterThan(card.width+4);expect(mid.width).toBeLessThan(viewport.width-4);
 await expect(stage.getByTestId('part-outline')).toBeVisible();
 await page.screenshot({path:fsShot('mid-transition-light')});
 await page.emulateMedia({colorScheme:'dark'});await page.screenshot({path:fsShot('mid-transition-dark')});await page.emulateMedia({colorScheme:'light'});
 await cdp.send('Animation.setPlaybackRate',{playbackRate:1});
 // Settled: the whole screen, framed on the part, the part outlined, then the outline fades over about a second.
 await expect(full).toHaveAttribute('data-phase','open');
 // A moment on (the bar has come in; the outline has only begun to fade), held still for the screenshots.
 await cdp.send('Animation.setPlaybackRate',{playbackRate:0.1});await page.waitForTimeout(1200);await cdp.send('Animation.setPlaybackRate',{playbackRate:0});
 const settled=await shownRect(page);
 expect(Math.round(settled.width)).toBe(viewport.width);expect(Math.round(settled.height)).toBe(viewport.height);
 await expect(stage).toHaveAttribute('data-view','part');
 expect(await outlineOpacity(page)).toBeGreaterThan(0.5);
 for(const scheme of ['light','dark'] as const){await page.emulateMedia({colorScheme:scheme});await page.screenshot({path:fsShot(`settled-outline-${scheme}`)});}
 await page.emulateMedia({colorScheme:'light'});
 await cdp.send('Animation.setPlaybackRate',{playbackRate:1});
 await expect.poll(()=>outlineOpacity(page),{timeout:3000}).toBe(0);
 for(const scheme of ['light','dark'] as const){await page.emulateMedia({colorScheme:scheme});await page.screenshot({path:fsShot(`settled-faded-${scheme}`)});}
 await page.emulateMedia({colorScheme:'light'});
 // The whole figure to roam: a double tap (or the toggle) shows all of it, again the part (outlined again, then fading).
 await stage.dblclick();await expect(stage).toHaveAttribute('data-view','whole');await expect(full.getByTestId('fullscreen-toggle')).toHaveText('Show part');
 await page.waitForTimeout(450);await page.screenshot({path:fsShot('whole-light')});
 await full.getByTestId('fullscreen-toggle').click();await expect(stage).toHaveAttribute('data-view','part');
 // Wheel and the − / + buttons zoom; arrows pan.
 await stage.hover();await page.mouse.wheel(0,-300);await expect(stage).toHaveAttribute('data-view','custom');
 await full.getByRole('button',{name:'Zoom out'}).click();
 await stage.press('ArrowLeft');
 // Esc goes back into the card, which has the focus again.
 await page.keyboard.press('Escape');
 await expect(full).toHaveAttribute('data-phase','closing');
 await expect(full).toHaveCount(0);
 await expect(right).toBeFocused();
});

test('every interaction with a card opens it full screen: tap, pinch, a sideways drag, ⌃ + wheel, Enter and its button; an upward or downward drag does not',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 const {right}=await partCards(page,request);
 await right.scrollIntoViewIfNeeded();
 const full=page.getByTestId('figure-fullscreen');
 const closeIt=async()=>{await expect(full).toHaveAttribute('data-phase','open');await full.getByTestId('fullscreen-close').click();await expect(full).toHaveCount(0);};
 const b=(await right.boundingBox())!,cx=b.x+b.width/2,cy=b.y+b.height/2;
 const pointer=(type:string,id:number,x:number,y:number)=>right.dispatchEvent(type,{pointerId:id,pointerType:'touch',isPrimary:id===1,clientX:x,clientY:y,bubbles:true});
 // A vertical drag is the page's: nothing opens.
 await pointer('pointerdown',1,cx,cy);await pointer('pointermove',1,cx+2,cy+30);await pointer('pointercancel',1,cx+2,cy+30);
 await page.waitForTimeout(300);await expect(full).toHaveCount(0);
 // Pinch: a second finger.
 await pointer('pointerdown',1,cx-10,cy);await pointer('pointerdown',2,cx+10,cy);await closeIt();
 await pointer('pointerup',1,cx-10,cy);await pointer('pointerup',2,cx+10,cy);
 // A sideways drag.
 await pointer('pointerdown',1,cx,cy);await pointer('pointermove',1,cx+30,cy+3);await closeIt();await pointer('pointerup',1,cx+30,cy+3);
 // A trackpad pinch (⌃ + wheel).
 await page.mouse.move(cx,cy);await page.keyboard.down('Control');await page.mouse.wheel(0,-40);await page.keyboard.up('Control');await closeIt();
 // Enter on the focused card, and the Full screen button.
 await right.focus();await page.keyboard.press('Enter');await closeIt();
 await right.locator('..').getByRole('button',{name:'Full screen',exact:true}).click();await closeIt();
 if(test.info().project.name==='phone'){
  // A swipe down at the whole figure closes it (touch).
  await right.click();await expect(full).toHaveAttribute('data-phase','open');
  const stage=full.getByTestId('fullscreen-crop');await stage.dblclick();await expect(stage).toHaveAttribute('data-view','whole');
  const s=(await stage.boundingBox())!,x=s.x+s.width/2,y=s.y+s.height/2;
  const touch=(type:string,yy:number)=>stage.dispatchEvent(type,{pointerId:7,pointerType:'touch',isPrimary:true,clientX:x,clientY:yy,bubbles:true});
  await touch('pointerdown',y);await touch('pointermove',y+80);await touch('pointermove',y+220);await touch('pointerup',y+220);
  await expect(full).toHaveCount(0);
 }
});

test('under Reduce Motion the full screen cross-fades, and the outline shows for a second, then goes without a fade',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 await page.emulateMedia({reducedMotion:'reduce'});
 const {right}=await partCards(page,request);
 await right.scrollIntoViewIfNeeded();await right.click();
 const full=page.getByTestId('figure-fullscreen');
 await expect(full).toHaveAttribute('data-phase','open');
 // No movement: the layer is the whole screen from the start.
 expect(await page.getByTestId('figure-fullscreen-layer').evaluate(e=>getComputedStyle(e).transform)).toMatch(/^(none|matrix\(1, 0, 0, 1, 0, 0\))$/);
 expect(await outlineOpacity(page)).toBe(1);
 await page.screenshot({path:fsShot('reduced-motion-outline-light')});
 await expect.poll(()=>outlineOpacity(page),{timeout:2500}).toBe(0);
 expect(await full.getByTestId('part-outline').evaluate(e=>getComputedStyle(e).transitionDuration)).toBe('0s');
 await page.keyboard.press('Escape');await expect(full).toHaveCount(0);
});
