import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import sharp from 'sharp';
import catalog from '../content/features.json' with {type:'json'};
import distribution from '../../releases/5.0.2-distribution.json' with {type:'json'};
import help from '../src/help/content.json' with {type:'json'};
import networks from '../content/networks.json' with {type:'json'};
import {documents} from '../src/agent-content.js';
import worker from '../src/index.js';
const root=new URL('../public/',import.meta.url),origin='https://oathwallet.org';
const read=p=>readFile(new URL('.'+p,root),'utf8');
const env={ASSETS:{async fetch(req){const path=new URL(req.url).pathname;try{return new Response(await read(path),{headers:{'Content-Type':path.endsWith('.md')?'text/markdown':path.endsWith('.xml')?'application/xml':'text/html'}});}catch{return new Response('Missing',{status:404});}}}};
const escape=s=>s.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');

test('feature claims and unchanged screenshots retain pinned release provenance',async()=>{
 assert.equal(catalog.sourceCommit,distribution.source_commit);
 assert.equal(catalog.version,distribution.version);assert.equal(catalog.build,distribution.build);
 assert.equal(distribution.status,'READY_FOR_DISTRIBUTION');
 assert.equal(catalog.features.length,3);
 assert.equal(new Set(catalog.features.map(f=>f.path)).size,3);
 for(const f of catalog.features){
  const image=await readFile(new URL('.'+f.image.path,root));
  assert.equal(createHash('sha256').update(image).digest('hex'),f.image.sha256);
  const meta=await sharp(image).metadata();assert.equal(meta.width,f.image.width);assert.equal(meta.height,f.image.height);
  assert.equal(f.image.version,help.articles.find(a=>a.slug===f.guide).screenshot_version);
  for(const s of f.sources){
   const bytes=execFileSync('git',['show',catalog.sourceCommit+':'+s.path],{cwd:new URL('../../',import.meta.url),maxBuffer:5*1024*1024});
   assert.equal(createHash('sha256').update(bytes).digest('hex'),s.sha256,s.path);
  }
 }
});

test('each feature is complete in initial HTML and Markdown, canonical and discoverable',async()=>{
 const sitemap=await read('/sitemaps/pages.xml');
 const hub=await read('/features.html');
 const server=hub.match(/<!-- oath-server-content:start -->([\s\S]*?)<!-- oath-server-content:end -->/)[1];
 const template=hub.match(/<template data-oath-template>([\s\S]*?)<\/template>/)[1];
 const titles=new Set(),descriptions=new Set();
 for(const f of catalog.features){
  const url=origin+f.path;
  const r=await worker.fetch(new Request(url),env);assert.equal(r.status,200);
  const html=await r.text();
  assert.equal((html.match(/<h1\b/g)||[]).length,1);
  assert.match(html,/<main id="content" class="feature-main" tabindex="-1">/);
  assert.ok(html.includes(`<link rel="canonical" href="${url}">`));
  assert.match(html,/<meta name="robots" content="index,follow/);
  assert.ok(r.headers.get('Link').includes(url+'.md'));
  assert.ok(html.includes(f.image.path));assert.ok(html.includes(f.image.version));assert.ok(html.includes(escape(f.image.caption)));
  assert.ok(html.includes('width="'+f.image.width+'" height="'+f.image.height+'"'));
  assert.match(html,/<!-- oath-shared-header:start -->/);assert.match(html,/<!-- oath-shared-footer:start -->/);
  assert.doesNotMatch(html,/\{\{|\u2197/);
  titles.add(html.match(/<title>(.*?)<\/title>/)[1]);descriptions.add(html.match(/<meta name="description" content="([^"]+)/)[1]);
  const schema=JSON.parse(html.match(/<script type="application\/ld\+json">(.*?)<\/script>/)[1]);
  assert.equal(schema['@graph'].find(x=>x['@type']==='WebPage').url,url);
  assert.deepEqual(schema['@graph'].find(x=>x['@type']==='BreadcrumbList').itemListElement.map(x=>x.item),[origin+'/',origin+'/features',url]);
  const md=await worker.fetch(new Request(url+'.md'),env);assert.equal(md.status,200);assert.ok(md.headers.get('Link').includes(url));assert.equal(md.headers.get('X-Robots-Tag'),'noindex');
  const text=await md.text();
  for(const str of [f.intro,...f.scope.map(s=>s.detail),...f.steps.map(s=>s.text),...f.questions.map(q=>q.a)]){assert.ok(html.includes(escape(str)),f.slug+' HTML');assert.ok(text.includes(str),f.slug+' Markdown');}
  for(const g of f.guides){assert.ok(help.articles.some(a=>a.slug===g.slug));assert.ok(html.includes('https://help.oathwallet.org/articles/'+g.slug));}
  for(const s of f.scope)for(const slug of s.links){assert.ok(networks.networks.some(n=>n.slug===slug));assert.ok(html.includes('/networks/'+slug));}
  assert.ok(sitemap.includes(`<loc>${url}</loc><lastmod>${catalog.reviewed}</lastmod>`));
  for(const content of [server,template])assert.ok(content.includes('href="'+f.path+'"'));
  assert.ok(documents.some(d=>d.url===url&&d.kind==='feature'));
  for(const suffix of ['/','.html']){const redirect=await worker.fetch(new Request(url+suffix),env);assert.equal(redirect.status,308);assert.equal(redirect.headers.get('Location'),url);}
  const negotiated=await worker.fetch(new Request(url,{headers:{Accept:'text/markdown'}}),env);assert.equal(await negotiated.text(),text);assert.match(negotiated.headers.get('Vary'),/Accept/);
 }
 assert.equal(titles.size,3);assert.equal(descriptions.size,3);
 const missing=await worker.fetch(new Request(origin+'/features/not-a-feature'),env);assert.equal(missing.status,404);
});

test('high-consequence capability limits remain visible in both representations',async()=>{
 const expectations={
  'revoke-token-approvals':[/partial, unavailable or unsupported/,/does not reverse completed transfers/,/Permanent delegates/,/Results can be mixed/],
  'icloud-wallet-backup':[/Electrum and aezeed/,/excluded from iCloud backup/,/excludes Recently Deleted/,/600,000 rounds/,/cannot reset/,/still in progress/],
  'walletconnect':[/Arc connections are not supported/,/separate from TON Connect/,/does not approve every future/,/on-chain token access are separate/]
 };
 for(const [slug,patterns] of Object.entries(expectations))for(const ext of ['html','md']){
  const content=await read('/features/'+slug+'.'+ext);for(const pattern of patterns)assert.match(content,pattern);
 }
});
