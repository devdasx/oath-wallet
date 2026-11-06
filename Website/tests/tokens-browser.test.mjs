import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdir} from 'node:fs/promises';
import {chromium} from 'playwright';
const base=process.env.OATH_TOKEN_TEST_ORIGIN||'http://127.0.0.1:8794';
const output=new URL('../Reports/token-catalog/',import.meta.url);
test('catalog works at mobile and desktop sizes, with keyboard and without JavaScript',async()=>{
 await mkdir(output,{recursive:true});
 const browser=await chromium.launch({channel:'chrome',headless:true});
 try{
  for(const width of [320,390,1024,1440]){
   const context=await browser.newContext({viewport:{width,height:950}});
   const page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));page.on('response',r=>{if(r.status()>=400&&!r.url().includes('/_events'))errors.push(r.status()+' '+r.url());});
   for(const route of ['/tokens','/tokens/usdt','/tokens/usdt/tron','/tokens/usdc/base','/tokens/usdc/solana','/networks/base/tokens','/networks/base']){
    const response=await page.goto(base+route);assert.equal(response.status(),200,route);
    await page.evaluate(()=>document.fonts.ready);
    assert.equal(await page.locator('h1').count(),1);
    if(!await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1)){console.log(await page.locator('body *').evaluateAll(nodes=>nodes.filter(n=>n.getBoundingClientRect().right>innerWidth+1).slice(0,10).map(n=>({tag:n.tagName,cls:n.className,width:n.getBoundingClientRect().width,text:n.textContent.slice(0,45)}))));await page.screenshot({path:new URL('overflow.png',output).pathname});}
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),`${width} ${route} overflow`);
    assert.ok(await page.locator('main img').evaluateAll(imgs=>imgs.every(i=>i.complete&&i.naturalWidth>0)),`${width} ${route} images`);
    if(route==='/tokens/usdt/tron'||route==='/tokens')await page.screenshot({path:new URL(`${width}-${route.replaceAll('/','-')}.png`,output).pathname,fullPage:false});
   }
   await page.goto(base+'/tokens');
   await page.keyboard.press('Tab');assert.equal(await page.locator(':focus').textContent(),'Skip to content');
   await page.keyboard.press('Enter');assert.equal(await page.locator(':focus').getAttribute('id'),'main');
   await page.getByLabel('Find a token').fill('USDC');await page.getByLabel('Network',{exact:true}).selectOption('base');
   await page.getByRole('button',{name:'Search',exact:true}).click();
   assert.ok(page.url().includes('q=USDC'));
   assert.ok(await page.locator('.token-row').count()>0);
   assert.ok(await page.locator('.token-networks').evaluateAll(nodes=>nodes.every(n=>n.textContent.trim()==='Base')));
   if(width<1024){await page.getByRole('button',{name:'Open menu'}).click();assert.equal(await page.locator('#oath-site-menu').getAttribute('aria-hidden'),'false');await page.keyboard.press('Escape');assert.equal(await page.locator('#oath-site-menu').getAttribute('aria-hidden'),'true');}
   assert.deepEqual(errors,[]);await context.close();
  }
  const context=await browser.newContext({javaScriptEnabled:false,viewport:{width:390,height:844}});const page=await context.newPage();
  await page.goto(base+'/tokens');assert.equal(await page.locator('.token-row').count(),50);
  await page.getByLabel('Find a token').fill('USDT');await page.getByLabel('Network',{exact:true}).selectOption('tron');await page.getByRole('button',{name:'Search',exact:true}).click();
  await page.locator('.token-row').filter({hasText:'Tether'}).first().click();assert.ok(page.url().endsWith('/tokens/usdt/tron'));assert.ok((await page.locator('.token-identity').textContent()).includes('not your receiving address'));
  await context.close();
 }finally{await browser.close();}
});
