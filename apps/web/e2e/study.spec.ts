// Study mode (reworked 2026-10-22; docs/proposals/LEARNING_GUIDE.md): "Enter Study Mode – Quiz me and help me learn" is
// offered after the starter questions and as the last suggested question; one tap sends the opening turn; the tutor's
// hidden notes go back with every turn and are never shown or stored; Hint and Explain instead send at once; Stop sends
// nothing. Suggested questions show the model's own picture question instead of the generic diagram rows.
import {expect,test} from '@playwright/test';
import {fixtureOrigin} from './environment';
import {durableKeys} from './key-capability';
import {openAuthoredPaper} from './authored-paper';
const SHOTS='../../.artifacts/web-e2e/study-explainer';
test('Study mode: one tap starts the tutor, Hint and Explain instead send at once, the notes stay hidden, Stop sends nothing',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 const project=test.info().project.name;
 await openAuthoredPaper(page,request);
 if(!await page.getByTestId('chat-pane').isVisible())await page.getByTestId('ask').click();
 const pane=page.getByTestId('chat-pane'),conversation=pane.getByRole('region',{name:'Conversation'});
 const field=page.getByRole('textbox',{name:'Message',exact:true});
 // The entry follows the starter questions in an empty paper chat.
 const entry=pane.getByTestId('chat-starters').getByTestId('study-entry');
 await expect(entry).toHaveText('Enter Study Mode – Quiz me and help me learn');
 await expect(pane.getByTestId('chat-starters').locator('button').last()).toHaveAttribute('data-testid','study-entry');
 await page.screenshot({path:`${SHOTS}/study-entry-${project}-light.png`});
 await entry.click();
 await page.getByRole('button',{name:'Allow and get answer'}).click();
 await expect(conversation).toContainText('what does attention compute?');
 await expect(page.getByTestId('chat-user')).toHaveText(/Quiz me and help me learn this paper\./);
 const bar=page.getByTestId('study-bar');
 await expect(bar).toBeVisible(); await expect(bar).toContainText('Study mode');
 await expect(field).toHaveAttribute('placeholder','Your answer');
 // No suggestions compete with the tutor's question; the hidden notes never show.
 await expect(page.getByTestId('follow-ups-toggle')).toHaveCount(0);
 await expect(conversation).not.toContainText('check the softmax');
 // The reader answers: the notes from the opening turn go with it.
 await field.fill('A weighted sum of the values.');
 await page.getByRole('button',{name:'Send',exact:true}).click();
 await expect(conversation).toContainText('What does the softmax do to large scores?');
 // Hint and Explain instead send their turn at once.
 await bar.getByRole('button',{name:'Hint',exact:true}).click();
 await expect(conversation).toContainText('What decides how much each value counts?');
 await bar.getByRole('button',{name:'Explain instead',exact:true}).click();
 await expect(conversation).toContainText('which value dominates');
 await expect(page.getByTestId('chat-user')).toHaveText([/Quiz me/,/A weighted sum/,/Give me a hint\./,/Explain it to me instead\./]);
 const evidence=await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json();
 expect(evidence.requests).toHaveLength(4);
 expect(evidence.requests.map((r:{action:string})=>r.action)).toEqual(['study','study','study','study']);
 expect(evidence.requests[0].study_state).toBeUndefined(); expect(evidence.requests[0].study).toBeUndefined(); expect(evidence.requests[0].follow_ups).toBeUndefined();
 expect(evidence.requests.slice(1).map((r:{study_state:{turn:number}})=>r.study_state.turn)).toEqual([1,2,3]);
 // Nothing of the notes reaches the encrypted history or the outbox.
 expect(JSON.stringify(evidence.events)).not.toContain('check the softmax');
 await page.waitForTimeout(400);
 await page.screenshot({path:`${SHOTS}/study-mode-${project}-light.png`});
 await page.emulateMedia({colorScheme:'dark'});
 await page.waitForTimeout(300);
 await page.screenshot({path:`${SHOTS}/study-mode-${project}-dark.png`});
 await page.emulateMedia({colorScheme:'light'});
 // While studying, the ⋯ menu offers End study mode; Stop leaves it without a request and keeps the conversation.
 await page.getByTestId('chat-menu').click();
 await expect(page.getByRole('menuitem',{name:'End study mode'})).toBeVisible();
 await page.keyboard.press('Escape');
 await bar.getByRole('button',{name:'Stop',exact:true}).click();
 await expect(page.getByTestId('study-bar')).toHaveCount(0);
 await expect(field).toHaveAttribute('placeholder','Ask anything about the paper');
 await expect(page.getByTestId('chat-assistant')).toHaveCount(4);
 expect((await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json()).requests).toHaveLength(4);
 // An ordinary question again: its suggestions show the model's picture question instead of the generic diagram rows,
 // and Enter Study Mode last.
 await field.fill('What does β do?');
 await page.getByRole('button',{name:'Send',exact:true}).click();
 await expect(page.getByTestId('chat-assistant')).toHaveCount(5);
 await page.getByTestId('follow-ups-toggle').click();
 const group=page.getByRole('group',{name:'Suggested questions'});
 await expect(group.getByTestId('follow-up')).toHaveText(['How is β chosen?','What does the KL term do?','Create a diagram explaining the background of the KL penalty']);
 await expect(group.getByTestId('follow-up-diagram')).toHaveCount(0);
 await expect(group.locator('button').last()).toHaveAttribute('data-testid','study-entry');
 await page.screenshot({path:`${SHOTS}/study-suggestions-${project}-light.png`});
 const last=await (await request.get(`${fixtureOrigin}/__chat-evidence`)).json();
 expect(last.requests.at(-1).action).toBeUndefined(); expect(last.requests.at(-1).follow_ups).toBe(true);
 // From the suggestions, Enter Study Mode starts again (the tutor reads the conversation so far).
 await group.getByTestId('study-entry').click();
 await expect(page.getByTestId('study-bar')).toBeVisible();
 await expect(page.getByTestId('chat-assistant')).toHaveCount(6);
});
