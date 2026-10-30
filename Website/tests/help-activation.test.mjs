import test from 'node:test';
import assert from 'node:assert/strict';
import data from '../src/help/content.json' with {type:'json'};
import patch from '../content/help/account-activation-2026-10-21.json' with {type:'json'};
import baseline from './fixtures/help-before-activation.json' with {type:'json'};
import {article, searchResults, HELP_SOCIAL_IMAGE} from '../src/help/render.js';
import {validateContent} from '../src/help/index.js';
test('activation guide covers every checked chain and preserves existing publication identities',()=>{
 validateContent(data.categories,data.articles);
 assert.deepEqual(data.categories,baseline.categories);
 for(const original of baseline.articles) {
  const current=data.articles.find(a=>a.slug===original.slug);assert.ok(current,original.slug);
  for(const key of ['slug','category_id','published_at']) assert.equal(current[key],original[key]);
 }
 const a=data.articles.find(a=>a.slug===patch.slug);
 // Release labels advance separately; the chain instructions retain their reviewed text.
 for(const key of ['title','summary','route','steps','body','note','related','screenshot']) assert.deepEqual(a[key],patch[key]);
 assert.equal(a.screenshot,null);
 for(const chain of ['Stellar','XRP Ledger','Solana','TRON','NEAR','Gram']) {
  assert.ok(a.body.some(p=>p.startsWith('## '+chain)),chain);
  assert.ok(searchResults(data,chain+' activation').includes('/articles/'+a.slug),chain);
 }
 const html=article(data,a);
 assert.match(html,/Oath does not charge or collect an activation fee/);
 assert.match(html,/Network transaction fees/);
 assert.match(html,/<h3>Stellar/);
 assert.ok(html.includes(HELP_SOCIAL_IMAGE));
 assert.equal((html.match(/<p>Source: <a /g)||[]).length,10);
 assert.ok(!html.includes('## '));
});
test('guide formatting escapes malicious headings and never links unsafe source URLs',()=>{
 const html=article(data,{...patch,body:['## <img src=x onerror=alert(1)>','Source: javascript:alert(1)','Source: https://solana.com.evil.invalid/test','Source: https://solana.com@evil.invalid/test','Source: https://solana.com/docs/"onclick="bad','<script>alert(1)</script>']});
 assert.ok(!html.includes('<img src=x'));assert.ok(!html.includes('<script>alert(1)'));
 assert.ok(!html.includes('href="javascript:'));assert.ok(!html.includes('href="https://solana.com.evil'));
 assert.ok(!html.includes('href="https://solana.com@'));
 assert.ok(html.includes('&lt;script&gt;'));
 assert.ok(!html.includes('"onclick="'));
});
