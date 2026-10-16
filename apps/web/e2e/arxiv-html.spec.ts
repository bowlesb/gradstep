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
 // The paper's own citation link ("[1]" to its bibliography) jumps with Back offered, and Back returns (build 31 report).
 // With the chat pane open a wide reader is at its narrowest: Back must still be in view in the toolbar (owner report, build 35).
 // On a phone the pane is an overlay over the paper, so it stays closed there.
 const wide=(page.viewportSize()?.width??0)>=1100; // the chat is beside the paper from 1,100 px; a drawer below (Shell.RIGHT_INLINE)
 if(wide&&!await page.getByTestId('chat-pane').isVisible())await page.getByTestId('ask').click();
 if(wide)await expect(page.getByTestId('chat-pane')).toBeVisible();
 await frame.locator('a[href^="#b-"]').first().click();
 await expect(page.getByTestId('citation-back')).toBeVisible();
 await expect(page.getByTestId('citation-back')).toBeInViewport();
 await page.getByTestId('citation-back').click();
 await expect(page.getByTestId('citation-back')).toBeHidden();
 expect(sourceRequests).toBe(2);expect(pdfRequests).toBe(0);expect(artifacts).toBe(0);
 if(!await page.getByTestId('chat-pane').isVisible())await page.getByTestId('ask').click();
 await page.getByRole('textbox',{name:'Message',exact:true}).fill('Explain the authored equation.');
 await page.getByRole('button',{name:'Send',exact:true}).click();
 await page.getByRole('button',{name:'Allow and get answer'}).click();
 await expect(page.getByTestId('chat-pane').getByRole('region',{name:'Conversation'})).toContainText('objective');
 const evidence=await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json();
 expect(evidence.requests[0].mode).toBe('paper');expect(evidence.requests[0].document_id).toBeUndefined();
 expect(evidence.requests[0].local_context).toMatchObject({format:'reader-local-context-v2',membership_id:member,source_id:'2601.01234',revision:2});
 expect(JSON.stringify(evidence.events)).not.toContain('Explain the authored equation');
 expect(pdfRequests).toBe(0);expect(artifacts).toBe(0);
 // The device numbered the paper for the model; its answer cites [¶2], which lands in the paper with Back offered.
 expect(evidence.requests[0].local_context.format).toBe('reader-local-context-v2');
 expect(evidence.requests[0].local_context.text.startsWith('[¶1] # Authored HTML fixture\n\n[¶2] A. Author')).toBe(true);
 const cite=page.getByTestId('chat-assistant').locator('.cite').first();
 const drawer=await page.getByTestId('pane-right').evaluate(e=>e.classList.contains('overlay'));
 await expect(cite).toHaveText('¶2');
 // From the top of the paper the jump offers no Back (it would go nowhere); read further down first and Back names
 // where it returns ("Back to 1 Introduction"), with an X that dismisses the offer.
 // A tall screen may hold the whole fixture paper: then there's nowhere else to have been, and no Back.
 const scrolled=await frame.locator('body').evaluate(()=>{scrollTo(0,document.documentElement.scrollHeight);return scrollY>4;});
 await cite.click();
 if(scrolled){await expect(page.getByTestId('citation-back')).toBeVisible();await expect(page.getByTestId('citation-back')).toHaveAccessibleName(/^Back to /);}
 if(drawer){
  // A chat that covers the paper (phone, narrow window) closes so the passage shows: the paper is on top, not just
  // present under the drawer; Back to chat reopens it (PaperView's reader.chat.back).
  await expect(page.getByTestId('pane-right')).toBeHidden();
  const box=(await page.getByTestId('reader-frame').boundingBox())!;
  expect(await page.evaluate(([x,y])=>document.elementFromPoint(x,y)?.getAttribute('data-testid'),[box.x+box.width/2,box.y+box.height/2])).toBe('reader-frame');
  // With Back to chat and Back in a phone's toolbar, the paper column still doesn't scroll sideways.
  expect(await page.locator('.pane-center').evaluate(e=>[e.scrollLeft,e.scrollWidth-e.clientWidth])).toEqual([0,0]);
  await expect(page.getByTestId('contents')).toBeInViewport();
  expect(await page.locator('.paper-toolbar').evaluate(e=>e.scrollLeft)).toBe(0);
 }else await expect(page.getByTestId('chat-back')).toHaveCount(0);
 if(scrolled)await page.getByTestId('citation-dismiss').click();
 await expect(page.getByTestId('citation-back')).toHaveCount(0);
 const backToChat=async()=>{if(drawer){await page.getByTestId('chat-back').click();await expect(page.getByTestId('chat-pane')).toBeVisible();await expect(page.getByTestId('chat-back')).toHaveCount(0);}};
 await backToChat();
 await frame.locator('body').evaluate(()=>scrollTo(0,0));
 await expect.poll(()=>frame.locator('body').evaluate(()=>scrollY)).toBe(0);
 await cite.click();
 await expect(page.getByTestId('citation-back')).toHaveCount(0);
 await backToChat();
 // The answer's suggested follow-up fills the message box; nothing is sent until the reader does.
 await page.getByTestId('follow-ups-toggle').click(); // on request (build 46)
 await page.getByTestId('follow-up').first().click();
 await expect(page.getByRole('textbox',{name:'Message',exact:true})).toHaveValue('How is β chosen?');
 expect((await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json()).requests).toHaveLength(1);
 await page.screenshot({path:`../../.artifacts/html-browser-${test.info().project.name}.png`});
 // Figures in chat (consent v3): a question naming Figure 1 carries that figure's image from the paper, and the
 // answer's parts are cropped from it under the answer; a click shows the whole figure with the parts outlined.
 await page.getByRole('textbox',{name:'Message',exact:true}).fill('What does Figure 1 show?');
 await page.getByRole('button',{name:'Send',exact:true}).click();
 await expect(page.getByTestId('figure-part-inline').first()).toBeVisible();
 const asked=(await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json()).requests[1];
 expect(asked.consent_version).toBe('cloud-ai-v3');
 expect(asked.figures).toHaveLength(1);
 expect(asked.figures[0]).toMatchObject({id:'F1',media_type:'image/jpeg',caption:'Figure 1: A test figure.'});
 expect(asked.figures[0].data.startsWith('/9j/')).toBe(true);
 // Each part's crop sits in the answer where it is discussed (2026-10-15); no marker is ever shown as text.
 const answerWithParts=page.getByTestId('chat-assistant').last();
 const inline=answerWithParts.getByTestId('figure-part-inline');
 await expect(inline).toHaveCount(2);
 await expect(inline.locator('.figure-part-crop img')).toHaveCount(2);
 await expect(answerWithParts).not.toContainText('[[part');
 const order=await answerWithParts.evaluate(el=>[...el.querySelectorAll('.answer-markdown p, [data-testid=figure-part-inline]')].map(n=>n.matches('[data-testid=figure-part-inline]')?'part':(n.textContent??'').slice(0,12)));
 expect(order).toEqual(['Figure 1 has','part','The left hal','part','The right ha']);
 const parts=answerWithParts.getByTestId('figure-parts-overview');
 await expect(parts).toBeVisible();
 await answerWithParts.evaluate(el=>el.scrollIntoView({block:'start'}));
 await page.screenshot({path:`../../.artifacts/html-browser-figure-parts-inline-${test.info().project.name}.png`});
 await parts.getByRole('button',{name:/2 parts outlined/}).click();
 const whole=page.getByRole('dialog',{name:'The figure, part by part'});
 await expect(whole.locator('.figure-part-outline')).toHaveCount(2);
 await expect(whole).toContainText('The left half of the figure.');
 await page.screenshot({path:`../../.artifacts/html-browser-figure-parts-${test.info().project.name}.png`});
 await whole.getByRole('button',{name:'Done'}).click();
 // A figure question that names no number: the model asks for the figure it means, and the question goes again with it.
 await page.getByRole('textbox',{name:'Message',exact:true}).fill('Break down the most complex figure into its parts');
 await page.getByRole('button',{name:'Send',exact:true}).click();
 await expect(page.getByTestId('figure-parts-overview')).toHaveCount(2);
 const both=(await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json()).requests.slice(2);
 expect(both.map((r:{figures?:unknown[]})=>r.figures?.length??0)).toEqual([0,1]);
 expect(both[0].capabilities).toContain('figure_requests');
 expect(both[1].figures[0].caption).toBe('Figure 1: A test figure.');
 await expect(page.getByTestId('chat-pane')).not.toContainText('Let me look at Figure 1.');
});
// Build 57 (2610.20399): arXiv has no HTML for this version. The reader says so and offers the PDF, which the browser
// opens from arXiv itself; Try again can't help, so it isn't offered.
test('a paper without arXiv HTML offers its PDF from arXiv, not Try again',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 await request.post(`${fixtureOrigin}/__reset`);
 const asked:string[]=[];
 await page.route('https://arxiv.org/**',async route=>{asked.push(route.request().url());await route.fulfill({status:404,contentType:'text/html',headers:{'access-control-allow-origin':'*'},body:'<p>No HTML</p>'});});
 await page.route(`${fixtureOrigin}/rest/v1/rpc/v3_library_page`,async route=>{
  const response=await route.fetch(),body=await response.json();
  const row=body.entries.find((e:{kind:string})=>e.kind==='item');
  body.entries=[{kind:'import',id:member,created_seq:row.created_seq,state_seq:row.state_seq,intent_revision:1,visible:true,phase:'source_only',source:'arxiv',source_id:'2601.01234',requested_revision:2,source_revision:2,
   metadata_id:row.metadata_id,version_id:row.version_id,metadata_recorded_at:row.metadata_recorded_at,source_url:'https://arxiv.org/abs/2601.01234v2',retryable:false,metadata:{title:'A PDF-only paper',authors:['Fixture author'],categories:['cs.LG']}}];
  body.has_more=false;body.next_cursor={format:2,account_id:body.account_id,through:body.baseline_cursor,created_seq:row.created_seq,id:member,kind:'import'};
  await route.fulfill({response,json:body});
 });
 await page.route(`${fixtureOrigin}/rest/v1/rpc/v3_library_changes`,async route=>{const response=await route.fetch(),body=await response.json();body.changes=[];body.has_more=false;body.next_cursor=body.through;await route.fulfill({response,json:body});});
 await page.goto('/');await page.getByTestId('email').fill('returning@example.test');await page.getByTestId('send-code').click();
 await page.getByTestId('code').fill('123456');await page.getByTestId('verify').click();
 await page.getByTestId('use-recovery-code').click();await page.getByTestId('recovery-code').fill(RECOVERY_CODE);await page.getByTestId('recover').click();
 await page.getByTestId('library-table').getByRole('link',{name:'A PDF-only paper',exact:true}).click();
 await expect(page.getByRole('heading',{name:'No web version of this paper'})).toBeVisible({timeout:20000});
 const pdf=page.getByTestId('reader-open-pdf');
 await expect(pdf).toHaveAttribute('href','https://arxiv.org/pdf/2601.01234v2');
 await expect(pdf).toHaveAttribute('target','_blank');
 await expect(page.getByRole('button',{name:'Try again'})).toHaveCount(0);
 expect(asked).toEqual(['https://arxiv.org/html/2601.01234v2']);
 await page.screenshot({path:`../../.artifacts/html-browser-no-html-${test.info().project.name}.png`});
});
