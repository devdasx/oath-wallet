import {chromium} from 'playwright';
import {mkdir,writeFile} from 'node:fs/promises';
const base=process.env.HELP_CHECK_ORIGIN||'http://127.0.0.1:8898';
const dir='Reports/help-update-2026-10-16';await mkdir(dir,{recursive:true});
const browser=await chromium.launch({channel:'chrome',headless:true});const results=[];let bad=false;
try{
 for(const viewport of [{width:390,height:844},{width:1440,height:1000}]){
  const page=await browser.newPage({viewport,deviceScaleFactor:1});const errors=[];page.on('pageerror',e=>errors.push(e.message));
  for(const path of ['/','/articles/send-availability','/articles/bulk-revoke-access','/articles/import-recovery-phrase','/articles/walletconnect-solana','/articles/restore-icloud','/collections/dapps']){
   await page.goto(base+path,{waitUntil:'networkidle'});
   const result=await page.evaluate(()=>({title:document.title,h1:document.querySelector('h1')?.textContent,overflow:document.documentElement.scrollWidth>innerWidth+1,brokenImages:[...document.images].filter(i=>i.loading!=='lazy'&&(!i.complete||!i.naturalWidth)).map(i=>i.getAttribute('src')),imageCount:document.querySelectorAll('.walkthrough img').length}));
   if(await page.locator('.walkthrough').count())await page.locator('.walkthrough').scrollIntoViewIfNeeded();
   await page.evaluate(async()=>{await Promise.all([...document.querySelectorAll('.walkthrough img')].map(i=>{i.loading='eager';return i.decode().catch(()=>{});}));});
   const images=await page.locator('.walkthrough img').evaluateAll(imgs=>imgs.map(i=>({src:i.getAttribute('src'),width:i.naturalWidth,height:i.naturalHeight,alt:i.alt})));
   const broken=images.filter(i=>!i.width||!i.height||!i.alt);
   if(result.overflow||broken.length||result.brokenImages.length||errors.length)bad=true;
   results.push({viewport,path,...result,broken,errors:[...errors]});
   await page.evaluate(async()=>{document.documentElement.style.scrollBehavior='auto';window.scrollTo({top:0,behavior:'instant'});await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));});
   if(path==='/articles/send-availability'||path==='/articles/bulk-revoke-access')await page.screenshot({path:dir+'/'+(base.includes('localhost')||base.includes('127.0.0.1')?'preview':'live')+'-'+viewport.width+'-'+path.split('/').pop()+'.png',fullPage:true});
  }
  await page.goto(base+'/search?q=Solana%20Devnet',{waitUntil:'networkidle'});
  if(!await page.locator('a[href="/articles/walletconnect-solana"]').count())bad=true;
  await page.close();
 }
}finally{await browser.close();}
await writeFile(dir+'/browser-'+(base.includes('127.0.0.1')?'preview':'live')+'.json',JSON.stringify({base,checkedAt:new Date().toISOString(),passed:!bad,results},null,2));
console.log(`${results.length} desktop/mobile page checks; ${bad?'FAILED':'passed'}`);if(bad)process.exitCode=1;
