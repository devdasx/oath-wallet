import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile,mkdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {chromium} from 'playwright';
import {handleHelp} from '../src/help/index.js';

test('shared help chrome matches the main header and works at phone, tablet and desktop widths',async()=>{
  const originalFetch=globalThis.fetch;
  globalThis.fetch=async()=>{throw Error('Use bundled help content for deterministic browser tests');};
  const assets={async fetch(request){
    try{
      const path=decodeURIComponent(new URL(request.url).pathname);
      if(path.includes('..'))return new Response('Not found',{status:404});
      const body=await readFile(new URL('../public'+path,import.meta.url));
      const type=path.endsWith('.js')?'application/javascript':path.endsWith('.css')?'text/css':path.endsWith('.svg')?'image/svg+xml':path.endsWith('.webp')?'image/webp':'text/html';
      return new Response(body,{headers:{'Content-Type':type}});
    }catch{return new Response('Not found',{status:404});}
  }};
  const server=createServer(async(req,res)=>{
    try{
      const url=new URL(req.url,'https://help.oathwallet.org');
      const request=new Request(url);
      const reference=/\.dc\.html$|^\/(?:index.html|support.js|oath-icons.js|assets\/)/.test(decodeURIComponent(url.pathname));
      const response=reference?await assets.fetch(request):await handleHelp(request,{ASSETS:assets});
      res.writeHead(response.status,Object.fromEntries(response.headers));res.end(Buffer.from(await response.arrayBuffer()));
    }catch(error){res.writeHead(500);res.end(error.message);}
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const origin=`http://127.0.0.1:${server.address().port}`;
  const browser=await chromium.launch({channel:'chrome',headless:true});
  const report=new URL('../Reports/help-chrome-2026-10-12/',import.meta.url);
  await mkdir(report,{recursive:true});
  try{
    for(const width of [390,820,1280,320]){
      const context=await browser.newContext({viewport:{width,height:900}});
      try{
        const page=await context.newPage();const errors=[];
        page.on('pageerror',error=>errors.push(error.message));
        page.on('console',message=>{if(message.text().includes('Content Security Policy'))errors.push(message.text());});
        await page.goto(origin+'/');
        await page.evaluate(()=>document.fonts.ready);
        assert.equal(await page.locator('header img').evaluate(img=>img.complete&&img.naturalWidth>0),true);
        assert.equal(await page.locator('footer img').evaluate(img=>img.complete&&img.naturalWidth>0),true);
        assert.equal(await page.locator('footer').evaluate(el=>getComputedStyle(el).backgroundColor),'rgb(255, 255, 255)');
        assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,`horizontal overflow at ${width}`);
        const bar=page.locator('header > div');
        const metrics=await bar.evaluate(el=>{const s=getComputedStyle(el),r=el.getBoundingClientRect();return {width:r.width,height:r.height,left:r.left,top:r.top,radius:s.borderRadius,bg:s.backgroundColor,padding:s.padding};});
        const toggle=page.getByRole('button',{name:'Open menu'});
        if(width<1024){
          await toggle.click();
          assert.equal(await page.locator('#oath-site-menu').getAttribute('aria-hidden'),'false');
          assert.equal(await page.getByRole('dialog',{name:'Navigation'}).getByRole('button',{name:'Close menu'}).count(),1);
          assert.equal(await page.locator('main').evaluate(el=>el.inert),true);
          assert.equal(await page.evaluate(()=>document.documentElement.style.overflow),'hidden');
          await page.keyboard.press('Shift+Tab');
          assert.equal(await page.evaluate(()=>document.activeElement?.getAttribute('data-oath-toggle')!==null),true);
          await page.keyboard.press('Escape');
          assert.equal(await page.locator('#oath-site-menu').evaluate(el=>el.inert),true);
          assert.equal(await page.locator('main').evaluate(el=>el.inert),false);
          assert.equal(await page.evaluate(()=>document.documentElement.style.overflow),'');
          await toggle.click();
          await page.locator('#oath-site-menu').evaluate(async el=>{
            await Promise.all(el.getAnimations({subtree:true}).map(animation=>animation.finished.catch(()=>{})));
          });
          if(width===390)await page.screenshot({path:fileURLToPath(new URL('mobile-menu.png',report))});
          await page.setViewportSize({width:1280,height:900});
          await page.waitForFunction(()=>document.querySelector('#oath-site-menu').getAttribute('aria-hidden')==='true');
          assert.equal(await page.locator('#oath-site-menu').getAttribute('aria-hidden'),'true');
          await page.setViewportSize({width,height:900});
        }else assert.equal(await toggle.count(),0);
        await page.locator('#help-search').fill('solana');
        await page.getByRole('button',{name:'Search',exact:true}).click();
        await page.waitForURL('**/search?q=solana');
        await page.locator('.article-row').first().click();
        await page.waitForURL('**/articles/**');
        assert.equal(await page.locator('.oath-site-header header').count(),1);
        assert.equal(await page.locator('footer').count(),1);
        await page.goto(origin+'/');
        if(width===390||width===1280){
          await page.screenshot({path:fileURLToPath(new URL(`help-${width}.png`,report)),fullPage:true});
        }
        // Compare actual geometry with the unchanged main website component.
        const reference=await context.newPage();
        await reference.goto(origin+'/index.html');
        await reference.locator('header > div').waitFor();
        await reference.evaluate(()=>document.fonts.ready);
        const referenceMetrics=await reference.locator('header > div').evaluate(el=>{const s=getComputedStyle(el),r=el.getBoundingClientRect();return {width:r.width,height:r.height,left:r.left,top:r.top,radius:s.borderRadius,bg:s.backgroundColor,padding:s.padding};});
        assert.equal(metrics.bg,'rgba(255, 255, 255, 0.88)');
        assert.deepEqual({...metrics,bg:referenceMetrics.bg},referenceMetrics,`header layout differs from main site at ${width}px`);
        assert.deepEqual(errors,[],`browser errors at ${width}px`);
      }finally{await context.close();}
    }
  }finally{
    await browser.close();await new Promise(resolve=>server.close(resolve));globalThis.fetch=originalFetch;
  }
});
