import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {buildSiteChrome} from '../scripts/build-help-chrome.mjs';
import published from '../public/oath-data.json' with {type:'json'};
import catalog from '../content/networks.json' with {type:'json'};
import {handleHelp} from '../src/help/index.js';
const root=new URL('../public/',import.meta.url);
async function files(dir){return (await Promise.all((await readdir(dir,{withFileTypes:true})).map(e=>e.isDirectory()?files(new URL(e.name+'/',dir)):[new URL(e.name,dir)]))).flat();}
test('all marketing and editorial pages use the canonical header and complete network footer',async()=>{
 const chrome=await buildSiteChrome();const light=await buildSiteChrome({light:true});let checked=0;
 assert.equal(await readFile(new URL('site-chrome.css',root),'utf8'),chrome.css);
 for(const file of await files(root)){
  if(!file.pathname.endsWith('.html')||file.pathname.endsWith('.dc.html'))continue;
  const html=await readFile(file,'utf8');
  if(!html.includes('oath-shared-header:start')&&!html.includes('id="oath-server-content"'))continue;
  const expected=file.pathname.endsWith("/news/index.html")?light:chrome;
  assert.ok(html.includes(expected.header),file.pathname);
  assert.ok(html.includes(expected.footer),file.pathname);
  assert.equal((html.match(/<header\b/g)||[]).length,1,file.pathname);
  assert.equal((html.match(/<footer\b/g)||[]).length,1,file.pathname);
  assert.match(html,/src="\/site-chrome.js" defer/);assert.match(html,/href="\/(?:help\/)?site-chrome.css"/);
  assert.doesNotMatch(html,/<header class="site-header"|<footer class="site-footer"/);
  checked++;
 }
 assert.equal(checked,86+published.articles.filter(a=>a.github_editorial).length,`checked ${checked} current pages`);
 for(const n of catalog.networks){assert.ok(chrome.footer.includes(`href="https://oathwallet.org/networks/${n.slug}"`));assert.ok(chrome.footer.includes(`src="${n.icon}"`));}
 assert.equal((chrome.footer.match(/href="https:\/\/oathwallet.org\/networks\//g)||[]).length,42);
});
test('Help Center serves the shared controller and every footer logo without relaxing its policy',async()=>{
 const env={ASSETS:{fetch:async req=>new Response(new URL(req.url).pathname)}};
 for(const path of ['/site-chrome.js','/assets/fonts/oath-fonts.css',...catalog.networks.map(n=>n.icon)]){
  const response=await handleHelp(new Request('https://help.oathwallet.org'+path),env);assert.equal(response.status,200,path);assert.equal(await response.text(),path);
 }
 const page=await handleHelp(new Request('https://help.oathwallet.org/'),env);
 assert.match(await page.text(),/src="\/site-chrome.js" defer/);
 assert.doesNotMatch(page.headers.get('Content-Security-Policy'),/unsafe-inline|unsafe-eval/);
});

test('special public landing pages keep their existing action controls',async()=>{
 const notes=await readFile(new URL('news/index.html',root),'utf8');
 assert.match(notes,/data-newsletter-open/);assert.match(notes,/href="\/admin"/);
 const ousd=await readFile(new URL('ousd/index.html',root),'utf8');
 for(const id of ['connect','exchange-form','review','sign'])assert.equal((ousd.match(new RegExp(`id="${id}"`,'g'))||[]).length,1);
 assert.match(ousd,/<div class="nav ousd-nav">/);
});
