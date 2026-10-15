// Study (experimental, 2026-10-14): an adaptive tutor on the paper numbered by the on-device HTML reader. The map
// travels with every turn, grows with complete answers, is drawn and listed, and ends without a trace in storage.
import {readFileSync} from 'node:fs';
import {expect,test} from '@playwright/test';
import {RECOVERY_CODE} from './fixture-keys.mjs';
import {fixtureOrigin} from './environment';
import {durableKeys} from './key-capability';
const html=readFileSync(new URL('../../../tests/fixtures/reader-arxiv/source.html',import.meta.url));
const raster=readFileSync(new URL('../../../tests/fixtures/reader-mathpix/figure-exif.jpg',import.meta.url));
const member='58000000-0000-4000-8000-000000000003';
test('Study this paper: one question at a time, the knowledge map grows with each answer and is never stored',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
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
 const frame=page.frameLocator('[data-testid=reader-frame]');
 await expect(frame.locator('[data-reader-block]')).not.toHaveCount(0,{timeout:20000});
 if(!await page.getByTestId('chat-pane').isVisible())await page.getByTestId('ask').click();
 const conversation=page.getByTestId('chat-pane').getByRole('region',{name:'Conversation'});
 // The offer sits in the empty paper chat; starting sends the opening turn as the reader's message.
 await page.getByTestId('study-start').click();
 await page.getByRole('button',{name:'Allow and get answer'}).click();
 await expect(conversation).toContainText('what does attention compute?');
 await expect(page.getByTestId('chat-user')).toContainText('Start studying this paper.');
 const panel=page.getByTestId('study-panel');
 await expect(panel.getByTestId('study-summary')).toContainText('1 concept');
 await expect(panel.getByTestId('study-now')).toContainText('Attention');
 await expect(page.getByRole('textbox',{name:'Message',exact:true})).toHaveAttribute('placeholder','Your answer…');
 // The map is drawn by the sandboxed diagram frame (no "couldn't draw"), and no follow-up chips compete with the tutor's question.
 await expect(panel.getByTestId('study-graph').locator('iframe')).toBeVisible();
 await expect(panel.getByRole('alert')).toHaveCount(0);
 await expect(page.getByTestId('follow-up')).toHaveCount(0);
 // The reader answers: the current map goes with the answer; the reply judges, teaches with a citation, and the map grows.
 await page.getByRole('textbox',{name:'Message',exact:true}).fill('A weighted sum of the values.');
 await page.getByRole('button',{name:'Send',exact:true}).click();
 await expect(conversation).toContainText('What does the softmax do');
 await expect(panel.getByTestId('study-summary')).toContainText('2 concepts · 1 known · 1 learning');
 await expect(panel.getByTestId('study-now')).toContainText('Softmax · Teaching');
 await panel.getByRole('button',{name:'Journey',exact:true}).click();
 await expect(panel.getByTestId('study-journey').locator('.study-chip')).toHaveText(['Attention','Softmax']);
 await panel.getByRole('button',{name:'Concepts',exact:true}).click();
 await expect(panel.getByTestId('study-concepts')).toContainText('Knows the weighted sum');
 await expect(panel.getByTestId('study-concepts')).toContainText('builds on Attention');
 // A concept's paragraph lands in the paper with Back offered, like an answer's citation.
 await page.frameLocator('[data-testid=reader-frame]').locator('body').evaluate(() => scrollTo(0, document.documentElement.scrollHeight)); // Back is offered only when there's somewhere to return to
 const drawer=await page.getByTestId('pane-right').evaluate(e=>e.classList.contains('overlay'));
 await panel.getByRole('button',{name:'Go to paragraph 2'}).first().click();
 await expect(page.getByTestId('citation-back')).toBeVisible();
 if(drawer)await page.getByTestId('chat-back').click(); // a phone's drawer closed for the passage; Back to chat reopens it
 const evidence=await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json();
 expect(evidence.requests).toHaveLength(2);
 expect(evidence.requests[0]).toMatchObject({action:'study',study:{concepts:[],links:[],journey:[]}});
 expect(evidence.requests[0].follow_ups).toBeUndefined();
 expect(evidence.requests[1].study.concepts.map((c:{id:string})=>c.id)).toEqual(['attention']);
 expect(evidence.requests[1].messages.at(-1).text).toBe('A weighted sum of the values.');
 // Nothing of the map reaches the encrypted history or the outbox: concept names are in no stored event.
 expect(JSON.stringify(evidence.events)).not.toContain('Softmax');
 await panel.getByRole('button',{name:'Map',exact:true}).click();
 await expect(panel.getByTestId('study-graph').locator('iframe')).toBeVisible();
 await page.waitForTimeout(1500);
 await page.screenshot({path:`../../.artifacts/study-${test.info().project.name}.png`});
 // Ending the study keeps the conversation and drops the map; the composer is an ordinary paper chat again.
 await panel.getByTestId('study-end').click();
 await expect(page.getByTestId('study-panel')).toHaveCount(0);
 await expect(page.getByRole('textbox',{name:'Message',exact:true})).toHaveAttribute('placeholder','Ask about this paper…');
 await expect(page.getByTestId('chat-assistant')).toHaveCount(2);
});
