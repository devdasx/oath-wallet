import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile, readdir} from 'node:fs/promises';
import {runInNewContext} from 'node:vm';
import worker from '../src/index.js';
import manifest from '../src/tokens-manifest.json' with {type:'json'};
import {renderTransferPreparation, transferURL, transferPath} from '../src/transfer-preparation.js';
const root = new URL('../public/', import.meta.url), origin = 'https://oathwallet.org';
const read = path => readFile(new URL('.'+path, root), 'utf8');
const environment = () => ({ASSETS:{async fetch(request){try {const path = new URL(request.url).pathname; return new Response(await read(path), {headers:{'Content-Type':path.endsWith('.html')?'text/html':'application/json'}});} catch {return new Response(null,{status:404});}}}});
const env = environment();
const get = (path, options) => worker.fetch(new Request(origin+path, options), env);
const coins = {};
for (const shard of await readdir(new URL('.'+manifest.prefix+'/coins/',root))) Object.assign(coins, JSON.parse(await read(manifest.prefix+'/coins/'+shard)));

test('exact-asset preparation works across every released token network', async () => {
  const samples = Object.values(manifest.networks).map(n => coins[n.featured[0].slug].assets.find(a => a.path === n.featured[0].path));
  samples.push(...coins.usdt.assets.filter(a=>a.network==='tron'), ...coins.usdc.assets.filter(a=>['base','solana'].includes(a.network)));
  for (const asset of samples) {
    const r = await get(transferURL(asset)), html = await r.text();
    assert.equal(r.status,200,asset.path);
    assert.equal(r.headers.get('X-Robots-Tag'),'noindex, follow');
    assert.equal(r.headers.get('Cache-Control'),'no-store');
    assert.ok(html.includes(`href="${origin+transferPath}"`));
    assert.ok(html.includes(`value="${asset.path}" data-token="${asset.slug}" selected`),asset.path);
    assert.ok(html.includes(`data-transfer-path="${asset.path}"><p`), 'Selected entry must be visible without JS');
    assert.ok(html.includes('This token identifier is not your receiving address.'));
    const md = await get(transferURL(asset), {headers:{Accept:'text/markdown'}});
    assert.match(md.headers.get('Content-Type'),/text\/markdown/);
    const text = await md.text();
    assert.ok(text.includes(asset.reference));
    assert.ok(text.includes('`'+asset.reference+'`'), 'Public token identifiers use code formatting');
    assert.ok(text.includes(manifest.networks[asset.network].send));
    assert.doesNotMatch(text,/Choose a tokenChoose|Clear selection|checkbox|<select/);
    assert.equal((await get(transferURL(asset),{method:'HEAD'})).status,200);
  }
});

test('same-network variants retain exact references and independent selections', async () => {
  const original=coins.usdc.assets.find(a=>a.network==='base');
  const variant={...original,path:original.path+'-111111111111',reference:'0x1111111111111111111111111111111111111111'};
  const mock=environment(), fetch=mock.ASSETS.fetch;
  mock.ASSETS.fetch=async request=>{
    const response=await fetch(request);
    if(!new URL(request.url).pathname.includes('/coins/'))return response;
    const data=await response.json();if(data.usdc)data.usdc.assets.push(variant);
    return new Response(JSON.stringify(data));
  };
  const response=await worker.fetch(new Request(origin+transferURL(variant)),mock),html=await response.text();
  assert.equal(response.status,200);assert.ok(html.includes(`data-transfer-path="${variant.path}"><p`));
  assert.ok(html.includes(`data-transfer-path="${original.path}" hidden`));
  assert.ok(html.includes(`Base · ${variant.reference}</option>`));
  assert.ok(html.includes(`Base · ${original.reference}</option>`));
});

test('bad selections, canonical aliases and unavailable snapshots fail truthfully', async () => {
  for (const query of ['token=usdc','token=usdc&network=cronos','token=missing-token&network=base','token=usdc&network=base&network=solana','token=constructor&network=base','token=%3Cscript%3E&network=base']) {
    const r=await get(transferPath+'?'+query); assert.equal(r.status,404,query);assert.match(r.headers.get('X-Robots-Tag'),/noindex/);
  }
  const alias=await get(transferPath+'.html?token=usdc&network=base');assert.equal(alias.status,308);assert.equal(alias.headers.get('Location'),origin+transferPath+'?token=usdc&network=base');
  const tracking=await get(transferPath+'?utm_source=example');assert.equal(tracking.status,308);assert.equal(tracking.headers.get('Location'),origin+transferPath);
  const md=await get(transferPath+'.md?token=usdc&network=base');assert.match(md.headers.get('Content-Type'),/text\/markdown/);assert.ok((await md.text()).includes(coins.usdc.assets.find(a=>a.network==='base').reference));
  const unavailable=await worker.fetch(new Request(origin+transferURL(coins.usdc.assets[0])),{ASSETS:{fetch:async()=>new Response(null,{status:503})}});assert.equal(unavailable.status,503);assert.equal(unavailable.headers.get('Retry-After'),'60');
  assert.equal((await get(transferURL(coins.usdc.assets[0]),{method:'POST'})).status,405);
});

test('tool escapes metadata and preserves separate identities without guessing by symbol', () => {
  const asset={...coins.usdc.assets[0],name:'<img src=x onerror=alert(1)>',reference:'"<script>bad</script>',symbol:'USDC&"'};
  const html=renderTransferPreparation([asset],manifest.networks,asset.path);
  assert.doesNotMatch(html,/<img src=x|<script>bad/);assert.match(html,/&lt;script&gt;bad/);assert.match(html,/USDC&amp;&quot;/);
  assert.throws(()=>renderTransferPreparation([asset],manifest.networks,'/tokens/usdc/unknown'));
});

test('changing selection resets review, constrains network choices and announces results', async () => {
  const event = object => Object.assign(object, {events:{},addEventListener(name,fn){this.events[name]=fn;}});
  const option=(value,token)=>({value,dataset:{token},disabled:false,hidden:false});
  const network=event({value:'/tokens/usdc/base',options:[option('',''),option('/tokens/usdc/base','usdc'),option('/tokens/usdc/solana','usdc'),option('/tokens/usdt/tron','usdt')]});
  const token=event({value:'usdc',focus(){this.focused=true;}}), reset=event({}), controls={hidden:true}, count={}, status={};
  const cards=network.options.slice(1).map(o=>({dataset:{transferPath:o.value,transferToken:o.dataset.token},hidden:false}));
  const checks=[event({checked:false}),event({checked:false}),event({checked:false})];
  const review={hidden:true,querySelectorAll:()=>checks};
  const map={'.transfer-controls':controls,'#transfer-token':token,'#transfer-network':network,'[data-transfer-count]':count,'.transfer-review':review,'[data-transfer-review-status]':status,'[data-transfer-reset]':reset};
  const tool={querySelector:q=>map[q],querySelectorAll:()=>cards,classList:{toggle(){}}};
  let location='';
  runInNewContext(await read('/transfer-preparation.js'),{document:{querySelector:()=>tool},URL,window:{location:{href:origin+transferPath},history:{replaceState(_s,_t,url){location=url;}}}});
  assert.equal(controls.hidden,false);assert.equal(review.hidden,false);assert.equal(cards.filter(c=>!c.hidden).length,1);
  checks.forEach(c=>{c.checked=true;c.events.change();});assert.match(status.textContent,/checklist is complete/);
  network.value='/tokens/usdc/solana';network.events.change();assert.ok(checks.every(c=>!c.checked));
  assert.equal(location,transferPath+'?token=usdc&network=solana#prepare-transfer');
  token.value='usdt';token.events.change();assert.equal(network.value,'');assert.equal(review.hidden,true);assert.equal(network.options[1].disabled,true);assert.equal(network.options[3].disabled,false);
  network.value='/tokens/usdt/tron';network.events.change();assert.equal(review.hidden,false);assert.match(count.textContent,/1 exact token/);
  reset.events.click();assert.equal(network.disabled,true);assert.equal(cards.filter(c=>!c.hidden).length,3);assert.equal(token.focused,true);assert.equal(review.hidden,true);
  assert.equal(location,transferPath+'#prepare-transfer');
});

test('current copy, structured metadata and homepage discovery agree with the published release', async () => {
  const data=JSON.parse(await read('/oath-data.json')),release=JSON.parse(await read('/release-status.json'));
  for(const path of ['/index.html','/index.md','/features.html','/features.md']) {
    const text=await read(path);assert.doesNotMatch(text,/4\.1\.14|5\.0\.0|use physical entropy|addEntropy|Roll 6 dice/,path);
    if(path.includes('index'))assert.ok(text.includes('networks/choose-token-network#prepare-transfer'));
  }
  assert.equal(data.facts.app_version,release.version);
  for(const page of ['index','features']){
    const html=await read('/'+page+'.html');const graph=JSON.parse(html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1])['@graph'];
    assert.equal(graph.find(n=>n['@type']==='MobileApplication').softwareVersion,release.version);
    if(page==='features')assert.deepEqual(graph.find(n=>n['@type']==='ItemList').itemListElement.map(n=>n.description),data.features.map(f=>f.summary));
  }
  assert.doesNotMatch(JSON.stringify([data.features,data.faq]),/4\.1\.14|5\.0\.0/);
});
