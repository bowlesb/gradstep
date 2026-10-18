// Paper search in the browser, native parity (RootView's Library / arXiv switch, DiscoveryList, DiscoveryRow): the switch
// under the field while searching, the same states and rows, Add with its percent, In library opens the paper, / to
// search. Off: the server's discover?q= (as native). On (device_search, ARXIV_DEVICE_ONLY.md §5.6): DataCite from this
// browser, answered here by a route; nothing reaches the network.
import {readFileSync} from 'node:fs';
import {expect,test,type Page} from '@playwright/test';
import {signInReader} from './device-reader-helpers';
import {fixtureOrigin} from './environment';
import {durableKeys} from './key-capability';
const html=readFileSync(new URL('../../../tests/fixtures/reader-arxiv/source.html',import.meta.url));
const raster=readFileSync(new URL('../../../tests/fixtures/reader-mathpix/figure-exif.jpg',import.meta.url));

async function serveArxiv(page:Page) {
 await page.route('https://arxiv.org/**',async route=>{
  const url=route.request().url();
  if(/\/html\/2604\.01001v7$/.test(url)){await new Promise(r=>setTimeout(r,1200));await route.fulfill({status:200,contentType:'text/html',headers:{'access-control-allow-origin':'*'},body:html});}
  else if(/\/html\/2604\.01001v7\/figure\.jpg$/.test(url))await route.fulfill({status:200,contentType:'image/jpeg',headers:{'access-control-allow-origin':'*'},body:raster});
  else await route.abort();
 });
}
const record=(id:string,version:number,title:string,family:string,given:string,year:number,category:string)=>({id:`10.48550/arxiv.${id}`,type:'dois',attributes:{
 doi:`10.48550/arxiv.${id}`,version:String(version),titles:[{title}],creators:[{name:`${family}, ${given}`,givenName:given,familyName:family}],
 descriptions:[{description:`About ${title.toLowerCase()}.`,descriptionType:'Abstract'}],subjects:[{subject:`Machine Learning (${category})`,subjectScheme:'arXiv'}],
 dates:[{date:`${year}-01-15T00:00:00Z`,dateType:'Submitted',dateInformation:'v1'}],publicationYear:year}});
const noOverflow=async(page:Page)=>expect(await page.evaluate(()=>document.documentElement.scrollWidth)).toBe(page.viewportSize()!.width);

test('field criteria are ANDed in the device request and public paper links route without importing',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 const queries:string[]=[];
 await page.route('https://api.datacite.org/**',async route=>{
  queries.push(new URL(route.request().url()).searchParams.get('query')??'');
  await route.fulfill({status:200,contentType:'application/json',headers:{'access-control-allow-origin':'*'},body:JSON.stringify({data:[],meta:{total:0}})});
 });
 await signInReader(page,request);await request.post(`${fixtureOrigin}/__device-search`,{data:{enabled:true}});
 await page.getByTestId('search').click();await page.getByTestId('search-scope-arxiv').click();
 await page.getByText('Search by fields',{exact:true}).click();
 await page.getByRole('textbox',{name:'title criterion'}).fill('preference optimization');
 await page.getByRole('button',{name:'Add criterion'}).click();
 await page.getByRole('combobox',{name:'Field'}).nth(1).selectOption('author');
 await page.getByRole('textbox',{name:'author criterion'}).fill('Rafailov');
 await page.locator('.advanced-search').getByRole('button',{name:'Search',exact:true}).click();
 await expect(page.getByTestId('discover-empty')).toBeVisible();
 expect(queries).toHaveLength(1);expect(queries[0]).toContain('titles.title:');expect(queries[0]).toContain('creators.name:');expect(queries[0]).toContain(' AND ');
 await page.evaluate(()=>sessionStorage.setItem('gradstep.publicLink','https://app.gradstep.ai/p/arxiv/2305.18290v3'));
 await page.reload();await expect(page).toHaveURL(/\/paper\//);
 await page.evaluate(()=>sessionStorage.setItem('gradstep.publicLink','https://app.gradstep.ai/p/arxiv/2610.99999v2'));
 await page.reload();await expect(page.getByTestId('search')).toHaveValue('2610.99999v2');
 await expect(page.getByTestId('paper-search')).toBeVisible();
 await noOverflow(page);
 await page.screenshot({path:`../../.artifacts/feedback/build70-20261018/search-fields-${test.info().project.name}.png`});
});

test('ML paper search beside the library: the switch, states, order, In library opens the paper, Add shows its percent (server search while device search is off)',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 const datacite:string[]=[];page.on('request',r=>{if(r.url().startsWith('https://api.datacite.org'))datacite.push(r.url());});
 await serveArxiv(page);
 await signInReader(page,request);
 const field=page.getByTestId('search');
 // "/" focuses the search; the switch appears under the field while searching.
 await page.locator('body').press('/');
 await expect(field).toBeFocused();
 await expect(page.getByTestId('search-scope')).toBeVisible();
 await expect(page.getByTestId('search-scope-library')).toHaveAttribute('aria-pressed','true');
 await expect(page.getByTestId('search-scope-arxiv')).toHaveText('ML paper search');
 await page.getByTestId('search-scope-arxiv').click();
 await expect(field).toHaveAttribute('placeholder','Search ML papers');
 await expect(field).toHaveAttribute('aria-label','ML paper search');
 await expect(field).toBeFocused();
 await expect(page.getByTestId('discover-idle')).toContainText('Search ML papers by title');
 await expect(page.getByTestId('discover-idle')).not.toContainText('Find papers');
 await expect(page.getByTestId('library-table')).toHaveCount(0);
 await field.fill('sparse attention');await field.press('Enter');
 const cards=page.getByTestId('paper-search').locator('.feed-card');
 await expect(cards).toHaveCount(2);
 expect((await (await request.get(`${fixtureOrigin}/__search-evidence`)).json()).server).toEqual(['sparse attention']);
 // Newest first by default (native DiscoveryOrder), Relevance keeps the search's order.
 await expect(cards.first()).toContainText('Scaling sparse attention');
 await page.getByTestId('discover-order-relevance').click();
 await expect(cards.first()).toContainText('Direct Preference Optimization');
 await page.getByTestId('discover-order-newest').click();
 await noOverflow(page);
 await page.screenshot({path:`../../.artifacts/web-paper-search/results-${test.info().project.name}.png`});
 // In library opens the paper; back in the library the search is still there, as in the app.
 const dpo=cards.filter({hasText:'Direct Preference Optimization'});
 await dpo.getByTestId('feed-open').click();
 await expect(page).toHaveURL(/\/paper\//);
 await page.getByTestId('back-to-library').click();
 await expect(cards).toHaveCount(2);
 // Add: the Library's spinner until the paper is prepared here (its percent under it), then In library.
 const added=cards.filter({hasText:'Scaling sparse attention'});
 await added.getByRole('button',{name:'+ Add to library'}).click();
 await expect(added.getByTestId('feed-preparing').locator('.spinner')).toBeVisible();
 await expect(added.getByTestId('feed-preparing')).toHaveText(/^\d{1,3}%$/,{timeout:15_000});
 await expect(added.getByTestId('feed-open')).toHaveText('✓ In library',{timeout:15_000});
 // A failed search says so and offers Try again; an empty one suggests other words.
 await field.fill('broken query');await field.press('Enter');
 await expect(page.getByTestId('discover-failed')).toContainText('Couldn’t search');
 await expect(page.getByTestId('discover-failed')).toContainText('ML paper search isn’t available right now. Try again in a moment.');
 await field.fill('nothing at all');await page.getByTestId('discover-failed').getByRole('button',{name:'Try again'}).click();
 await expect(page.getByTestId('discover-empty')).toContainText('No papers found');
 // Escape clears the query, then leaves the search for the library (native Cancel).
 await field.focus();await field.press('Escape');
 await expect(field).toHaveValue('');
 await field.press('Escape');
 await expect(field).toHaveAttribute('placeholder','Search library');
 await expect(page.getByTestId('library-table')).toBeVisible();
 await expect(page.getByTestId('search-scope')).toHaveCount(0);
 expect(datacite).toEqual([]);
});

test('with device search on, the browser asks DataCite itself and the server is not asked',async({page,request})=>{
 test.skip(!await durableKeys(page),'Engine cannot persist X25519 keys.');
 const datacite:string[]=[];
 await page.route('https://api.datacite.org/**',async route=>{
  const url=new URL(route.request().url());datacite.push(url.href);
  const query=url.searchParams.get('query')??'';
  const data=query.startsWith('titles.title:')?[]:[record('2604.01001',7,'Scaling sparse attention to long contexts','Example','Ada',2026,'cs.LG'),
   record('2305.18290',3,'Direct Preference Optimization: Your Language Model is Secretly a Reward Model','Rafailov','Rafael',2023,'cs.LG')];
  await route.fulfill({status:200,contentType:'application/vnd.api+json',headers:{'access-control-allow-origin':'*'},body:JSON.stringify({data,meta:{total:data.length}})});
 });
 await signInReader(page,request);
 await request.post(`${fixtureOrigin}/__device-search`,{data:{enabled:true}});
 const field=page.getByTestId('search');
 await field.click();
 await page.getByTestId('search-scope-arxiv').click();
 await field.fill('sparse attention');await field.press('Enter');
 const cards=page.getByTestId('paper-search').locator('.feed-card');
 await expect(cards).toHaveCount(2);
 await expect(cards.filter({hasText:'Direct Preference Optimization'}).getByTestId('feed-open')).toHaveText('✓ In library');
 expect(datacite.length).toBeGreaterThan(0);
 for(const url of datacite){expect(new URL(url).searchParams.get('mailto')).toBe('hello@gradstep.ai');expect(new URL(url).searchParams.get('provider-id')).toBe('arxiv');}
 expect((await (await request.get(`${fixtureOrigin}/__search-evidence`)).json()).server).toEqual([]);
 await noOverflow(page);
 await page.screenshot({path:`../../.artifacts/web-paper-search/datacite-${test.info().project.name}.png`});
});
