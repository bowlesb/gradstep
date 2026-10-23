// The paper's AI Explainer (2026-10-22; docs/proposals/LEARNING_GUIDE.md "Paper AI Explainer"): Paper ⋯ › AI Explainer
// asks which model, the chat's consent, then streams the summary and each entry under the figure explainer's progress
// bar; at the end the diagram of how the concepts fit together. A ¶ lands in the paper with Back to AI Explainer (kept:
// no new request); Open in Chat continues in the paper's chat; Your assets › Paper explanations reopens it.
import {expect,test,type APIRequestContext,type Page} from '@playwright/test';
import {fixtureOrigin} from './environment';
import {durableKeys} from './key-capability';
import {openAuthoredPaper,PAPER_TITLE} from './authored-paper';
const SHOTS='../../.artifacts/web-e2e/study-explainer';
const step=async(request:APIRequestContext,count=1)=>(await (await request.post(`${fixtureOrigin}/__figure-step`,{data:{count}})).json()) as {waiting:number;left:number};
async function openExplainer(page:Page){
 await page.getByRole('button',{name:`Actions for ${PAPER_TITLE}`}).click();
 await page.getByRole('menuitem',{name:'AI Explainer',exact:true}).click();
 return page.getByRole('dialog',{name:'AI Explainer'});
}

test('AI Explainer: the paper’s background, key ideas and diagram stream in under a progress bar, then stay',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 const project=test.info().project.name;
 await openAuthoredPaper(page,request);
 await request.post(`${fixtureOrigin}/__chat-fixture`,{data:{figureStream:'step'}});
 const dialog=await openExplainer(page);
 // Which model first, then the chat's consent; nothing is asked before.
 await expect(page.getByRole('dialog',{name:'AI model'})).toBeVisible();
 expect((await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json()).requests).toHaveLength(0);
 await page.getByTestId('explainer-default').click();
 await dialog.getByRole('button',{name:'Allow and explain'}).click();
 await expect(dialog.getByTestId('paper-explainer-title')).toHaveText(PAPER_TITLE);
 const bar=dialog.getByRole('progressbar'),status=dialog.getByTestId('paper-progress-status');
 await expect(bar).toBeVisible();await expect(dialog.getByTestId('paper-skeleton-summary')).toBeVisible();
 await step(request);
 await expect(bar).toHaveAttribute('aria-label','Reading the paper…');await expect(bar).not.toHaveAttribute('aria-valuenow');
 await expect(status).toHaveText('Reading the paper…');
 await step(request,2);
 await expect(bar).toHaveAttribute('aria-label','Writing the summary…');await expect(bar).toHaveAttribute('aria-valuenow',/^\d+$/);
 const value=async()=>Number(await bar.getAttribute('aria-valuenow'));
 let last=await value();
 await step(request);
 await expect(dialog.getByTestId('paper-summary')).toContainText('trains a policy on preferences directly');
 await expect(bar).toHaveAttribute('aria-label','Writing the key concepts, 1 of 5…');
 await step(request,3);
 await expect(dialog.getByTestId('paper-background-item')).toHaveCount(1);
 await expect(bar).toHaveAttribute('aria-label','Writing the key concepts, 2 of 5…');
 expect(await value()).toBeGreaterThanOrEqual(last);last=await value();
 await page.screenshot({path:`${SHOTS}/paper-explainer-streaming-${project}-light.png`});
 await page.emulateMedia({colorScheme:'dark'});await page.screenshot({path:`${SHOTS}/paper-explainer-streaming-${project}-dark.png`});await page.emulateMedia({colorScheme:'light'});
 await step(request,6);
 await expect(dialog.getByTestId('paper-background-item')).toHaveCount(3);
 await expect(bar).toHaveAttribute('aria-label','Writing the key concepts, 4 of 5…');
 await step(request,3);
 await expect(dialog.getByTestId('paper-ideas-item')).toHaveCount(1);
 await expect(bar).toHaveAttribute('aria-label','Writing the key concepts, 5 of 5…');
 expect(await value()).toBeGreaterThanOrEqual(last);
 await step(request,3);
 // Every announced entry in: the links are on their way, the bar says so without a made-up value.
 await expect(bar).toHaveAttribute('aria-label','Drawing how it fits together…');await expect(bar).not.toHaveAttribute('aria-valuenow');
 await expect(dialog.getByTestId('paper-diagram')).toHaveCount(0);
 expect((await step(request)).left).toBe(0);
 await expect(dialog.getByTestId('paper-progress')).toHaveCount(0);
 await expect(status).toHaveText('Done');
 const diagram=dialog.getByTestId('paper-diagram');
 await expect(diagram).toBeVisible();await expect(diagram.locator('iframe')).toBeVisible();
 await expect(diagram.getByRole('alert')).toHaveCount(0);
 await expect(dialog.getByTestId('paper-background-item').first()).toContainText('Reinforcement learning from human feedback — Trains a reward model');
 const sent=(await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json()).requests;
 expect(sent).toHaveLength(1);
 expect(sent[0]).toMatchObject({action:'paper_explainer',mode:'paper',messages:[{role:'user',text:'Explain this paper'}]});
 for(const key of ['selection','figures','topic_title','follow_ups'])expect(sent[0][key]).toBeUndefined();
 await page.waitForTimeout(800);
 for(const scheme of ['light','dark'] as const){
  await page.emulateMedia({colorScheme:scheme});await page.waitForTimeout(300);
  await dialog.getByTestId('paper-summary').scrollIntoViewIfNeeded();await page.screenshot({path:`${SHOTS}/paper-explainer-done-${project}-${scheme}.png`});
  await diagram.scrollIntoViewIfNeeded();await page.waitForTimeout(300);await page.screenshot({path:`${SHOTS}/paper-explainer-diagram-${project}-${scheme}.png`});
 }
 await page.emulateMedia({colorScheme:'light'});
 // A ¶ lands in the paper with Back to AI Explainer, which shows it again without a request.
 await dialog.getByTestId('paper-concepts').getByRole('button',{name:'Go to paragraph 2'}).first().click();
 await expect(page.getByRole('dialog',{name:'AI Explainer'})).toHaveCount(0);
 await page.getByTestId('explainer-return').click();
 await expect(page.getByRole('dialog',{name:'AI Explainer'}).getByTestId('paper-diagram')).toBeVisible();
 expect((await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json()).requests).toHaveLength(1);
 // Open in Chat continues in the paper's chat (the figure explainer's handoff), with the explanation above it.
 await page.getByRole('dialog',{name:'AI Explainer'}).getByRole('button',{name:'Open in Chat'}).click();
 await expect(page.getByRole('dialog',{name:'AI Explainer'})).toHaveCount(0);
 const promoted=page.getByTestId('chat-pane').getByTestId('promoted-context');
 await expect(promoted).toContainText('This paper');await expect(promoted).toContainText('Bradley–Terry model');
 // The same cards follow it into the chat (build 82): the summary, Key concepts with their ¶ links, the drawn diagram.
 await expect(promoted.getByTestId('paper-summary')).toContainText('trains a policy on preferences directly');
 await expect(promoted.getByTestId('paper-background-item')).toHaveCount(3);await expect(promoted.getByTestId('paper-ideas-item')).toHaveCount(2);
 await expect(promoted.getByTestId('paper-diagram').locator('iframe')).toBeVisible();
 await expect(promoted.getByRole('button',{name:'Go to paragraph 2'}).first()).toBeVisible();
 await page.screenshot({path:`${SHOTS}/paper-explainer-open-in-chat-${project}-light.png`});
 // Your assets › Paper explanations lists it; a row reopens the paper's explainer.
 await page.getByTestId('account-menu').click();await page.getByTestId('open-settings').click();await page.getByTestId('assets-papers').click();
 const assets=page.getByRole('dialog',{name:'Paper explanations'});
 await expect(assets.getByTestId('explanation-paper')).toContainText(PAPER_TITLE);
 await assets.getByTestId('explanation-paper').click();
 await expect(page.getByRole('dialog',{name:'AI Explainer'}).getByTestId('paper-summary')).toBeVisible();
 expect((await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json()).requests).toHaveLength(1);
});
