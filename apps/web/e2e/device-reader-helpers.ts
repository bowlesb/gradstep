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

export async function choosePDF(page:Page,name:string,buffer:Buffer) {
 await page.getByRole('button',{name:'Add paper',exact:true}).click();
 const dialog=page.getByRole('dialog',{name:'Add paper'});
 await dialog.locator('input[type=file]').setInputFiles({name,mimeType:'application/pdf',buffer});
 await dialog.getByRole('button',{name:'Add PDF',exact:true}).click();
 return dialog;
}
