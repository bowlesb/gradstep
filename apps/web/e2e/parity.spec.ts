// Browser parity with the apps (cross-surface audit, 2026-10-15): Feed → reading, the library's marks, tag chips.
import {readFileSync} from 'node:fs';
import {expect,test} from '@playwright/test';
import {signInReader} from './device-reader-helpers';
import {durableKeys} from './key-capability';
const html=readFileSync(new URL('../../../tests/fixtures/reader-arxiv/source.html',import.meta.url));
const raster=readFileSync(new URL('../../../tests/fixtures/reader-mathpix/figure-exif.jpg',import.meta.url));

test('Feed → reading: Add prepares the paper here with its percent, In library opens it without a second download',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 let documents=0;
 await page.route('https://arxiv.org/**',async route=>{
  const url=route.request().url();
  if(/\/html\/2604\.01001v7$/.test(url)){documents++;await new Promise(r=>setTimeout(r,1200));await route.fulfill({status:200,contentType:'text/html',headers:{'access-control-allow-origin':'*'},body:html});}
  else if(/\/html\/2604\.01001v7\/figure\.jpg$/.test(url))await route.fulfill({status:200,contentType:'image/jpeg',headers:{'access-control-allow-origin':'*'},body:raster});
  else await route.abort();
 });
 await signInReader(page,request);
 await page.screenshot({path:`../../.artifacts/parity-web-library-before-${test.info().project.name}.png`});
 await page.getByRole('link',{name:'Feed'}).click();
 const card=page.getByTestId('feed-grid').locator('li').filter({hasText:'scaling sparse attention'});
 await card.getByRole('button',{name:'+ Add to library'}).click();
 // From Add until the paper is ready here, the Library's spinner (owner, build 58): no check before then, the percent
 // under the spinner once preparation reports one (DiscoveryAddControl's preparing).
 const adding=card.getByTestId('feed-preparing');
 await expect(adding).toBeVisible();await expect(adding.locator('.spinner')).toBeVisible();
 await expect(card.getByTestId('feed-open')).toHaveCount(0);
 await expect(adding).toHaveText(/^\d{1,3}%$/,{timeout:15_000});
 await expect(adding).toHaveAttribute('aria-label',/^Adding to your library, \d{1,3}%\. Show the Library$/);
 await page.screenshot({path:`../../.artifacts/parity-web-feed-preparing-${test.info().project.name}.png`});
 // The spinner shows the Library; the paper keeps preparing meanwhile.
 await adding.click();
 await expect(page.getByTestId('library-table')).toBeVisible();
 await page.getByRole('link',{name:'Feed'}).click();
 const open=card.getByTestId('feed-open');
 await expect(open).toBeEnabled({timeout:15_000});await expect(open).toHaveText('✓ In library');
 // The library marks it new (never opened) and on this device (prepared in this tab).
 await page.getByTestId('back-to-library').click();
 const row=page.getByTestId('paper-row').filter({hasText:'Paper 2604.01001'}); // the fixture's title for an added paper
 await expect(row.getByTestId('new-dot')).toBeVisible();
 await expect(row.getByTestId('device-badge')).toHaveAttribute('aria-label','On this device (prepared in this tab)');
 await expect(page.getByTestId('paper-row').filter({hasText:'Direct Preference Optimization'}).getByTestId('device-badge')).toHaveAttribute('aria-label',/^Not on this device yet/);
 await page.screenshot({path:`../../.artifacts/parity-web-library-after-${test.info().project.name}.png`});
 // Back in the Feed, In library opens the paper at once: no Downloading screen, no second download.
 await page.getByRole('link',{name:'Feed'}).click();
 await card.getByTestId('feed-open').click();
 await expect(page).toHaveURL(/\/paper\//);
 await expect(page.getByText(/^(Downloading|Preparing)… \d+%$/)).toHaveCount(0);
 await expect(page.frameLocator('[data-testid=reader-frame]').locator('math').first()).toBeVisible();
 expect(documents).toBe(1);
 // Opened: no longer new.
 await page.getByTestId('back-to-library').click();
 await expect(row.getByTestId('new-dot')).toHaveCount(0);
});

test('a tag chip filters by its tag, shows which one is active, and clears when tapped again',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 await signInReader(page,request);
 const width=page.viewportSize()!.width;
 // The Tags column is on by default only where the table has room; the chip filter works the same either way.
 const chip=page.getByTestId('library-table').locator('button.tag').first();
 test.skip(!await chip.count(),'No tag chips in this layout.');
 const tag=(await chip.textContent())!.trim();
 const all=await page.getByTestId('paper-row').count();
 await chip.click();
 const active=page.getByTestId('library-table').locator('button.tag.on',{hasText:tag}).first();
 await expect(active).toHaveAttribute('aria-pressed','true');
 const filtered=await page.getByTestId('paper-row').count();
 expect(filtered).toBeLessThanOrEqual(all);
 await page.screenshot({path:`../../.artifacts/parity-web-tag-${width}.png`});
 await active.click();
 await expect(page.getByTestId('library-table').locator('button.tag.on')).toHaveCount(0);
 await expect(page.getByTestId('paper-row')).toHaveCount(all);
 // A visit starts with all tags, as the apps do (B3): a tag chosen before a reload doesn't come back; the status filter does.
 await chip.click();
 await expect(page.getByTestId('library-table').locator('button.tag.on')).not.toHaveCount(0);
 await page.evaluate(()=>localStorage.setItem('gradstep.library.filter',JSON.stringify('unread')));
 await page.reload();
 await expect(page.getByTestId('library-table')).toBeVisible();
 await expect(page.getByTestId('library-table').locator('button.tag.on')).toHaveCount(0);
 expect(await page.evaluate(()=>localStorage.getItem('gradstep.library.tag'))).toBeNull();
 expect(await page.evaluate(()=>localStorage.getItem('gradstep.library.filter'))).toBe('"unread"');
});
