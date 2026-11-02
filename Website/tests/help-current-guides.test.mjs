import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import data from '../src/help/content.json' with {type:'json'};
import walkthroughs from '../src/help/walkthroughs.json' with {type:'json'};
import {article,searchResults} from '../src/help/render.js';
const current=['send-availability','send-max-and-fees','send-tags-and-memos','bitcoin-transfer-options','connect-dapp','dapp-swap','dapp-transaction-data','dapp-signatures','walletconnect-solana','walletconnect-thorchain','bulk-revoke-access','permission-coverage','check-contract-access','last-wallet-reset','upgrade-existing-wallets','token-prices-and-logos','asset-filters'];
test('every current guide has usable steps, source references and captioned actual-screen images',async()=>{
 const coverage=JSON.parse(await readFile(new URL('./fixtures/help-source-coverage.json',import.meta.url)));
 assert.equal(coverage.length,130);
 assert.equal(Object.keys(walkthroughs).length,130);
 for(const a of data.articles.filter(a=>coverage.some(c=>c.slug===a.slug))){
  assert.ok(a.steps.length>=4,a.slug);assert.ok(a.body.length>=2,a.slug);
  assert.equal(a.app_version,'Oath 5.0.0');
  assert.equal(a.screenshot_version,'Oath 4.0.3');
  assert.ok(coverage.find(c=>c.slug===a.slug)?.sources.length,a.slug);
  const items=walkthroughs[a.slug];assert.ok(items?.length,a.slug);
  assert.equal(a.screenshot,items[0].image,a.slug);
  for(const x of items){
   assert.match(x.image,/^guide-[a-z0-9-]+$/);assert.ok(x.caption.length>40,x.image);assert.ok(x.alt.length>10,x.image);
   if(x.step)assert.ok(x.step>=1&&x.step<=a.steps.length,a.slug);
  }
  const html=article(data,a);
  assert.match(html,/Real app screens with illustrative demo data/);
  assert.match(html,/Never send funds to an example address/);
  for(const x of items)assert.ok(html.includes('/help/assets/'+x.image+'.webp'));
 }
 for(const name of new Set(Object.values(walkthroughs).flat().map(x=>x.image))){
  const raw=await readFile(new URL('../public/help/assets/'+name+'.webp',import.meta.url));assert.equal(raw.subarray(0,4).toString(),'RIFF');assert.equal(raw.subarray(8,12).toString(),'WEBP');assert.ok(raw.length>1000);
 }
});
test('new actions are findable and obsolete availability instructions are absent',()=>{
 for(const slug of current){const a=data.articles.find(x=>x.slug===slug);assert.ok(a);assert.ok(searchResults(data,a.title).includes('/articles/'+slug));}
 const text=JSON.stringify(data.articles);
 assert.doesNotMatch(text,/Send is not available|Send placeholder|permissions.*coming soon/i);
 const appIcon=data.articles.find(a=>a.slug==='app-icon');assert.match(JSON.stringify(appIcon),/Signal Blue/);
 assert.ok(data.categories.some(c=>c.id==='dapps'));
 assert.equal(data.categories.find(c=>c.id==='receive').title,'Send & receive');
});
test('guides distinguish review, signature, submission, confirmation and incomplete discovery',()=>{
 const get=s=>JSON.stringify(data.articles.find(a=>a.slug===s));
 assert.match(get('bulk-revoke-access'),/not a single atomic transaction/);
 assert.match(get('bulk-revoke-access'),/iOS can suspend/);
 assert.match(get('dapp-disconnect'),/does not revoke|does not remove/i);
 assert.match(get('permission-coverage'),/off-chain/i);
 assert.match(get('walletconnect-solana'),/Devnet.*Testnet/);
 assert.match(get('walletconnect-thorchain'),/destination/i);
 assert.match(get('restore-icloud'),/backup password/);
 assert.match(get('last-wallet-reset'),/Both confirmations.*before deletion/);
 assert.match(get('token-prices-and-logos'),/not a confirmed price of zero/);
});
test('article text remains escaped and galleries use full-size non-cropped images',()=>{
 const a={...data.articles[0],title:'<script>bad</script>',steps:['<img src=x onerror=bad()>'],body:['<script>bad</script>']};
 const html=article(data,a);assert.ok(!html.includes('<script>bad</script>'));assert.match(html,/&lt;img/);assert.match(html,/width="1320" height="2868"/);assert.match(html,/id="step-1"/);
});
