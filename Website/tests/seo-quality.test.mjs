import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {runInNewContext} from 'node:vm';
import sharp from 'sharp';
import worker from '../src/index.js';
import {home as helpHome} from '../src/help/render.js';
import help from '../src/help/content.json' with {type:'json'};
import priority from '../content/priority-guidance.json' with {type:'json'};
import guides from '../content/decision-guides.json' with {type:'json'};
import networks from '../content/networks.json' with {type:'json'};
import manifest from '../src/tokens-manifest.json' with {type:'json'};
import facts from '../public/oath-data.json' with {type:'json'};
import {documents} from '../src/agent-content.js';
const root=new URL('../public/',import.meta.url),origin='https://oathwallet.org';
const read=p=>readFile(new URL('.'+p,root),'utf8');
const env={ASSETS:{async fetch(req){const p=new URL(req.url).pathname;try{return new Response(await read(p),{headers:{'Content-Type':p.endsWith('.html')?'text/html':p.endsWith('.json')?'application/json':'text/plain'}});}catch{return new Response('Missing',{status:404});}}}};
const get=p=>worker.fetch(new Request(origin+p),env);
const nodes=html=>[...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].flatMap(m=>{const j=JSON.parse(m[1]);return j['@graph']||[j];});
const escape=s=>s.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#39;');
test('site names agree and imported App Store ratings are not review markup',async()=>{
 const main=await read('/index.html');
 for(const [html,name]of [[main,'Oath Wallet'],[await read('/articles.html'),'Oath Wallet Articles'],[helpHome(help),'Oath Wallet Help']]){
  assert.ok(html.includes(`property="og:site_name" content="${name}"`));assert.equal(nodes(html).find(n=>n['@type']==='WebSite').name,name);
 }
 const app=nodes(main).find(n=>n['@type']==='MobileApplication');assert.equal(app.aggregateRating,undefined);assert.equal(app.review,undefined);
 const rating=facts.facts.app_store_rating,date=new Intl.DateTimeFormat('en-US',{month:'long',day:'numeric',year:'numeric',timeZone:'UTC'}).format(new Date(rating.checked_on+'T00:00:00Z'));
 assert.ok(main.includes(`${rating.count} US ratings`));assert.ok(main.includes(`Rating checked ${date}`));
 assert.ok(main.includes(`${rating.value.toFixed(1)} out of 5`));
 assert.ok((await read('/index.md')).includes(`Rated **${rating.value.toFixed(1)} out of 5** from ${rating.count} ratings in the US App Store · checked ${date}`));
 const token=await(await get('/tokens/usdc/base')).text();assert.equal(nodes(token).find(n=>n['@type']==='WebPage').isPartOf['@id'],origin+'/#site');assert.match(token,/property="og:site_name" content="Oath Wallet"/);
});
test('product metadata agrees across pages and source code uses its correct schema type',async()=>{
 const products=await Promise.all(['/index.html','/features.html'].map(async path=>nodes(await read(path)).find(n=>n['@type']==='MobileApplication')));
 for(const app of products){
  assert.equal(app.name,'Oath: Crypto & Bitcoin Wallet');assert.equal(app.softwareVersion,facts.facts.app_version);assert.equal(app.operatingSystem,'iOS, iPadOS');
  assert.deepEqual(app.featureList,facts.features.map(f=>f.name));assert.equal(app.codeRepository,undefined);
  assert.equal(app.subjectOf['@type'],'SoftwareSourceCode');assert.equal(app.subjectOf.codeRepository,facts.facts.source_code);
  assert.equal(app.aggregateRating,undefined);assert.equal(app.review,undefined);
 }
 const security=nodes(await read('/security.html')).filter(n=>n['@type']==='WebPage'&&n.url===origin+'/security');
 assert.equal(security.length,1);assert.equal(security[0]['@id'],origin+'/security');assert.equal(security[0].dateModified,'2026-11-02');
 // A dated source review is not retroactively relabeled as a newer app version.
 assert.ok(help.articles.every(a=>a.app_version));
 assert.match(helpHome(help),/Each guide identifies the Oath version it covers/);
 assert.match(await read('/security.html'),/id="source-correspondence"/);
});
test('every priority page has complete HTML and Markdown guidance with original images',async()=>{
 for(const [path,p]of Object.entries(priority.pages)){
  const response=await get(path);assert.equal(response.status,200,path);const html=await response.text(),md=await(await get(path+'.md')).text();
  for(const q of p.questions){assert.ok(html.includes(escape(q.q)),path);assert.ok(html.includes(escape(q.a)),path);assert.ok(md.includes(q.q),path+' Markdown question');assert.ok(md.includes(q.a),path+' Markdown answer');}
  for(const l of p.links){assert.ok(html.includes('href="'+l.url+'"'),path+' '+l.url);assert.ok(md.includes(l.url.startsWith('/')?origin+l.url:l.url),path+' Markdown link');}
  if(p.image){const bytes=await readFile(new URL('.'+p.image.path,root));assert.equal(createHash('sha256').update(bytes).digest('hex'),p.image.sha256);const image=await sharp(bytes).metadata();assert.equal(image.width,1320);assert.equal(image.height,2868);assert.ok(html.includes(p.image.path));assert.ok(html.includes(p.image.version));assert.ok(md.includes(p.image.path));}
 }
});
test('decision guides expose all entries without JavaScript and retain canonical discovery',async()=>{
 const sitemap=await read('/sitemaps/pages.xml');
 for(const p of guides.pages){
  const r=await get(p.path);assert.equal(r.status,200);assert.equal(r.headers.get('X-Robots-Tag'),null);const html=await r.text();assert.equal((html.match(/<h1>/g)||[]).length,1);assert.ok(html.includes('href="'+origin+p.path+'"'));assert.ok(html.includes('<noscript>'));assert.ok(sitemap.includes('<loc>'+origin+p.path+'</loc><lastmod>'+guides.updated+'</lastmod>'));assert.ok(documents.some(d=>d.url===origin+p.path));
  for(const suffix of ['.html','/']){const redir=await get(p.path+suffix);assert.equal(redir.status,308);assert.equal(redir.headers.get('Location'),origin+p.path);}
  const md=await get(p.path+'.md');assert.equal(md.status,200);assert.match(md.headers.get('X-Robots-Tag'),/noindex/);
 }
 const fees=await(await get('/networks/fees')).text();for(const n of networks.networks){assert.ok(fees.includes('id="'+n.slug+'"'));assert.ok(fees.includes(escape(n.send)));}
 const choice=await(await get('/networks/choose-token-network')).text();let expected=0;
 for(const slug of ['usdt','usdc']){const shard=createHash('sha256').update(slug).digest('hex').slice(0,2),c=JSON.parse(await read(manifest.prefix+'/coins/'+shard+'.json'))[slug];expected+=c.assets.length;for(const a of c.assets)assert.ok(choice.includes('href="'+a.path+'"'),a.path);}
 assert.equal((choice.match(/data-transfer-path=/g)||[]).length,expected);assert.doesNotMatch(choice,/<input[^>]*type="(?:text|password|number)"|connectWallet|ethereum\.request/);
});
test('decision filters preserve entries and announce the result count',async()=>{
 const cards=['tether','usd-coin','tether'].map(value=>({dataset:{decisionValue:value},hidden:false}));const panel={hidden:true},status={},filter={value:'',addEventListener(event,fn){this.change=fn;}};
 runInNewContext(await read('/decision-guides.js'),{document:{querySelector:q=>q==='.decision-controls'?panel:q==='[data-decision-filter]'?filter:status,querySelectorAll:()=>cards}});
 assert.equal(panel.hidden,false);assert.equal(status.textContent,'3 entries shown');filter.value='usd-coin';filter.change();assert.equal(cards.filter(c=>!c.hidden).length,1);assert.equal(status.textContent,'1 entry shown');filter.value='';filter.change();assert.equal(cards.filter(c=>!c.hidden).length,3);
});
test('release history and migration pages retain accountable versioned evidence',async()=>{
 const release=await read('/articles/oath-wallet-release-history.html');assert.match(release,/5\.0\.2 \(104\)/);assert.match(release,/5\.0\.2-distribution\.json/);assert.match(release,/about#editorial/);assert.doesNotMatch(release,/5\.0\.3.*(?:available|released)/);assert.match(await read('/about.html'),/What a reviewed guide means/);
 for(const slug of ['move-from-trust-wallet-to-oath','use-metamask-wallet-in-oath','restore-electrum-bitcoin-wallet-on-iphone']){const html=await read('/articles/'+slug+'.html');assert.match(html,/Oath 4\.0\.3 app screenshot with sample data/);assert.match(html,/networks\/fees/);assert.match(html,/oath-wallet-release-history/);}
});
