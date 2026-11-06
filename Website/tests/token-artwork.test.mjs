import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {gunzipSync} from 'node:zlib';
import {execFileSync} from 'node:child_process';
import vm from 'node:vm';
import {artworkSnapshot,attachArtwork} from '../scripts/token-artwork.mjs';
import {tokenArtwork,stripTokenArtwork,permittedArtworkURL,artworkCandidates} from '../src/token-artwork.js';
import {fetchArtwork,handleArtwork,imageType} from '../src/artwork-route.js';
import worker from '../src/index.js';
import manifest from '../src/artwork-manifest.json' with {type:'json'};
import tokens from '../src/tokens-manifest.json' with {type:'json'};

const origin='https://oathwallet.org';
const root=new URL('../public/',import.meta.url);
const snapshot=await artworkSnapshot();
const source=JSON.parse(gunzipSync(await readFile(new URL('../content/tokens/source.json.gz',import.meta.url))));
const rows=attachArtwork(source.entries,snapshot);
const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j5S8AAAAASUVORK5CYII=','base64');
const bytes=text=>new TextEncoder().encode(text);
const environment=()=>({ASSETS:{async fetch(request){
  try {const path=new URL(request.url).pathname;return new Response(await readFile(new URL('.'+path,root)),{headers:{'Content-Type':path.endsWith('.html')?'text/html':'application/json'}});}
  catch{return new Response(null,{status:404});}
}}});

test('every artwork entry has an exact accepted identity and generated shard; missing artwork remains absent',async()=>{
  assert.equal(snapshot.version,manifest.version);
  assert.equal(Object.keys(snapshot.images).length,manifest.entries);
  const shards=new Map(),seen=new Set(),counts={};
  for(const row of rows){
    const identity=row.network+':'+row.reference;
    if(!snapshot.images[identity]){assert.equal(row.artwork,undefined);continue;}
    assert.ok(permittedArtworkURL(snapshot.images[identity]));
    const key=row.artwork.split('/').at(-1),prefix=key.slice(0,2);
    assert.ok(!seen.has(key));seen.add(key);
    if(!shards.has(prefix))shards.set(prefix,JSON.parse(await readFile(new URL('.'+manifest.prefix+'/'+prefix+'.json',root))));
    const entry=shards.get(prefix)[key];
    assert.equal(entry.source,snapshot.images[identity]);
    assert.equal(entry.initials,Array.from(row.symbol).slice(0,2).join(''));
    counts[row.network]=(counts[row.network]||0)+1;
  }
  assert.equal(seen.size,manifest.entries);
  for(const [network,count]of Object.entries(manifest.networks))assert.equal(counts[network]||0,count);
  const fixture=rows.find(a=>a.artwork);
  assert.equal(attachArtwork([{...fixture,reference:'different-contract',artwork:undefined}],snapshot)[0].artwork,undefined);
  assert.equal(attachArtwork([{...fixture,network:'different-network',artwork:undefined}],snapshot)[0].artwork,undefined);
});

test('directory, search, asset hub, detail, network and transfer surfaces include local images in initial HTML',async()=>{
  const env=environment();
  for(const path of ['/tokens','/tokens?q=USDC&network=base','/tokens/usdc','/tokens/usdc/base','/tokens/usdt/tron','/networks/base/tokens','/networks/base','/networks/choose-token-network?token=usdc&network=base']){
    const response=await worker.fetch(new Request(origin+path),env);assert.equal(response.status,200,path);
    const html=await response.text();
    assert.match(html,new RegExp('src="/token-artwork/'+manifest.version+'/[a-f0-9]{32}"'),path);
    assert.ok(html.includes('/token-artwork.css'),path);assert.ok(html.includes('/token-artwork.js'),path);
    assert.doesNotMatch(html,/<img[^>]+src="https:\/\/(?:assets|coin-images)\.coingecko\.com/);
  }
  const index=JSON.parse(await readFile(new URL('.'+tokens.prefix+'/search.json',root)));
  assert.equal(index.filter(a=>a[6]).length,manifest.entries);
  const missing=tokenArtwork({symbol:'<"'});
  assert.doesNotMatch(missing,/<img/);assert.match(missing,/&lt;&quot;/);
  assert.doesNotMatch(tokenArtwork({symbol:'X',artwork:'https://untrusted.example/logo.svg'}),/<img/);
  assert.match(tokenArtwork(rows.find(a=>a.artwork),64,true),/width="64" height="64" loading="eager"/);
  assert.equal(stripTokenArtwork(tokenArtwork(rows.find(a=>a.artwork))+'Token name'),'Token name');
  assert.equal(stripTokenArtwork(missing+'Token name'),'Token name');
  const markdown=await worker.fetch(new Request(origin+'/tokens/usdc/base',{headers:{Accept:'text/markdown'}}),env);
  assert.doesNotMatch(await markdown.text(),/\nUS\s*\n/);
});

test('public metadata is noindex; unknown identities, methods, query URLs and failed metadata are handled explicitly',async()=>{
  const env=environment(),row=rows.find(a=>a.artwork);
  const metadata=await handleArtwork(new Request(origin+manifest.prefix+'/'+row.artwork.split('/').at(-1).slice(0,2)+'.json'),env);
  assert.equal(metadata.headers.get('X-Robots-Tag'),'noindex');
  for(const path of ['/token-artwork/invalid',row.artwork+'?source=https://example.com',row.artwork.replace(manifest.version,'0'.repeat(16)),`/token-artwork/${manifest.version}/${'0'.repeat(32)}`])assert.equal((await handleArtwork(new Request(origin+path),env)).status,404);
  assert.equal((await handleArtwork(new Request(origin+row.artwork,{method:'POST'}),env)).status,405);
  assert.equal((await handleArtwork(new Request(origin+row.artwork),{ASSETS:{fetch:async()=>new Response(null,{status:503})}})).status,503);
});

test('upstream image validation rejects arbitrary sources, unsafe redirects, active content and oversized responses',async()=>{
  const allowed='https://assets.coingecko.com/coins/images/1/large/logo.png';
  for(const url of ['http://assets.coingecko.com/a','https://assets.coingecko.com.evil.example/a','https://assets.coingecko.com@evil.example/a','https://assets.coingecko.com:8080/a','file:///tmp/a','https://127.0.0.1/a']){
    assert.equal(permittedArtworkURL(url),false);await assert.rejects(fetchArtwork(url,()=>{throw Error('must not fetch');}),/Unaccepted/);
  }
  let calls=0;
  await assert.rejects(fetchArtwork(allowed,async()=>{calls++;return new Response(null,{status:302,headers:{Location:'https://untrusted.example/image.png'}});}),/Unaccepted/);
  assert.equal(calls,1);
  await assert.rejects(fetchArtwork(allowed,async()=>new Response(null,{status:302,headers:{Location:allowed}})),/redirect limit/);
  for(const body of ['<!doctype html><script>alert(1)</script>','<svg onload="alert(1)"/>','<svg><script/></svg>','<svg><foreignObject/></svg>','<svg><image href="https://example.com/a"/></svg>','<svg><style>@import "a";</style></svg>','<svg><path fill="url(https://example.com/a)"/></svg>'])assert.equal(imageType(bytes(body)),null,body);
  assert.equal(imageType(bytes('<svg xmlns="http://www.w3.org/2000/svg"><path fill="url(\'#gradient\')"/></svg>')),'image/svg+xml');
  await assert.rejects(fetchArtwork(allowed,async()=>new Response('bad',{headers:{'Content-Length':String(2*1024*1024+1)}})),/unavailable/);
  await assert.rejects(fetchArtwork(allowed,async()=>new Response(new Uint8Array(2*1024*1024+1))),/too large/);
  const response=await fetchArtwork(allowed,async(url,options)=>{
    assert.equal(options.redirect,'manual');assert.deepEqual(Object.keys(options.headers),['Accept']);
    return new Response(png,{headers:{'Content-Type':'text/plain'}});
  });
  assert.equal(response.headers.get('Content-Type'),'image/png');
  assert.match(response.headers.get('Content-Security-Policy'),/sandbox/);
  const original='https://assets.coingecko.com/coins/images/1/thumb/logo%282%29%2Fimage.png?1';
  const candidates=artworkCandidates(original),attempted=[];
  assert.equal(candidates[0],original.replace('/thumb/','/large/'));
  const recovered=await fetchArtwork(original,async url=>{attempted.push(url);return url===original?new Response(png):new Response(null,{status:404});});
  assert.equal(recovered.headers.get('X-Oath-Artwork'),'image');assert.deepEqual(attempted,candidates);
});

test('image cache coalesces concurrent requests, serves HEAD and retains stale images during provider failure',async()=>{
  const priorFetch=globalThis.fetch,priorCaches=globalThis.caches,stored=new Map(),pending=[];
  globalThis.caches={default:{async match(key){return stored.get(key.url)?.clone();},async put(key,value){stored.set(key.url,value.clone());}}};
  let calls=0;globalThis.fetch=async()=>{calls++;await new Promise(r=>setTimeout(r,5));return new Response(png);};
  const env=environment(),url=origin+rows.find(a=>a.artwork).artwork,request=()=>new Request(url),ctx={waitUntil:p=>pending.push(p)};
  try{
    const responses=await Promise.all(Array.from({length:8},()=>handleArtwork(request(),env,ctx)));
    assert.equal(calls,1);for(const r of responses){assert.equal(r.headers.get('X-Oath-Artwork'),'image');await r.arrayBuffer();}
    const head=await handleArtwork(new Request(url,{method:'HEAD'}),env,ctx);assert.equal(await head.text(),'');assert.equal(calls,1);
    const stale=stored.get(url);stale.headers.set('X-Oath-Artwork-Fetched',String(Date.now()-8*86400000));
    globalThis.fetch=async()=>{calls++;throw Error('Provider unavailable');};
    const response=await handleArtwork(request(),env,ctx);assert.equal(response.headers.get('X-Oath-Artwork'),'image');await response.arrayBuffer();await Promise.all(pending);
    const attempts=artworkCandidates(snapshot.images[rows.find(a=>a.artwork).network+':'+rows.find(a=>a.artwork).reference]).length;
    assert.equal(stored.get(url).headers.get('X-Oath-Artwork'),'image');assert.equal(calls,1+attempts);
    stored.clear();
    const fallback=await handleArtwork(request(),env,ctx);assert.equal(fallback.headers.get('X-Oath-Artwork'),'fallback');assert.match(await fallback.text(),/<svg/);
    const retried=await handleArtwork(new Request(url,{method:'HEAD'}),env,ctx);assert.equal(await retried.text(),'');assert.equal(retried.headers.get('Cache-Control'),'public, max-age=60');assert.equal(calls,1+attempts*2);
  }finally{globalThis.fetch=priorFetch;if(priorCaches===undefined)delete globalThis.caches;else globalThis.caches=priorCaches;}
});

test('concurrent distinct images are queued with bounded upstream work',async()=>{
  const previous=globalThis.fetch;let active=0,max=0,calls=0;
  globalThis.fetch=async()=>{active++;calls++;max=Math.max(max,active);await new Promise(r=>setTimeout(r,10));active--;return new Response(png);};
  try{
    const env=environment();
    const responses=await Promise.all(rows.filter(a=>a.artwork).slice(0,30).map(a=>handleArtwork(new Request(origin+a.artwork),env)));
    assert.equal(calls,30);assert.ok(max<=12);assert.ok(max>1);
    for(const r of responses){assert.equal(r.headers.get('X-Oath-Artwork'),'image');await r.arrayBuffer();}
  }finally{globalThis.fetch=previous;}
});

test('the browser fallback hides failed images without hiding valid artwork or other page images',async()=>{
  const failed={complete:true,naturalWidth:0,matches:()=>true},loaded={complete:true,naturalWidth:80,matches:()=>true},other={matches:()=>false};let error;
  vm.runInNewContext(await readFile(new URL('../public/token-artwork.js',import.meta.url),'utf8'),{document:{addEventListener:(type,fn,capture)=>{assert.equal(type,'error');assert.equal(capture,true);error=fn;},querySelectorAll:()=>[failed,loaded]}});
  assert.equal(failed.hidden,true);assert.equal(loaded.hidden,undefined);error({target:other});assert.equal(other.hidden,undefined);
  error({target:loaded});assert.equal(loaded.hidden,true);
});

test('refresh normalization preserves case-sensitive identities and rejects invalid TON references',()=>{
  execFileSync('python3',['-c',`import importlib.util
spec=importlib.util.spec_from_file_location('artwork','scripts/refresh-token-artwork.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
assert m.canonical('ethereum','0x'+'AB'*20)=='0x'+'ab'*20
assert m.canonical('solana','CaseSensitiveMint')=='CaseSensitiveMint'
assert m.canonical('ton','bad-reference') is None
assert m.canonical('sui','0xA::coin::COIN')=='0x'+'a'.zfill(64)+'::coin::COIN'
assert m.canonical('polkadot','1984')=='assets:1984'
assert m.logo_url('http://assets.coingecko.com/image.png')=='https://assets.coingecko.com/image.png'
assert m.logo_url('https://attacker.example/image.png') is None
`],{cwd:new URL('../',import.meta.url)});
});
