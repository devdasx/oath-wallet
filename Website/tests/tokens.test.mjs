import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {gunzipSync} from 'node:zlib';
import {execFileSync} from 'node:child_process';
import {validateSnapshot,assignRoutes,digest,identity,readLedger,nativeAlias} from '../scripts/token-catalog.mjs';
import {sitemapURLs} from '../scripts/sitemaps.mjs';
import {detailContent,escapeHTML,cachedTokens} from '../src/tokens.js';
import worker from '../src/index.js';
import manifest from '../src/tokens-manifest.json' with {type:'json'};
import networks from '../content/networks.json' with {type:'json'};
const root=new URL('../public/',import.meta.url),main='https://oathwallet.org';
const read=p=>readFile(new URL('.'+p,root),'utf8');
const source=JSON.parse(gunzipSync(await readFile(new URL('../content/tokens/source.json.gz',import.meta.url))));
source.networks=networks.networks.filter(n=>source.enabled.includes(n.id));
const ledger=readLedger(JSON.parse(await readFile(new URL('../content/tokens/routes.json',import.meta.url))));
const {rows}=assignRoutes(validateSnapshot(source),ledger);
const routes=JSON.parse(await read(manifest.prefix+'/routes.json'));
const routeSet=new Set(routes.map(r=>r.path));
const environment=()=>({ASSETS:{async fetch(req){try{const p=new URL(req.url).pathname;return new Response(await read(p),{headers:{'Content-Type':p.endsWith('.html')?'text/html':p.endsWith('.json')?'application/json':'text/plain'}});}catch{return new Response('Missing',{status:404});}}}});
const env=environment();
const get=(path,options)=>worker.fetch(new Request(main+path,options),env);

test('edge cache keeps search and Markdown separate and survives asset read failures',async()=>{
 const previous=globalThis.caches,stored=new Map(),pending=[];
 globalThis.caches={default:{async match(key){return stored.get(key.url)?.clone();},async put(key,response){stored.set(key.url,response.clone());}}};
 const ctx={waitUntil:p=>pending.push(p)};
 try{
  const first=await cachedTokens(new Request(main+'/tokens'),env,ctx);assert.equal(first.status,200);await Promise.all(pending);assert.equal(stored.size,1);
  const unavailable={ASSETS:{fetch:async()=>new Response(null,{status:503})}};
  const hit=await cachedTokens(new Request(main+'/tokens'),unavailable,ctx);assert.equal(hit.status,200);assert.match(await hit.text(),/Find your token/);
  const search=await cachedTokens(new Request(main+'/tokens?q=USDC'),env,ctx);assert.match(search.headers.get('X-Robots-Tag'),/noindex/);
  const md=await cachedTokens(new Request(main+'/tokens',{headers:{Accept:'text/markdown'}}),env,ctx);assert.match(md.headers.get('Content-Type'),/text\/markdown/);assert.equal(stored.size,1);
  assert.equal((await cachedTokens(new Request(main+'/tokens?q=USDC'),unavailable,ctx)).status,503);
 }finally{if(previous===undefined)delete globalThis.caches;else globalThis.caches=previous;}
});

test('accepted snapshot exactly matches the approved Git release after native-alias filtering',async()=>{
 const evidence=JSON.parse(await readFile(new URL('../content/release-evidence.json',import.meta.url)));
 const distribution=JSON.parse(await readFile(new URL(`../../releases/${source.version}-distribution.json`,import.meta.url)));
 assert.equal(source.revision,evidence.source_commit);assert.equal(source.revision,distribution.source_commit);assert.equal(distribution.status,'READY_FOR_DISTRIBUTION');
 const raw=execFileSync('git',['show',source.revision+':Packages/OathAnkr/Sources/OathAnkr/Resources/TokenDiscoverySeed.json'],{cwd:new URL('../../',import.meta.url),maxBuffer:20*1024*1024});
 assert.equal(digest(raw),source.sha256);assert.deepEqual(source.entries,JSON.parse(raw).entries.filter(e=>!nativeAlias(e)));
});

test('every catalog identity and route is unique, pinned, escaped and in the sitemap',async()=>{
 assert.equal(rows.length,manifest.count);assert.equal(rows.length,32135);
 assert.equal(source.rawCount,32136);assert.equal(source.excludedNativeAliases.length,1);
 assert.equal(new Set(rows.map(identity)).size,rows.length);
 assert.equal(new Set(rows.map(r=>r.path)).size,rows.length);
 assert.equal(new Set(rows.map(r=>r.coinID)).size,manifest.coinCount);
 assert.equal(Object.keys(manifest.networks).length,38);
 assert.ok(!manifest.enabled.includes('cronos'));
 const sitemap=await sitemapURLs(),all=new Set(sitemap.map(u=>new URL(u).pathname+new URL(u).search));
 assert.equal(sitemap.length,new Set(sitemap).size);
 assert.equal(routeSet.size,routes.length);
 for(const r of routes)assert.ok(all.has(r.path),r.path);
 const coins={};
 for(const file of await readdir(new URL('.'+manifest.prefix+'/coins/',root)))Object.assign(coins,JSON.parse(await read(manifest.prefix+'/coins/'+file)));
 const core=new Set(networks.networks.map(n=>'/networks/'+n.slug));
 for(const a of rows){
  assert.match(a.path,/^\/tokens\/[a-z0-9-]+\/[a-z0-9-]+$/);
  const c=coins[a.slug];assert.ok(c);assert.equal(c.coinID,a.coinID);
  assert.ok(c.assets.some(x=>identity(x)===identity(a)&&x.path===a.path));
  assert.ok(manifest.networks[a.network]);
  assert.ok(routeSet.has(a.path));
  const m=detailContent(c,a);
  assert.equal((m.content.match(/<h1>/g)||[]).length,1);
  assert.ok(m.content.includes(escapeHTML(a.reference)));
  assert.match(m.content,/not your receiving address/);
  assert.ok(m.title.includes(manifest.networks[a.network].name));
  for(const [,path]of m.content.matchAll(/href="(\/[^"#]*)"/g))assert.ok(routeSet.has(path)||core.has(path),a.path+' links to '+path);
  if(a.decimals==null||a.network==='xrpl')assert.ok(!m.content.includes('Catalog decimals'));
 }
 for(const c of Object.values(coins))assert.equal(routeSet.has('/tokens/'+c.slug),c.assets.length>1);
});

test('all network lists cover every identity exactly once, with 50 entries per page',async()=>{
 const found=new Set();
 for(const n of Object.values(manifest.networks)){
  let count=0;
  for(let p=1;p<=n.pages;p++){
   const entries=JSON.parse(await read(`${manifest.prefix}/networks/${n.slug}/${p}.json`));
   assert.ok(entries.length>0&&entries.length<=50);if(p<n.pages)assert.equal(entries.length,50);
   for(const a of entries){assert.equal(a.network,n.id);assert.ok(!found.has(a.path));found.add(a.path);count++;}
  }
  assert.equal(count,n.count);assert.ok(n.featured.length<=12);
 }
 assert.equal(found.size,manifest.count);
 const assets=[];for(let p=1;p<=manifest.pages;p++)assets.push(...JSON.parse(await read(`${manifest.prefix}/directory/${p}.json`)));
 assert.equal(assets.length,manifest.coinCount);assert.equal(new Set(assets.map(a=>a.slug)).size,manifest.coinCount);
 assert.ok(assets.every(a=>routeSet.has(a.path)));
});

test('rendering, canonical and Markdown work across every network and page type',async()=>{
 const paths=[...manifest.samples,'/tokens','/tokens?page=2','/tokens?page='+manifest.pages,...Object.values(manifest.networks).map(n=>'/networks/'+n.slug+'/tokens')];
 for(const path of paths){
  const r=await get(path);assert.equal(r.status,200,path);const html=await r.text();
  assert.ok(html.includes(`<link rel="canonical" href="${escapeHTML(main+path)}">`),path);
  assert.match(html,/<meta name="robots" content="index,follow">/);assert.equal((html.match(/<h1>/g)||[]).length,1);
  assert.match(html,/href="https:\/\/oathwallet.org\/tokens"/);
  assert.ok(html.includes('Oath '+manifest.source.version));
  const json=JSON.parse(html.match(/<script type="application\/ld\+json">(.*?)<\/script>/s)[1]);assert.equal(json['@graph'][0].url,main+path);
  const md=await get(path,{headers:{Accept:'text/markdown'}});assert.equal(md.status,200);assert.match(md.headers.get('Content-Type'),/text\/markdown/);assert.match(md.headers.get('X-Robots-Tag'),/noindex/);assert.ok((await md.text()).startsWith('Canonical: '+main+path));
  const head=await get(path,{method:'HEAD'});assert.equal(head.status,200);assert.equal(await head.text(),'');
 }
});

test('search, filters, pagination and unknown pages have deliberate indexing behavior',async()=>{
 for(const path of ['/tokens/no-such-token','/tokens/constructor','/tokens/usdt/no-such-network','/tokens/usdt/base-extra','/networks/bitcoin/tokens','/networks/cronos/tokens','/tokens?page=0','/tokens?page=999999','/tokens?page=1.5','/tokens/documents.json?page=999999'])assert.equal((await get(path)).status,404,path);
 for(const [path,target]of [['/tokens/','/tokens'],['/tokens?page=1','/tokens'],['/tokens?network=base','/networks/base/tokens']]){const r=await get(path);assert.equal(r.status,308);assert.equal(r.headers.get('Location'),main+target);}
 const one=rows.find(a=>rows.filter(b=>b.coinID===a.coinID).length===1);const r=await get('/tokens/'+one.slug);assert.equal(r.status,308);assert.equal(r.headers.get('Location'),main+one.path);
 for(const q of ['USDC','<script>alert(1)</script>','zzyynotpresentxxxx']){const r=await get('/tokens?q='+encodeURIComponent(q)+'&network=base');assert.equal(r.status,200);assert.match(r.headers.get('X-Robots-Tag'),/noindex/);const html=await r.text();assert.ok(!html.includes('<script>alert(1)</script>'));assert.ok(html.includes('value="'+escapeHTML(q)+'"'));}
 assert.equal((await get('/tokens',{method:'POST'})).status,405);
 assert.equal((await get('/tokens.md')).status,200);
 const discovery=await get('/tokens/documents.json');assert.equal(discovery.status,200);const d=await discovery.json();assert.equal(d.documents.length,100);assert.ok(d.next.endsWith('page=2'));
 const fail={ASSETS:{fetch:async()=>new Response(null,{status:503})}};
 assert.equal((await worker.fetch(new Request(main+'/tokens'),fail)).status,503);
 assert.equal((await get('/tokens')).status,200,'failed source is not shared across environments');
});

test('refresh preserves identity, reserves aliases, rejects invalid snapshots and never reuses removed paths',()=>{
 const fixture={...source,entries:[{network:'ethereum',reference:'0x'+'1'.repeat(40),coinID:'coin-a',name:'First',symbol:'SAME'},{network:'ethereum',reference:'0x'+'2'.repeat(40),coinID:'coin-b',name:'Second',symbol:'SAME'}]};
 const first=assignRoutes(fixture);assert.notEqual(first.rows[0].path,first.rows[1].path);
 assert.deepEqual(assignRoutes({...fixture,entries:[...fixture.entries].reverse()},first.ledger).rows.map(a=>a.path),first.rows.map(a=>a.path).reverse());
 const replacement={...fixture,entries:[{...fixture.entries[0],reference:'0x'+'3'.repeat(40)}]};
 assert.notEqual(assignRoutes(replacement,first.ledger).rows[0].path,first.rows[0].path);
 assert.throws(()=>assignRoutes({...fixture,entries:[{...fixture.entries[0],coinID:'renamed'}]},first.ledger),/grouping changed/);
 for(const change of [{network:'cronos'},{network:'bitcoin'},{reference:'native'},{reference:'javascript:alert(1)'},{reference:'0x123'},{name:'bad\u202evalue'},{decimals:-1}])assert.throws(()=>validateSnapshot({...fixture,entries:[{...fixture.entries[0],...change}]}));
 assert.throws(()=>validateSnapshot({...fixture,entries:[fixture.entries[0],fixture.entries[0]]}),/Duplicate/);
 const malicious={...fixture.entries[0],name:'</h1><script>alert(1)</script>',symbol:'" onload="bad'};
 const content=detailContent({coinID:malicious.coinID,assets:[malicious]},{...malicious,path:'/tokens/coin-a/ethereum'}).content;
 assert.ok(!content.includes('<script>alert(1)</script>'));assert.ok(content.includes('&lt;script&gt;'));
 assert.equal(digest(JSON.stringify(ledger)),digest(JSON.stringify(assignRoutes(source,ledger).ledger)));
});
