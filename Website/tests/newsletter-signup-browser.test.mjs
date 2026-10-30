import assert from 'node:assert/strict';
import test from 'node:test';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { chromium } from 'playwright';

test('email and Join complete signup without a checkbox or confirmation step, on desktop and mobile', async () => {
 const server=createServer(async(req,res)=>{
  try{
   const path=new URL(req.url,'http://localhost').pathname;
   if(path.includes('..')){res.writeHead(404);res.end();return;}
   const body=await readFile(new URL('../public'+path,import.meta.url));
   const type=path.endsWith('.js')?'application/javascript':path.endsWith('.css')?'text/css':path.endsWith('.svg')?'image/svg+xml':'text/html';
   res.writeHead(200,{'Content-Type':type});res.end(body);
  }catch{res.writeHead(404);res.end();}
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const browser=await chromium.launch({channel:'chrome',headless:true});
 try{
  for(const viewport of [{width:1280,height:900},{width:390,height:844}]){
   const context=await browser.newContext({viewport});
   try{
    const page=await context.newPage();const sent=[];
    await page.route('**/_newsletter/signup',async route=>{
     sent.push(route.request().postDataJSON());
     await route.fulfill({json:{ok:true,subscribed:true,message:'You’re subscribed to Oath Notes. No email confirmation is needed — you’re all set.'}});
    });
    await page.goto(`http://127.0.0.1:${server.address().port}/news/index.html`);
    await page.locator('[data-newsletter-open]').click();
    assert.equal(await page.locator('input[name=consent]').count(),0);
    assert.match(await page.locator('.on-consent').innerText(),/By selecting Join Oath Notes/);
    await page.locator('#on-email').fill('new-subscriber@example.invalid');
    await page.locator('.on-form button[type=submit]').click();
    await page.locator('.on-success').waitFor();
    assert.equal(sent.length,1);
    assert.equal(sent[0].consent,true);
    assert.deepEqual(sent[0].topics,['oath','markets','security','guides']);
    assert.match(await page.locator('.on-success-message').innerText(),/No email confirmation is needed/);
    assert.equal(await page.locator('dialog input').count(),0);
    assert.equal(await page.locator('dialog').evaluate(el=>el.scrollWidth<=el.clientWidth+1),true);
    await page.locator('.on-success button').click();
    assert.equal(await page.locator('dialog').evaluate(el=>el.open),false);
    assert.equal(await page.evaluate(()=>localStorage.getItem('oath_newsletter_seen_v1')),'1');
   }finally{await context.close();}
  }
 }finally{
  await browser.close();
  await new Promise(resolve=>server.close(resolve));
 }
});
