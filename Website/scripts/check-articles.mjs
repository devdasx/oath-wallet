import assert from 'node:assert/strict';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {chromium} from 'playwright';
const base=(process.argv[2]||'http://127.0.0.1:8793').replace(/\/$/,'');
const output=new URL('../../Reports/oath-article-migration-2026-09-23/'+(base.includes('127.')?'local':'live')+'/',import.meta.url);await mkdir(output,{recursive:true});
const manifest=JSON.parse(await readFile(new URL('../published-manifest.json',output)));
const media=JSON.parse(await readFile(new URL('../media-manifest.json',output)));
const report={base,pages:[],media:0,links:0,browser:[],errors:[]};const allLinks=new Set();
async function workers(queue,fn){await Promise.all(Array.from({length:6},async()=>{while(queue.length)await fn(queue.shift())}));}
await workers([...manifest.pages],async a=>{const r=await fetch(base+a.path);assert.equal(r.status,200,a.path);const text=await r.text();assert.ok(text.includes('<h1>'+a.title.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#x27;')+'</h1>'),a.path+' title');assert.equal((text.match(/<img /g)||[]).length,a.image_count+6,a.path+' images preserved');for(const m of text.matchAll(/(?:href|src|poster)="(\/[^"#?]*)/g))allLinks.add(m[1]);report.pages.push(a.path);});
await workers([...media],async a=>{const r=await fetch(base+a.path);assert.equal(r.status,200,a.path);assert.equal((await r.arrayBuffer()).byteLength,a.bytes,a.path);report.media++});
await workers([...allLinks],async p=>{const r=await fetch(base+p,{method:'HEAD'});assert.equal(r.status,200,p);report.links++});
const browser=await chromium.launch({channel:'chrome',headless:true});
try{
 for(const width of [390,1440]){
  const page=await browser.newPage({viewport:{width,height:1000}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
  for(const route of ['/articles',manifest.pages[0].path,manifest.pages.find(p=>p.locale==='ar').path]){
   await page.goto(base+route,{waitUntil:'networkidle'});
   if(route==='/articles'){
    await page.getByPlaceholder('Search articles').waitFor();
    await page.getByPlaceholder('Search articles').fill('dice');
    await page.getByRole('link',{name:/Make Randomness Physical/}).waitFor();
    await page.getByPlaceholder('Search articles').fill('zzznomatch');
    await page.getByText('No articles match that.',{exact:true}).waitFor();
    await page.getByPlaceholder('Search articles').fill('');
    await page.getByRole('button',{name:/Security/}).click();
    assert.equal(await page.locator('a[href^="/articles/"]:visible').count(),12);
    await page.getByRole('button',{name:/^All/}).click();
    assert.equal(await page.locator('a[href^="/articles/"]:visible').count(),24);
   } else {
    if(route.startsWith('/ar/')){assert.equal(await page.locator('html').getAttribute('dir'),'rtl');await page.locator('.languages summary').click();assert.equal(await page.locator('.languages a').count(),16);await page.locator('.languages summary').click();}
    await page.locator('.toc summary').click();await page.locator('.toc a').first().click();assert.ok(new URL(page.url()).hash.startsWith('#section-'));
   }
   await page.evaluate(async()=>{for(let y=0;y<document.body.scrollHeight;y+=innerHeight){scrollTo({top:y,behavior:'instant'});await new Promise(r=>setTimeout(r,70))}});
   await page.waitForFunction(()=>[...document.images].filter(i=>i.getClientRects().length).every(i=>i.complete&&i.naturalWidth>0));
   assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),route+' overflow');
   await page.evaluate(()=>scrollTo({top:0,behavior:'instant'}));await page.waitForTimeout(500);
   const screenshot=width+'-'+(route==='/articles'?'index':route.startsWith('/ar/')?'arabic':'article')+'.png';await page.screenshot({path:fileURLToPath(new URL(screenshot,output))});
   report.browser.push({width,route,screenshot});console.log('PASS',width,route);
  }
  assert.deepEqual(errors,[]);await page.close();
 }
}finally{await browser.close();await writeFile(new URL('checks.json',output),JSON.stringify(report,null,2))}
console.log(JSON.stringify({pages:report.pages.length,media:report.media,links:report.links,browser:report.browser.length}));
