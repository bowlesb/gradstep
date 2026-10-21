// The equation view (docs/architecture/EQUATION_VIEW.md): a tapped equation's AI Explainer opens it large and asks at
// once, after the chat's consent (owner, build 62); its one top row has Explain in Chat, AI Explainer until it is asked,
// and the X; its heading switches to the paper's other equations, which wait for AI Explainer. The explanation describes
// its symbols, then background is offered; ¶ links land in the paper with Back; no credit counts anywhere. Both requests
// are the chat's own. Contents › Equations lists "Equation (n)" rows and a tile view.
import {readFileSync} from 'node:fs';
import {expect,test} from '@playwright/test';
import {RECOVERY_CODE} from './fixture-keys.mjs';
import {fixtureOrigin} from './environment';
import {durableKeys} from './key-capability';
const html=readFileSync(new URL('../../../tests/fixtures/reader-arxiv/source.html',import.meta.url));
const raster=readFileSync(new URL('../../../tests/fixtures/reader-mathpix/figure-exif.jpg',import.meta.url));
const member='58000000-0000-4000-8000-000000000003';
// Two more display equations: a numbered one, and an unnumbered one in its own section (its row names the section).
const equations=html.toString('utf8')
 .replace('</tr></tbody></table>\n<figure','</tr></tbody></table>\n<table class="ltx_equation" id="eq2"><tbody><tr><td><math alttext="y=\\frac{a}{b}" display="block"><semantics><mrow><mi>y</mi><mo>=</mo><mfrac><mi>a</mi><mi>b</mi></mfrac></mrow><annotation encoding="application/x-tex">y=\\frac{a}{b}</annotation></semantics></math></td><td><span class="ltx_tag_equation">(2)</span></td></tr></tbody></table>\n<figure')
 .replace('<section id="refs">','<section id="S2"><h2>2 Method</h2><p id="p2">The method sets one value.</p><table class="ltx_equation" id="eq3"><tbody><tr><td><math alttext="z=1" display="block"><semantics><mrow><mi>z</mi><mo>=</mo><mn>1</mn></mrow><annotation encoding="application/x-tex">z=1</annotation></semantics></math></td></tr></tbody></table></section><section id="refs">');
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
   metadata_id:row.metadata_id,version_id:row.version_id,metadata_recorded_at:row.metadata_recorded_at,source_url:'https://arxiv.org/abs/2601.01234v2',retryable:false,metadata:{title:'Authored HTML fixture',authors:['A. Author'],categories:['cs.LG']}}];
  body.has_more=false;body.next_cursor={format:2,account_id:body.account_id,through:body.baseline_cursor,created_seq:row.created_seq,id:member,kind:'import'};
  await route.fulfill({response,json:body});
 });
 await page.route(`${fixtureOrigin}/rest/v1/rpc/v3_library_changes`,async route=>{const response=await route.fetch(),body=await response.json();body.changes=[];body.has_more=false;body.next_cursor=body.through;await route.fulfill({response,json:body});});
 await page.goto('/');await page.getByTestId('email').fill('returning@example.test');await page.getByTestId('send-code').click();
 await page.getByTestId('code').fill('123456');await page.getByTestId('verify').click();
 await page.getByTestId('use-recovery-code').click();await page.getByTestId('recovery-code').fill(RECOVERY_CODE);await page.getByTestId('recover').click();
 await page.getByTestId('library-table').getByRole('link',{name:'Authored HTML fixture',exact:true}).click();
}

test('equation explanation, model choice and follow-up remain together with encrypted history',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 await openFixture(page,request,equations);
 const frame=page.frameLocator('[data-testid=reader-frame]'), display=frame.locator('.reader-display[data-reader-equation]').first();
 await expect(display).toBeVisible({timeout:20000});
 // Metadata controls are independent of the verified paper text.
 await expect(frame.getByRole('button',{name:'More papers by A. Author'})).toBeVisible();
 const keywords=frame.locator('[data-sr-paper-tags]'); await expect(keywords).toContainText('Machine learning');
 expect(await keywords.evaluate(e=>e.nextElementSibling?.textContent)).toContain('Introduction');
 await keywords.click(); await expect(page.getByRole('dialog',{name:'Edit tags',exact:true})).toBeVisible();
 await page.getByRole('dialog',{name:'Edit tags',exact:true}).getByRole('button',{name:'Cancel',exact:true}).click();
 await display.click(); const bar=page.getByRole('toolbar',{name:'Selected passage'});
 await expect(bar.getByRole('button')).toHaveText(['Chat about Equation','AI Explainer','Related']);
 await bar.getByRole('button',{name:'Chat about Equation',exact:true}).click();
 const view=page.getByTestId('equation-view'), context=view.getByTestId('contextual-chat');
 await expect(context.getByRole('textbox',{name:'Message',exact:true})).toBeVisible();
 const chats=async()=>(await(await request.get(`${fixtureOrigin}/__chat-evidence`)).json()).requests;
 expect(await chats()).toHaveLength(0);
 await context.getByTestId('composer-model').click();
 const options=page.getByRole('dialog',{name:'Answer options',exact:true});
 await options.getByRole('radio',{name:'Haiku',exact:true}).click(); await options.getByRole('button',{name:'Close',exact:true}).click();
 await view.getByTestId('equation-explain').click();await view.getByRole('button',{name:'Allow and explain'}).click();
 await expect(view.getByTestId('equation-summary')).toHaveText('It squares x: the value multiplied by itself.');
 expect((await chats())[0].profile.model).toBe('haiku');
 await view.getByTestId('equation-more').click();await expect(view.getByTestId('equation-background')).toContainText('That symmetry is why the paper uses it.');
 await context.getByRole('textbox',{name:'Message',exact:true}).fill('Why is it squared?');await context.getByRole('button',{name:'Send',exact:true}).click();
 await expect(context.locator('.chat-message.assistant').first()).toBeVisible();
 await expect(view).toBeVisible();
 let requests=await chats();expect(requests.at(-1).messages.at(-1).text).toBe('About Equation (1): Why is it squared?');
 expect(requests.at(-1).selection.quote).toContain('x^2');expect(requests.at(-1).selection.quote).toContain('It squares x');expect(requests.at(-1).profile.model).toBe('haiku');
 await context.getByRole('textbox',{name:'Message',exact:true}).fill('And when it is negative?');await context.getByRole('button',{name:'Send',exact:true}).click();
 await expect(context.locator('.chat-message.assistant')).toHaveCount(2);
 await expect(context.getByRole('button',{name:'Stop',exact:true})).toHaveCount(0);
 await expect(context.getByRole('button',{name:'Send',exact:true})).toBeVisible();
 requests=await chats();expect(requests.at(-1).messages.length).toBeGreaterThanOrEqual(3);
 await page.screenshot({path:`../../.artifacts/feedback/all-20261018/equation-chat-${test.info().project.name}.png`});
 await view.getByTestId('equation-close').click();await display.click();await bar.getByRole('button',{name:'Chat about Equation',exact:true}).click();
 await expect(page.getByTestId('contextual-chat').locator('.chat-message.assistant')).toHaveCount(2);expect(await chats()).toHaveLength(requests.length);
});

// Contents with Figures, Tables and Equations (owner, build 59): Contents first; a figure or table row is its number and
// caption and opens the figure with its whole caption (Show in paper), Figures starts with View as tiles, and an equation
// row ("Equation (1)", no LaTeX; owner, build 62) goes to the equation in the paper with Back, as does its tile.
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
 await openFixture(page,request,equations.replace(/<figure id="tab1">[\s\S]*?<\/figure>/,'<figure id="tab1"><img src="2601.01234v2/figure.jpg"><figcaption>Table 1: Values.</figcaption></figure>'));
 const frame=page.frameLocator('[data-testid=reader-frame]');
 await expect(frame.locator('.reader-display[data-reader-equation]').first()).toBeVisible({timeout:20000});
 let tabs=await openContents(page);
 await expect(tabs.getByRole('tab')).toHaveText(['Contents','Figures','Tables','Equations']);
 await expect(tabs.getByRole('tab',{name:'Contents'})).toHaveAttribute('aria-selected','true');
 await expect(page.getByRole('navigation',{name:'Contents'}).getByRole('button')).toHaveText(['1 Introduction','2 Method','References']);
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
 await viewer.getByTestId('figure-close').click(); await expect(viewer).toBeHidden();

 // Tables, then Equations by keyboard: "Equation (n)" without the LaTeX, View as tiles first; the row goes to it with Back.
 tabs=await openContents(page);
 await tabs.getByRole('tab',{name:'Figures'}).click(); await tabs.getByRole('tab',{name:'Figures'}).press('ArrowRight');
 await expect(tabs.getByRole('tab',{name:'Tables'})).toBeFocused();
 await expect(page.getByTestId('contents-table-0')).toHaveText('Table 1 — Values.');
 await page.keyboard.press('ArrowRight'); await expect(tabs.getByRole('tab',{name:'Equations'})).toHaveAttribute('aria-selected','true');
 const row=page.getByTestId('contents-equation-0');
 await expect(page.getByTestId('contents-equation-tiles')).toHaveText('View as tiles');
 await expect(page.getByRole('list',{name:'Equations'}).locator('.contents-row')).toHaveText(['Equation (1)','Equation (2)','Equation · 2 Method']);
 await expect(row).toHaveText('Equation (1)');
 await page.screenshot({path:`../../.artifacts/contents-equations-${test.info().project.name}.png`});
 await row.click();
 await expect(page.getByTestId('citation-back')).toBeVisible();
 await expect(frame.locator('.reader-display[data-reader-equation]').first()).toBeInViewport();
 await page.getByTestId('citation-back').click(); await expect(page.getByTestId('citation-back')).toBeHidden();

 // View as tiles: every equation typeset in one frame, each tile named as its row; a tile goes where its row goes.
 tabs=await openContents(page); await tabs.getByRole('tab',{name:'Equations'}).click();
 await page.getByTestId('contents-equation-tiles').click();
 const tiles=page.getByRole('dialog',{name:'Equations'});
 const grid=tiles.frameLocator('[data-testid=equation-tiles-frame]');
 await expect(tiles.locator('iframe')).toHaveCount(1);
 await expect(grid.locator('.eq-tile-label')).toHaveText(['Equation (1)','Equation (2)','Equation · 2 Method']);
 for(const name of ['Equation (1)','Equation (2)','Equation · 2 Method'])await expect(grid.getByRole('button',{name,exact:true})).toHaveCount(1);
 await expect(grid.locator('.eq-tile math')).toHaveCount(3);
 // Each equation fits its tile.
 for(const fits of await grid.locator('.eq-tile-math').evaluateAll(boxes=>boxes.map(b=>{const inner=b.firstElementChild!.getBoundingClientRect(),outer=b.getBoundingClientRect();return inner.width<=outer.width+1&&inner.height<=outer.height+1;})))expect(fits).toBe(true);
 await page.screenshot({path:`../../.artifacts/contents-equation-tiles-${test.info().project.name}.png`});
 await page.emulateMedia({colorScheme:'dark'});
 await expect.poll(()=>grid.locator('html').evaluate(e=>getComputedStyle(e).colorScheme).catch(()=>'')).toBe('dark');
 await page.screenshot({path:`../../.artifacts/contents-equation-tiles-${test.info().project.name}-dark.png`});
 await page.emulateMedia({colorScheme:'light'});
 await grid.getByRole('button',{name:'Equation (2)'}).click();
 await expect(tiles).toBeHidden();
 await expect(page.getByTestId('citation-back')).toBeVisible();
 await expect(frame.locator('.reader-display[data-reader-equation]').nth(1)).toBeInViewport();
 // Dark: the same quiet tabs and rows.
 await page.emulateMedia({colorScheme:'dark'});
 tabs=await openContents(page); await tabs.getByRole('tab',{name:'Figures'}).click();
 await page.screenshot({path:`../../.artifacts/contents-figures-${test.info().project.name}-dark.png`});
 await page.emulateMedia({colorScheme:'light'});
});

// Reader revision 16: a paper's HTML tables are listed by their captions (most papers' tables are tables, not images, and
// the Tables tab said "No tables"). A row opens the table with its whole caption; Show in paper goes there with Back.
test('Contents › Tables lists the paper’s HTML tables by caption; a row opens the table, Show in paper goes to it',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 await openFixture(page,request,html);
 const frame=page.frameLocator('[data-testid=reader-frame]');
 await expect(frame.locator('.reader-table').first()).toBeAttached({timeout:20000});
 const tabs=await openContents(page);
 await tabs.getByRole('tab',{name:'Tables'}).click();
 await expect(page.getByTestId('contents-table-0')).toHaveText('Table 1 — Values.');
 await expect(page.getByTestId('contents-table-1')).toHaveCount(0);
 await page.screenshot({path:`../../.artifacts/contents-tables-${test.info().project.name}.png`});
 await page.getByTestId('contents-table-0').click();
 const detail=page.getByRole('dialog',{name:'Table 1'});
 await expect(detail.frameLocator('iframe.figure-frame').locator('th').first()).toHaveText('Value');
 await expect(detail.frameLocator('iframe.figure-frame').getByText('Table 1: Values.')).toBeVisible();
 // A table's sheet names the table (build 76: it said "Chat about Figure").
 await expect(detail.getByTestId('figure-reference-ask')).toHaveText('Chat about Table');
 await page.screenshot({path:`../../.artifacts/contents-table-detail-${test.info().project.name}.png`});
 await detail.getByTestId('figure-reference-go').click();
 await expect(detail).toBeHidden(); await expect(page.getByTestId('citation-back')).toBeVisible();
 await expect(frame.locator('.reader-table').first()).toBeInViewport();
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

test('a wide equation fits at 100 percent and automatically pans when enlarged',async({page,request})=>{
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
 while(await view.getByTestId('equation-scale').textContent()!=='100%') await view.getByRole('button',{name:'Smaller equation'}).click();
 await expect.poll(overflow).toBeLessThanOrEqual(1);
 await view.getByRole('button',{name:'Larger equation'}).click(); await view.getByRole('button',{name:'Larger equation'}).click();
 await expect.poll(overflow).toBeGreaterThan(50);
 await box.evaluate(e=>{e.scrollLeft=60;});expect(await box.evaluate(e=>e.scrollLeft)).toBeGreaterThan(0);
 await expect(view.getByText('Scroll sideways',{exact:true})).toHaveCount(0);
 // No page-level sideways scroll at any width.
 expect(await page.evaluate(()=>document.documentElement.scrollWidth-document.documentElement.clientWidth)).toBeLessThanOrEqual(0);
 await page.screenshot({path:`../../.artifacts/equation-view-wide-${test.info().project.name}.png`});

});


test('an author byline offers an author search without an AI request', async ({page,request}) => {
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 await openFixture(page,request,equations);
 const author=page.frameLocator('[data-testid=reader-frame]').getByRole('button',{name:'More papers by A. Author'});
 await expect(author).toBeVisible({timeout:20000}); await author.click();
 const search=page.waitForRequest(r=>r.url().includes('/functions/v1/discover?') && new URL(r.url()).searchParams.get('q')==='author:A. Author');
 await page.getByRole('dialog',{name:'Author',exact:true}).getByRole('button',{name:'Find papers by A. Author'}).click();
 await search; await expect(page).toHaveURL(/\/$/);
 expect((await(await request.get(`${fixtureOrigin}/__chat-evidence`)).json()).requests).toHaveLength(0);
});
