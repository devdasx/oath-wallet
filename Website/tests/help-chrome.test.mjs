import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {buildHelpChrome} from '../scripts/build-help-chrome.mjs';
import {siteHeader,siteFooter} from '../src/help/site-chrome.js';
import {home,collection,article,searchResults,notFound} from '../src/help/render.js';
import {handleHelp} from '../src/help/index.js';
import data from '../src/help/content.json' with {type:'json'};

test('Help Center chrome is generated from the current main-site components',async()=>{
  const generated=await buildHelpChrome();
  assert.equal(await readFile(new URL('../src/help/site-chrome.js',import.meta.url),'utf8'),generated.module);
  assert.equal(await readFile(new URL('../public/help/site-chrome.css',import.meta.url),'utf8'),generated.css);
  assert.match(siteHeader,/\/assets\/brand\/oath-mark-light.svg/);
  assert.match(siteFooter,/\/assets\/brand\/oath-mark-light.svg/);
  assert.match(generated.css,/background:#FFFFFF;color:#0A0A0B/);
  assert.match(generated.css,/background:rgba\(255,255,255,\.88\)/);
  assert.match(generated.css,/background:rgba\(248,249,252,\.96\)/);
  assert.doesNotMatch(siteHeader+siteFooter,/style=|onClick=|{{|sc-for|dc-import/);
  assert.match(siteHeader,/aria-controls="oath-site-menu"/);
  assert.match(siteHeader,/inert aria-hidden="true"/);
  for(const html of [home(data),collection(data,data.categories[0]),article(data,data.articles[0]),searchResults(data,'backup'),notFound()]){
    assert.ok(html.includes(siteHeader));assert.ok(html.includes(siteFooter));
    assert.equal((html.match(/<footer\b/g)||[]).length,1);
    assert.match(html,/\/help\/site-chrome.css/);
    assert.doesNotMatch(html,/class="brand"|class="header"/);
  }
});
test('shared navigation points to the correct subdomain without hijacking help article paths',()=>{
  for(const href of ['https://oathwallet.org/','https://oathwallet.org/features','https://articles.oathwallet.org/','https://help.oathwallet.org/']){
    assert.ok(siteHeader.includes(`href="${href}"`));
  }
  for(const href of ['https://oathwallet.org/privacy','https://oathwallet.org/terms','mailto:care@oathwallet.org'])assert.ok(siteFooter.includes(`href="${href}"`));
  assert.match(home(data),/href="\/articles\/create-wallet"/);
});
test('brand and chrome assets are served on the Help Center without weakening its content policy',async()=>{
  const env={ASSETS:{fetch:async request=>new Response(new URL(request.url).pathname)}};
  for(const path of ['/assets/brand/oath-mark-dark.svg','/assets/brand/oath-mark-light.svg','/help/site-chrome.css']){
    const response=await handleHelp(new Request('https://help.oathwallet.org'+path),env);
    assert.equal(response.status,200);assert.equal(await response.text(),path);
  }
  const source=await readFile(new URL('../src/help/index.js',import.meta.url),'utf8');
  assert.match(source,/script-src 'self'; style-src 'self' https:\/\/fonts.googleapis.com/);
  assert.doesNotMatch(source,/unsafe-inline|unsafe-eval/);
});
