import {expect, type Page, type APIRequestContext} from '@playwright/test';
import {RECOVERY_CODE} from './fixture-keys.mjs';
import {fixtureOrigin} from './environment';

export async function signInReader(page:Page,request:APIRequestContext) {
 await request.post(`${fixtureOrigin}/__reset`);
 await page.goto('/');await page.getByTestId('email').fill('returning@example.test');await page.getByTestId('send-code').click();
 await page.getByTestId('code').fill('123456');await page.getByTestId('verify').click();
 await page.getByTestId('use-recovery-code').click();await page.getByTestId('recovery-code').fill(RECOVERY_CODE);await page.getByTestId('recover').click();
 await expect(page.getByTestId('library-table')).toBeVisible();
}

export function guardLocalContent(page:Page) {
 const forbidden:string[]=[],bodies:string[]=[];
 page.on('request',r=>{
  if(/upload-pdf|\/storage\/|begin_pdf_upload|pdf_upload_part|mathpix|reader-artifact/.test(r.url()))forbidden.push(r.url());
  const body=r.postData();if(body)bodies.push(body);
 });
 return {assertPrivate(canaries:string[]){
  expect(forbidden).toEqual([]);
  for(const marker of ['%PDF-',...canaries])expect(bodies.join('\n')).not.toContain(marker);
 }};
}

/** Add paper: the first row of the Library's "…" (owner, build 75: "move the + option as a new row inside the dialogue on
 * the far right"; 2026-10-22: that is the Library's own "…", audit S10). */
export async function openAddPaper(page:Page) {
 if(!await page.getByTestId('library-options').isVisible())await page.getByTestId('back-to-library').click();
 await page.getByTestId('library-options').click();await page.getByTestId('add-paper').click();
}

/** Settings (audit S9): the account menu's Settings… opens the dialog with the apps' sections. */
export async function openSettings(page:Page) {
 await page.getByTestId('account-menu').click();await page.getByTestId('open-settings').click();
 const settings=page.getByRole('dialog',{name:'Settings'});await expect(settings).toBeVisible();
 return settings;
}

export async function choosePDF(page:Page,name:string,buffer:Buffer) {
 await openAddPaper(page);
 const dialog=page.getByRole('dialog',{name:'Add paper'});
 await dialog.locator('input[type=file]').setInputFiles({name,mimeType:'application/pdf',buffer});
 await dialog.getByRole('button',{name:'Add PDF',exact:true}).click();
 return dialog;
}
