import { chromium } from '/Users/benbowlwes/science-reader/apps/web/node_modules/playwright/index.mjs';
const b = await chromium.launch({ args: ['--enable-unsafe-webgpu', '--enable-features=Vulkan', '--use-angle=metal'] });
const p = await b.newPage();
p.on('console', m => console.error('console:', m.text()));
await p.goto('http://127.0.0.1:8765/index.html');
await p.waitForFunction(() => window.result, null, { timeout: 600000 });
console.log(JSON.stringify(await p.evaluate(() => window.result), null, 1));
console.log('UA', await p.evaluate(() => navigator.userAgent));
await b.close();
