// The equation view (docs/architecture/EQUATION_VIEW.md): a tapped equation opens large with Explain and Ask in chat
// beside each other and nothing asked of the AI (owner, build 59); Explain describes its symbols, then background is
// offered; ¶ links land in the paper with Back; no credit counts anywhere. Both requests are the chat's own.
import {readFileSync} from 'node:fs';
import {expect,test} from '@playwright/test';
import {RECOVERY_CODE} from './fixture-keys.mjs';
import {fixtureOrigin} from './environment';
import {durableKeys} from './key-capability';
const html=readFileSync(new URL('../../../tests/fixtures/reader-arxiv/source.html',import.meta.url));
const raster=readFileSync(new URL('../../../tests/fixtures/reader-mathpix/figure-exif.jpg',import.meta.url));
const member='58000000-0000-4000-8000-000000000003';
// The authored arXiv fixture in the reader, served as `source` (the official HTML the device prepares).
async function openFixture(page:import('@playwright/test').Page,request:import('@playwright/test').APIRequestContext,source:Buffer|string){
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

test('a tapped equation opens large, explained only on request, background after that, then into the chat',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 await openFixture(page,request,html);
 const frame=page.frameLocator('[data-testid=reader-frame]');
 const display=frame.locator('.reader-display[data-reader-equation]').first();
 await expect(display).toBeVisible({timeout:20000});
 const chats=async()=>(await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json()).requests as Record<string,unknown>[];

 // The tapped equation offers its view right after Explain; a text selection does not.
 await display.click();
 const bar=page.getByRole('toolbar',{name:'Selected passage'});
 await expect(bar.getByRole('button')).toHaveText(['Explain','Equation','Why it matters','Related','Add paper']);
 await bar.getByTestId('equation-open').click();
 const view=page.getByTestId('equation-view');
 await expect(view.getByRole('heading',{name:'Equation (1)'})).toBeVisible();
 await expect(view.frameLocator('[data-testid=equation-frame]').locator('math')).toBeVisible();
 // Owner, build 59: nothing is asked on opening; Explain and Ask in chat sit side by side under the equation.
 const explain=view.getByTestId('equation-explain'),ask=view.getByTestId('equation-ask');
 await expect(explain).toHaveText('Explain');await expect(ask).toHaveText('Ask in chat');
 const [explainBox,askBox]=[(await explain.boundingBox())!,(await ask.boundingBox())!];
 expect(Math.abs(explainBox.y-askBox.y)).toBeLessThan(2);expect(explainBox.x).toBeLessThan(askBox.x);
 await expect(view.getByRole('heading',{name:'What it says'})).toHaveCount(0);await expect(view.getByTestId('equation-more')).toHaveCount(0);
 await expect(view.getByTestId('equation-consent')).toHaveCount(0);
 await page.waitForTimeout(500);expect(await chats()).toHaveLength(0);
 await page.screenshot({path:`../../.artifacts/equation-view-opened-${test.info().project.name}.png`});
 // Explain asks the chat's own consent first; nothing is sent before it.
 await explain.click();
 await expect(view.getByTestId('equation-consent')).toBeVisible();expect(await chats()).toHaveLength(0);
 await view.getByRole('button',{name:'Allow and explain'}).click();
 await expect(view.getByTestId('equation-summary')).toHaveText('It squares x: the value multiplied by itself.');
 await expect(view.getByTestId('equation-symbols').locator('li')).toHaveCount(3);
 // Every symbol is typeset: from its LaTeX, or from its text when the model gave none ("L_DPO(π_θ; π_ref)").
 for(let i=0;i<3;i++)await expect(view.getByTestId('equation-symbols').locator('li').nth(i).locator('.equation-symbol math')).toBeVisible();
 await expect(view.getByTestId('equation-symbols').locator('li').nth(2).locator('.equation-symbol msub')).toHaveCount(3);
 await expect(view.getByTestId('equation-source')).toHaveText('From the paper ¶2');
 await expect(view.getByTestId('equation-symbols')).toContainText('General meaning');
 // Explained: Explain has gone, Ask in chat stays, More background is offered.
 await expect(explain).toHaveCount(0);await expect(ask).toBeVisible();await expect(view.getByTestId('equation-more')).toBeVisible();

 // Size: larger keeps growing the equation; sideways scroll keeps the size instead of fitting the width.
 const frameBox=view.getByTestId('equation-frame');
 const before=(await frameBox.boundingBox())!.height;
 await expect(view.getByTestId('equation-scale')).toHaveText('160%');
 await view.getByRole('button',{name:'Larger equation'}).click();await view.getByRole('button',{name:'Larger equation'}).click();
 await expect(view.getByTestId('equation-scale')).toHaveText('240%');
 await expect.poll(async()=>(await frameBox.boundingBox())!.height).toBeGreaterThan(before);
 await view.getByTestId('equation-scroll').check();await expect(view.getByTestId('equation-scroll')).toBeChecked();

 // Background only on request, rendered like an answer.
 await view.getByTestId('equation-more').click();
 const background=view.getByTestId('equation-background');
 await expect(background).toContainText('That symmetry is why the paper uses it.');
 // Every paragraph stays once streaming has finished (landing-page capture, 2026-10-15: only the first remained).
 await page.waitForTimeout(3000);
 await expect(background.locator('p')).toHaveCount(3);await expect(background.locator('h2, h3, h4')).toHaveCount(1);await expect(background.locator('li')).toHaveCount(2);
 // It reads in view: its heading was brought up, and its last paragraph can be scrolled to.
 await expect(view.getByRole('heading',{name:'Background'})).toBeInViewport();
 const last=background.locator('p').last();await last.scrollIntoViewIfNeeded();await expect(last).toBeInViewport();
 await expect(background).toContainText('For x = 3 it gives 9.');await expect(background).toContainText('That symmetry is why the paper uses it.');
 // No credit counts in the view (owner, build 59).
 await expect(view.getByTestId('equation-credits')).toHaveCount(0);await expect(view).not.toContainText(/\d+\s+credits?\b/);
 const sent=await chats();
 expect(sent.map(r=>r.action)).toEqual(['equation','equation_background']);
 for(const r of sent){
  expect(r).toMatchObject({mode:'paper',consent_version:'cloud-ai-v4',selection:{quote:'x^2'},messages:[{role:'user',text:'Equation (1)'}],
   local_context:{format:'reader-local-context-v2',membership_id:member}});
  for(const key of ['topic_title','follow_ups','figures','document_id'])expect(r).not.toHaveProperty(key);
 }
 // No conversation was made.
 expect((await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json()).events).toHaveLength(0);
 await page.screenshot({path:`../../.artifacts/equation-view-${test.info().project.name}.png`});
 // Dark: the panel and the equation's own frame follow the app's appearance.
 await page.emulateMedia({colorScheme:'dark'});
 // The frame is rebuilt in the new colours; a read during the rebuild just tries again.
 await expect.poll(()=>view.frameLocator('[data-testid=equation-frame]').locator('html').evaluate(e=>getComputedStyle(e).colorScheme).catch(()=>'')).toBe('dark');
 await page.screenshot({path:`../../.artifacts/equation-view-${test.info().project.name}-dark.png`});
 await page.emulateMedia({colorScheme:'light'});

 // A symbol's paragraph: the view closes and the paper lands there, with Back offered unless the reader was at the top.
 const atTop=await frame.locator('body').evaluate(()=>scrollY<4);
 await view.getByTestId('equation-source').click();
 await expect(view).toBeHidden();
 if(atTop)await expect(page.getByTestId('citation-back')).toHaveCount(0);else await expect(page.getByTestId('citation-back')).toBeVisible();

 // Reopened, the results come back without a new request; Ask in chat starts a draft about the equation, unsent.
 await display.click();await bar.getByTestId('equation-open').click();
 await expect(view.getByTestId('equation-summary')).toBeVisible();await expect(view.getByTestId('equation-background')).toContainText('That symmetry is why the paper uses it.');
 await expect(view.getByTestId('equation-explain')).toHaveCount(0);
 await expect(view.getByTestId('equation-scale')).toHaveText('240%');
 expect(await chats()).toHaveLength(2);
 await view.getByTestId('equation-ask').click();
 await expect(view).toBeHidden();
 const composer=page.getByRole('textbox',{name:'Message',exact:true});
 await expect(composer).toBeVisible();await expect(composer).toHaveValue('About “\\[x^2\\]”: ');
 await expect(composer).toBeFocused();
 expect(await chats()).toHaveLength(2);
});

// Contents with Figures, Tables and Equations (owner, build 59): Contents first; a figure or table row is its number and
// caption and opens the figure with its whole caption (Show in paper), Figures starts with View as tiles, and an equation
// row goes to the equation in the paper with Back.
async function openContents(page:import('@playwright/test').Page){
 const tabs=page.getByRole('tablist',{name:'Show',exact:true});
 // Wide windows keep the contents in the side panel once the paper is ready; narrow ones open it as a drawer.
 await expect(page.getByTestId('contents')).toBeEnabled();
 if(!await tabs.isVisible())await page.getByTestId('contents').click();
 await expect(tabs).toBeVisible();
 return tabs;
}
/** Closes the contents (a side panel stays open beside the paper) and opens it again. */
async function reopenContents(page:import('@playwright/test').Page){
 if(await page.getByRole('tablist',{name:'Show',exact:true}).isVisible())await page.getByTestId('contents').click();
 await expect(page.getByRole('tablist',{name:'Show',exact:true})).toHaveCount(0);
 return openContents(page);
}
test('Contents, Figures, Tables and Equations: each row goes into the paper',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 // Its table as arXiv sometimes publishes one, an image (a TikZ table): the index lists figures and tables with images.
 await openFixture(page,request,html.toString('utf8').replace(/<figure id="tab1">[\s\S]*?<\/figure>/,'<figure id="tab1"><img src="2601.01234v2/figure.jpg"><figcaption>Table 1: Values.</figcaption></figure>'));
 const frame=page.frameLocator('[data-testid=reader-frame]');
 await expect(frame.locator('.reader-display[data-reader-equation]').first()).toBeVisible({timeout:20000});
 let tabs=await openContents(page);
 await expect(tabs.getByRole('tab')).toHaveText(['Contents','Figures','Tables','Equations']);
 await expect(tabs.getByRole('tab',{name:'Contents'})).toHaveAttribute('aria-selected','true');
 await expect(page.getByRole('navigation',{name:'Contents'}).getByRole('button')).toHaveText(['1 Introduction','References']);
 await page.screenshot({path:`../../.artifacts/contents-tabs-${test.info().project.name}.png`});

 // Figures: View as tiles, then "Figure 1 — caption"; the row opens the figure with its whole caption and Show in paper.
 await tabs.getByRole('tab',{name:'Figures'}).click();
 await expect(page.getByTestId('contents-figure-tiles')).toHaveText('View as tiles');
 await expect(page.getByTestId('contents-figure-0')).toHaveText('Figure 1 — A test figure.');
 await expect(page.getByTestId('contents-figure-1')).toHaveCount(0); // the table is under Tables
 await page.screenshot({path:`../../.artifacts/contents-figures-${test.info().project.name}.png`});
 await page.getByTestId('contents-figure-0').click();
 const viewer=page.getByRole('dialog',{name:'Figures'});
 await expect(viewer.frameLocator('iframe.figure-frame').locator('figcaption')).toContainText('A test figure.');
 await viewer.getByTestId('show-in-paper').click();
 await expect(viewer).toBeHidden(); await expect(page.getByTestId('citation-back')).toBeVisible();
 await page.getByTestId('citation-back').click(); await expect(page.getByTestId('citation-back')).toBeHidden();

 // Reopened, Contents is chosen again; View as tiles is the figure gallery.
 tabs=await reopenContents(page);
 await expect(tabs.getByRole('tab',{name:'Contents'})).toHaveAttribute('aria-selected','true');
 await tabs.getByRole('tab',{name:'Figures'}).click(); await page.getByTestId('contents-figure-tiles').click();
 await expect(viewer.getByRole('list',{name:'Figures'}).getByRole('button')).toHaveCount(2);
 await viewer.getByRole('button',{name:'Done'}).click(); await expect(viewer).toBeHidden();

 // Tables, then Equations by keyboard: the printed number and the LaTeX as text; the row goes to it with Back.
 tabs=await openContents(page);
 await tabs.getByRole('tab',{name:'Figures'}).click(); await tabs.getByRole('tab',{name:'Figures'}).press('ArrowRight');
 await expect(tabs.getByRole('tab',{name:'Tables'})).toBeFocused();
 await expect(page.getByTestId('contents-table-0')).toHaveText('Table 1 — Values.');
 await page.keyboard.press('ArrowRight'); await expect(tabs.getByRole('tab',{name:'Equations'})).toHaveAttribute('aria-selected','true');
 const row=page.getByTestId('contents-equation-0');
 await expect(row.locator('.contents-row-title')).toHaveText('Equation (1)'); await expect(row.locator('.contents-row-math')).toHaveText('x²');
 await page.screenshot({path:`../../.artifacts/contents-equations-${test.info().project.name}.png`});
 await row.click();
 await expect(page.getByTestId('citation-back')).toBeVisible();
 await expect(frame.locator('.reader-display[data-reader-equation]').first()).toBeInViewport();
 // Dark: the same quiet tabs and rows.
 await page.emulateMedia({colorScheme:'dark'});
 tabs=await openContents(page); await tabs.getByRole('tab',{name:'Figures'}).click();
 await page.screenshot({path:`../../.artifacts/contents-figures-${test.info().project.name}-dark.png`});
 await page.emulateMedia({colorScheme:'light'});
});

test('Contents says when a paper has no tables or equations',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 const source=html.toString('utf8').replace(/<table class="ltx_equation"[\s\S]*?<\/table>/,'').replace(/<figure id="tab1">[\s\S]*?<\/figure>/,'');
 await openFixture(page,request,source);
 await expect(page.frameLocator('[data-testid=reader-frame]').locator('h2').first()).toBeVisible({timeout:20000});
 const tabs=await openContents(page);
 await tabs.getByRole('tab',{name:'Tables'}).click(); await expect(page.locator('#contents-tabpanel')).toHaveText('No tables');
 await tabs.getByRole('tab',{name:'Equations'}).click(); await expect(page.locator('#contents-tabpanel')).toHaveText('No equations');
 await tabs.getByRole('tab',{name:'Figures'}).click(); await expect(page.getByTestId('contents-figure-0')).toHaveText('Figure 1 — A test figure.');
});

test('a wide equation fits the width, or keeps its size and scrolls sideways',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 const term=(i:number)=>`<msub><mi>a</mi><mn>${i}</mn></msub><mo>+</mo>`;
 const wide=`<table class="ltx_equation" id="eq2"><tbody><tr><td><math alttext="S=a_1+\\dots+b" display="block"><semantics><mrow><mi>S</mi><mo>=</mo>${Array.from({length:40},(_,i)=>term(i+1)).join('')}<mi>b</mi></mrow><annotation encoding="application/x-tex">S=a_1+\\dots+b</annotation></semantics></math></td><td><span class="ltx_tag_equation">(2)</span></td></tr></tbody></table>`;
 const source=html.toString('utf8').replace('</tbody></table>',`</tbody></table>${wide}`);
 await openFixture(page,request,source);
 const frame=page.frameLocator('[data-testid=reader-frame]');
 await frame.locator('.reader-display[data-reader-equation]').nth(1).click();
 await page.getByTestId('equation-open').click();
 const view=page.getByTestId('equation-view');
 await expect(view.getByRole('heading',{name:'Equation (2)'})).toBeVisible();
 const box=view.frameLocator('[data-testid=equation-frame]').locator('#eq-box');
 await expect(box.locator('math')).toBeVisible();
 const overflow=()=>box.evaluate(e=>e.scrollWidth-e.clientWidth);
 if(await view.getByTestId('equation-scroll').isChecked())await view.getByTestId('equation-scroll').uncheck();
 await expect.poll(overflow).toBeLessThanOrEqual(1);
 await view.getByTestId('equation-scroll').check();
 await expect.poll(overflow).toBeGreaterThan(100);
 // No page-level sideways scroll at any width.
 expect(await page.evaluate(()=>document.documentElement.scrollWidth-document.documentElement.clientWidth)).toBeLessThanOrEqual(0);
 await page.screenshot({path:`../../.artifacts/equation-view-wide-${test.info().project.name}.png`});
 await view.getByTestId('equation-scroll').uncheck();
});
