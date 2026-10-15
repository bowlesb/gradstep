// Line width and reading mode (docs/architecture/READING_MODE.md). Owner, 2026-10-15: a wider reading space should
// put more words on a line (as an option), and a full screen reading mode that is a great experience.
import {mkdirSync,readFileSync} from 'node:fs';
import {expect,test,type Page,type APIRequestContext} from '@playwright/test';
import {RECOVERY_CODE} from './fixture-keys.mjs';
import {fixtureOrigin} from './environment';
import {durableKeys} from './key-capability';

const base=readFileSync(new URL('../../../tests/fixtures/reader-arxiv/source.html',import.meta.url),'utf8');
const raster=readFileSync(new URL('../../../tests/fixtures/reader-mathpix/figure-exif.jpg',import.meta.url));
const member='58000000-0000-4000-8000-000000000004';
const sentence='The reader keeps every equation, figure and citation where the authors put them while the column follows the window. ';
const long=sentence.repeat(14);
// The authored fixture with two long sections, so lines can be measured and sections stepped through.
const html=base.replace('<section id="refs">',`<section id="S2"><h2>2 Method</h2><p id="p2">${long}</p><p id="p3">${long}</p><p id="p3b">See <a href="#S1.F1">Figure 1</a> again.</p></section>`
  +`<section id="S3"><h2>3 Results</h2><p id="p4">${long}</p><p id="p5">${long}</p><p id="p6">${long}</p></section><section id="refs">`);
const shots=process.env.READING_SCREENSHOTS?'../../.artifacts/reading-mode':null;

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
 await expect(page.frameLocator('[data-testid=reader-frame]').locator('p').filter({hasText:'The reader keeps every equation'}).first()).toBeVisible({timeout:20000});
}
const frame=(page:Page)=>page.frameLocator('[data-testid=reader-frame]');
// The compiled paper names its own blocks: the long paragraphs in order (0, 1 in Method; 2, 3, 4 in Results).
const para=(page:Page,n:number)=>frame(page).locator('p').filter({hasText:'The reader keeps every equation'}).nth(n);
const width=(page:Page,n:number)=>para(page,n).evaluate(e=>e.getBoundingClientRect().width);
/** The block at the top of the paper's viewport (its id), as the bridge measures reading places. */
const topBlock=(page:Page)=>frame(page).locator('body').evaluate(()=>[...document.querySelectorAll('[data-reader-block]')].find(e=>{const r=e.getBoundingClientRect();return r.height>0&&r.bottom>0;})?.id??null);

test.describe('desktop',()=>{
 test.beforeEach(({},info)=>{test.skip(info.project.name!=='desktop','Measured on the desktop project.');});

 test('line width: Comfortable keeps its measure, Full width puts more words on a line as the window widens, the place is kept',async({page,request})=>{
  test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
  await page.setViewportSize({width:1600,height:900});
  await openFixture(page,request);
  const control=page.getByTestId('line-width');
  await expect(control.getByRole('radio',{name:'Comfortable'})).toHaveAttribute('aria-checked','true');
  const comfortable=await width(page,0);
  await page.setViewportSize({width:1920,height:1080});
  await expect.poll(()=>width(page,0),{message:'Comfortable is capped: a wider window adds margins'}).toBeCloseTo(comfortable,0);
  // Reading part-way into the Method section, then widening the measure: the same paragraph stays at the top (one
  // with enough text below it to reach the top at the wider measure).
  await para(page,1).evaluate(e=>e.scrollIntoView({block:'start',behavior:'instant'}));
  await expect.poll(()=>topBlock(page)).not.toBeNull();
  const before=await topBlock(page);
  await control.getByRole('radio',{name:'Full width'}).click();
  await expect.poll(()=>width(page,0)).toBeGreaterThan(comfortable*1.3);
  expect(await topBlock(page),'the paragraph being read stays at the top').toBe(before);
  const full1920=await width(page,0);
  await page.setViewportSize({width:1440,height:860});
  await expect.poll(()=>width(page,0),{message:'Full width reflows: a narrower window, fewer words a line'}).toBeLessThan(full1920-300);
  await control.getByRole('radio',{name:'Wide'}).click();
  // Arrow keys move through the stops; the choice is remembered for the next paper opened in this browser.
  await control.getByRole('radio',{name:'Wide'}).press('ArrowLeft');
  await expect(control.getByRole('radio',{name:'Comfortable'})).toHaveAttribute('aria-checked','true');
  await control.getByRole('radio',{name:'Comfortable'}).press('ArrowLeft');
  await expect(control.getByRole('radio',{name:'Full width'})).toHaveAttribute('aria-checked','true');
  expect(await page.evaluate(()=>localStorage.getItem('gradstep.reader.lineWidth'))).toBe('"full"');
  // Figures stay a readable size and nothing scrolls the page sideways at any measure.
  const figure=await frame(page).locator('figure').first().evaluate(e=>e.getBoundingClientRect().width);
  expect(figure).toBeLessThanOrEqual(await width(page,0)+1);
  expect(await frame(page).locator('body').evaluate(()=>document.documentElement.scrollWidth<=document.documentElement.clientWidth+1)).toBe(true);
 });

 test('reading mode: the chrome steps aside, sections by key, figures and chat stay reachable, Esc returns to the same place and layout',async({page,request})=>{
  test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
  await page.setViewportSize({width:1440,height:900});
  await openFixture(page,request);
  // The layout before: whatever panels are open come back on exit.
  const panes=async()=>({left:await page.getByTestId('pane-left').isVisible(),right:await page.getByTestId('pane-right').isVisible()});
  const layout=await panes();
  await para(page,1).evaluate(e=>e.scrollIntoView({block:'start',behavior:'instant'}));
  await expect.poll(()=>topBlock(page)).not.toBeNull();
  const place=await topBlock(page);
  const paperWidth=async()=>page.getByTestId('reader-frame').evaluate(e=>e.getBoundingClientRect().width);

  await page.getByTestId('reading-mode').click();
  await expect(page.locator('.app')).toHaveClass(/\breading\b/);
  await expect(page.locator('.topbar')).toBeHidden();
  await expect(page.getByTestId('pane-left')).toBeHidden();await expect(page.getByTestId('pane-right')).toBeHidden();
  expect(await paperWidth(),'the paper takes the window').toBeGreaterThan(1400);
  expect(await topBlock(page),'entering keeps the place').toBe(place);
  await expect(page.getByTestId('reading-status')).toContainText('2 Method');
  if(shots){mkdirSync(shots,{recursive:true});await page.screenshot({path:`${shots}/web-reading-light.png`});}
  // The quiet bar steps aside, and comes back near the top edge.
  await expect(page.locator('.reader')).toHaveClass(/bar-hidden/,{timeout:6000});
  await page.mouse.move(700,8);
  await expect(page.locator('.reader')).not.toHaveClass(/bar-hidden/);

  // J / K: next and previous section, typed in the paper.
  await para(page,1).click();
  await page.keyboard.press('j');
  await expect(page.getByTestId('reading-status')).toContainText('3 Results');
  await page.keyboard.press('k');
  await expect(page.getByTestId('reading-status')).toContainText('2 Method');
  // Space pages down in the paper.
  const y=await frame(page).locator('body').evaluate(()=>scrollY);
  await page.keyboard.press('Space');
  await expect.poll(()=>frame(page).locator('body').evaluate(()=>scrollY)).toBeGreaterThan(y+200);

  // A link to the figure jumps to it with Back offered, as outside reading mode; the quiet bar stays while Back is
  // offered, and Back returns to the paragraph being read.
  const link=frame(page).locator('p',{hasText:'again.'}).locator('a');
  await link.scrollIntoViewIfNeeded();
  const origin=await frame(page).locator('body').evaluate(()=>scrollY);
  await link.click();
  await expect(page.getByTestId('citation-back')).toBeVisible();
  await expect(page.locator('.reader')).not.toHaveClass(/bar-hidden/);
  await page.waitForTimeout(1600);
  await expect(page.locator('.reader'),'the bar stays while Back is offered').not.toHaveClass(/bar-hidden/);
  await page.getByTestId('citation-back').click();
  await expect.poll(()=>frame(page).locator('body').evaluate(()=>scrollY)).toBeCloseTo(origin,-1);
  await expect(page.locator('.app')).toHaveClass(/\breading\b/);

  // The chat slides over the paper (]), which keeps its width and place; Esc closes it, Esc again leaves reading mode.
  const widthBefore=await paperWidth(), placeBefore=await topBlock(page);
  await frame(page).locator('body').press(']');
  await expect(page.getByTestId('pane-right')).toBeVisible();
  expect(await paperWidth(),'the paper does not reflow under the chat').toBeCloseTo(widthBefore,0);
  if(shots)await page.screenshot({path:`${shots}/web-reading-chat.png`});
  await page.keyboard.press('Escape');
  await expect(page.getByTestId('pane-right')).toBeHidden();
  await expect(page.locator('.app')).toHaveClass(/\breading\b/);
  expect(await topBlock(page)).toBe(placeBefore);
  await page.keyboard.press('Escape');
  await expect(page.locator('.app')).not.toHaveClass(/\breading\b/);
  await expect(page.locator('.topbar')).toBeVisible();
  expect(await panes(),'the panels come back as they were').toEqual(layout);
  await expect.poll(()=>page.evaluate(()=>!!document.fullscreenElement),{message:'full screen ends with reading mode'}).toBe(false);
  // F enters it again from the paper.
  await para(page,0).click();
  await page.keyboard.press('f');
  await expect(page.locator('.app')).toHaveClass(/\breading\b/);
  if(shots){
   await page.emulateMedia({colorScheme:'dark'});
   await page.mouse.move(700,8);
   await page.waitForTimeout(300);
   await page.screenshot({path:`${shots}/web-reading-dark.png`});
   await page.emulateMedia({colorScheme:'light'});
  }
  await page.getByTestId('reading-mode').click();
  await expect(page.locator('.app')).not.toHaveClass(/\breading\b/);
 });

 test('screenshots at each line width (READING_SCREENSHOTS=1)',async({page,request})=>{
  test.skip(!shots,'Set READING_SCREENSHOTS=1 to capture.');
  test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
  mkdirSync(shots!,{recursive:true});
  await page.setViewportSize({width:1440,height:900});
  await openFixture(page,request);
  await frame(page).getByRole('heading',{name:'2 Method'}).evaluate(e=>e.scrollIntoView({block:'start',behavior:'instant'}));
  for(const size of [1440,1920]){
   await page.setViewportSize({width:size,height:size===1920?1080:900});
   for(const stop of ['Comfortable','Wide','Full width']){
    await page.getByTestId('line-width').getByRole('radio',{name:stop}).click();
    await page.waitForTimeout(300);
    await page.screenshot({path:`${shots}/web-${size}-${stop.toLowerCase().replace(' ','-')}.png`});
   }
  }
 });
});
