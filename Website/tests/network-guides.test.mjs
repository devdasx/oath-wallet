import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {runInNewContext} from 'node:vm';
import catalog from '../content/networks.json' with {type:'json'};
import worker from '../src/index.js';
const root=new URL('../public/',import.meta.url);
const read=p=>readFile(new URL(p,root),'utf8');
const env={ASSETS:{async fetch(req){try{return new Response(await readFile(new URL('.'+new URL(req.url).pathname,root)));}catch{return new Response('Missing',{status:404});}}}};

test('every catalog network has a crawlable guide, real logo and canonical route',async()=>{
 const titles=new Set();const descriptions=new Set();const sitemap=await read('sitemap.xml');
 assert.equal(catalog.networks.length,42);
 assert.equal(new Set(catalog.networks.map(n=>n.slug)).size,42);
 for(const n of catalog.networks){
  const url='https://oathwallet.org/networks/'+n.slug;
  const response=await worker.fetch(new Request(url),env);
  assert.equal(response.status,200,n.slug);
  const html=await response.text();
  assert.ok(html.includes('<link rel="canonical" href="'+url+'">'),n.slug);
  assert.match(html,/<meta name="robots" content="index,follow/);
  assert.equal((html.match(/<h1>/g)||[]).length,1,n.slug);
  for(const id of ['receive','send','dapps','questions'])assert.ok(html.includes('id="'+id+'"'),n.slug+' '+id);
  assert.match(html,/Features depend on the app version/);
  assert.match(html,/Availability can differ between app releases/);
  assert.doesNotMatch(html,/\{\{|no Apple upload/);
  titles.add(html.match(/<title>(.*?)<\/title>/)[1]);
  descriptions.add(html.match(/<meta name="description" content="([^"]+)/)[1]);
  for(const script of html.matchAll(/<script type="application\/ld\+json">(.*?)<\/script>/g))assert.ok(JSON.parse(script[1])['@graph']);
  const icon=await readFile(new URL('.'+n.icon,root));
  assert.equal(icon.subarray(0,4).toString(),'RIFF');assert.equal(icon.subarray(8,12).toString(),'WEBP');assert.match(n.sourceIconSHA256,/^[a-f0-9]{64}$/);
  assert.ok(sitemap.includes('<loc>'+url+'</loc>'));
  const md=await worker.fetch(new Request(url+'.md'),env);
  assert.equal(md.status,200);assert.ok(md.headers.get('Link').includes(url));
 }
 assert.equal(titles.size,42);assert.equal(descriptions.size,42);
 const missing=await worker.fetch(new Request('https://oathwallet.org/networks/not-a-network'),env);assert.equal(missing.status,404);
});

test('TON aliases preserve Gram canonical and protocol limitations stay explicit',async()=>{
 for(const path of ['/networks/ton','/networks/ton/','/networks/ton.html']){
  const r=await worker.fetch(new Request('https://oathwallet.org'+path),env);
  assert.equal(r.status,308);assert.equal(r.headers.get('Location'),'https://oathwallet.org/networks/gram');
 }
 const gram=await read('networks/gram.html');assert.match(gram,/TON Connect/);assert.match(gram,/ton.app\/app\/oath-wallet/);
 for(const id of ['aptos','arc','bitcoincash','litecoin','dogecoin']){
  const n=catalog.networks.find(n=>n.id===id);assert.equal(n.walletConnect,false);
  const html=await read('networks/'+n.slug+'.html');assert.doesNotMatch(html,/scan the connection QR with Oath/);
 }
});

test('network slider moves only through explicit controls and respects reduced motion',async()=>{
 const html=await read('index.html');
 const script=html.match(/<script type="text\/x-dc"[^>]*>([\s\S]*?)<\/script>/)[1];
 let reduced=false;const calls=[];
 const component=runInNewContext(script+';new Component()', {DCLogic:class{props={};},React:{createElement:()=>null,createRef:()=>({current:null})},window:{matchMedia:()=>({matches:reduced})}});
 assert.equal(calls.length,0);
 component.r.networkTrack.current={querySelector:()=>({getBoundingClientRect:()=>({width:310})}),scrollBy:options=>calls.push(options)};
 const values=component.renderVals();values.networkNext();assert.equal(calls[0].left,330);assert.equal(calls[0].behavior,'smooth');
 reduced=true;values.networkPrev();assert.equal(calls[1].left,-330);assert.equal(calls[1].behavior,'auto');
 let prevented=false;const target={};values.networkKey({key:'ArrowRight',target,currentTarget:target,preventDefault:()=>{prevented=true;}});
 assert.equal(prevented,true);assert.equal(calls.length,3);
 values.networkKey({key:'ArrowLeft',target:{},currentTarget:target});assert.equal(calls.length,3);
 assert.equal((script.match(/this\.scrollNetworks\(/g)||[]).length,3,'only next, previous and keyboard handlers invoke scrolling');
 const server=html.match(/<!-- oath-server-content:start -->([\s\S]*?)<!-- oath-server-content:end -->/)[1];
 for(const n of catalog.networks)assert.ok(server.includes('https://oathwallet.org/networks/'+n.slug),'server HTML links '+n.slug);
 assert.equal((html.match(/id="network-track"/g)||[]).length,1,'one enhanced slider');
});

test('directory search handles TON aliases, empty results and resetting the filter',async()=>{
 let callback;const cards=catalog.networks.map(n=>({hidden:false,dataset:{networkKeywords:n.name+' '+n.symbol+' '+n.id}}));
 const input={value:'',addEventListener:(name,cb)=>{callback=cb;}};const count={};const empty={};
 const document={querySelector:s=>s==='[data-network-search]'?input:s==='[data-network-count]'?count:empty,querySelectorAll:()=>cards};
 runInNewContext(await read('network-guides.js'),{document});
 input.value='ton';callback();assert.ok(cards.some(c=>!c.hidden&&c.dataset.networkKeywords.includes('Gram')));
 input.value='no-such-chain';callback();assert.equal(cards.filter(c=>!c.hidden).length,0);assert.equal(empty.hidden,false);
 input.value='';callback();assert.equal(cards.filter(c=>!c.hidden).length,42);assert.equal(empty.hidden,true);
});
