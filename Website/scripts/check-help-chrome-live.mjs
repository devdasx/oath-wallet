import assert from 'node:assert/strict';
import {mkdir,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {chromium} from 'playwright';

const origin='https://help.oathwallet.org';
const report=new URL('../Reports/help-chrome-2026-10-12/',import.meta.url);
await mkdir(report,{recursive:true});
const resources=['/','/articles/create-wallet','/collections/wallets','/search?q=solana','/help/help.js?v=20261012-shell2','/help/help.css?v=20261012-shell2','/help/site-chrome.css?v=20261012-shell2','/assets/brand/oath-mark-light.svg'];
const checks=await Promise.all(resources.map(async path=>{
  const response=await fetch(origin+path);
  const body=await response.text();assert.equal(response.status,200,path);
  if(response.headers.get('content-type')?.includes('text/html')){
    assert.ok(body.includes('oath-site-header'),path);assert.ok(body.includes('oath-site-footer'),path);
    assert.ok(body.includes('20261012-shell2'),path);
  }
  return {path,status:response.status,source:response.headers.get('x-oath-content')};
}));
const browser=await chromium.launch({channel:'chrome',headless:true});
const layouts=[];
try{
  for(const width of [390,1280]){
    const context=await browser.newContext({viewport:{width,height:900}});
    try{
      const page=await context.newPage(),errors=[],platformWarnings=[];
      page.on('pageerror',error=>errors.push(error.message));
      page.on('console',message=>{
        const text=message.text();
        if(!text.includes('Content Security Policy'))return;
        // Cloudflare injects its analytics beacon at the edge; the existing
        // strict Help Center policy blocks it. Record it without allowing new
        // third-party scripts merely to remove an unrelated console warning.
        if(text.includes("Loading the script 'https://static.cloudflareinsights.com/beacon.min.js/")&&text.includes('has been blocked'))platformWarnings.push(text);
        else errors.push(text);
      });
      await page.goto(origin+'/');await page.evaluate(()=>document.fonts.ready);
      assert.equal(await page.locator('header > div').evaluate(el=>getComputedStyle(el).backgroundColor),'rgba(255, 255, 255, 0.88)');
      assert.equal(await page.locator('footer').evaluate(el=>getComputedStyle(el).backgroundColor),'rgb(255, 255, 255)');
      assert.equal(await page.locator('header img').evaluate(img=>img.complete&&img.naturalWidth>0),true);
      assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
      await page.screenshot({path:fileURLToPath(new URL(`live-${width}.png`,report))});
      await page.locator('footer').screenshot({path:fileURLToPath(new URL(`live-footer-${width}.png`,report))});
      await page.evaluate(()=>window.scrollTo(0,0));
      if(width<1024){
        await page.getByRole('button',{name:'Open menu'}).click();
        const dialog=page.getByRole('dialog',{name:'Navigation'});
        await dialog.getByRole('button',{name:'Close menu'}).waitFor();
        await dialog.getByRole('link',{name:'02 Features →'}).click();
      }else await page.getByRole('navigation',{name:'Main navigation'}).getByRole('link',{name:'Features',exact:true}).click();
      await page.waitForURL('https://oathwallet.org/features');
      await page.goBack();
      await page.locator('#help-search').fill('solana');
      await page.getByRole('button',{name:'Search',exact:true}).click();
      await page.waitForURL('**/search?q=solana');
      await page.locator('.article-row').first().click();await page.waitForURL('**/articles/**');
      assert.equal(await page.locator('.oath-site-header header').count(),1);
      assert.equal(await page.locator('footer').count(),1);
      assert.deepEqual(errors,[]);
      layouts.push({width,lightHeader:true,lightFooter:true,navigation:true,search:true,article:true,browserErrors:errors,blockedCloudflareAnalyticsWarnings:platformWarnings.length});
    }finally{await context.close();}
  }
}finally{await browser.close();}
await writeFile(new URL('live-verification.json',report),JSON.stringify({checkedAt:new Date().toISOString(),checks,layouts},null,2)+'\n');
console.log(JSON.stringify({resources:checks.length,layouts,passed:true},null,2));
