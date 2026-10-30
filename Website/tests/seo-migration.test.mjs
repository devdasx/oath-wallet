import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import worker from '../src/index.js';
import {articleURL,handleArticleHost,migrateArticleLinks} from '../src/article-host.js';
import {articleRoutes} from '../src/article-routes.js';
import {handleHelp} from '../src/help/index.js';
import {article,collection,searchResults} from '../src/help/render.js';
import data from '../src/help/content.json' with {type:'json'};
const env={ASSETS:{async fetch(req){
 const path=new URL(req.url).pathname;
 try{return new Response(await readFile(new URL('../public'+path,import.meta.url)),{headers:{'Content-Type':path.endsWith('.md')?'text/markdown':path.endsWith('.xml')?'application/xml':'text/html'}});}
 catch{return new Response('Missing',{status:404});}
}}};
const schemas=html=>[...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].flatMap(m=>{const j=JSON.parse(m[1]);return j['@graph']||[j];});
test('old support URLs permanently redirect to the canonical Help Center',async()=>{
 for(const path of ['/support','/support/','/support.html']){
  const r=await worker.fetch(new Request('https://oathwallet.org'+path+'?from=old'),env);
  assert.equal(r.status,308);assert.equal(r.headers.get('Location'),'https://help.oathwallet.org/?from=old');
 }
 const sitemap=await(await worker.fetch(new Request('https://oathwallet.org/sitemap.xml'),env)).text();
 assert.doesNotMatch(sitemap,/\/support|\/articles|articles\.oathwallet/);
 assert.equal([...sitemap.matchAll(/<loc>/g)].length,8);
});
test('article sitemap covers canonical editions with real modification dates and correct Markdown canonicals',async()=>{
 const sitemap=await(await handleArticleHost(new Request('https://articles.oathwallet.org/sitemap.xml'),env)).text();
 const urls=[...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map(m=>m[1]);
 const expected=['https://articles.oathwallet.org/',...Object.entries(articleRoutes).filter(([,v])=>typeof v==='string').map(([p])=>articleURL(p))];
 assert.deepEqual(urls,expected);assert.equal(new Set(urls).size,urls.length);
 assert.equal([...sitemap.matchAll(/<lastmod>/g)].length,urls.length);
 const markdown=await handleArticleHost(new Request('https://articles.oathwallet.org/index.md'),env);
 assert.equal(markdown.headers.get('Link'),'<https://articles.oathwallet.org/>; rel="canonical"');
 const oldMarkdown=await handleArticleHost(new Request('https://articles.oathwallet.org/articles.md'),env);
 assert.equal(oldMarkdown.status,308);
 assert.equal(oldMarkdown.headers.get('Location'),'https://articles.oathwallet.org/index.md');
});
test('Help Center structured data mirrors visible author, image and breadcrumb hierarchy',()=>{
 for(const a of data.articles){
  const html=article(data,a),nodes=schemas(html),post=nodes.find(n=>Array.isArray(n['@type'])&&n['@type'].includes('TechArticle'));
  assert.equal(post.headline,a.title);assert.equal(post.dateModified,a.updated_at);
  assert.equal(post.author.url,'https://oathwallet.org/about#editorial');
  assert.ok(html.includes('href="'+post.author.url+'"'));
  assert.ok(post.image.startsWith('https://help.oathwallet.org/help/assets/'));
  const trail=nodes.find(n=>n['@type']==='BreadcrumbList').itemListElement;
  assert.deepEqual(trail.map(x=>x.position),[1,2,3]);
  assert.equal(trail[2].item,post.mainEntityOfPage);
 }
 for(const c of data.categories)assert.ok(schemas(collection(data,c)).some(n=>n['@type']==='BreadcrumbList'));
 assert.match(searchResults(data,'backup'),/name="robots" content="noindex,follow"/);
});
test('article media and the published security reference remain reachable after the host move',async()=>{
 for(const path of ['/assets/articles/054e319a27e8-slide-to-send.mp4','/data/security-model.json']){
  const r=await handleArticleHost(new Request('https://articles.oathwallet.org'+path),env);
  assert.equal(r.status,200,path);
  assert.ok((await r.arrayBuffer()).byteLength>100,path);
 }
});
test('article migration does not confuse the og directory with a language or corrupt the archive image',async()=>{
 const image='https://oathwallet.org/og/articles.png';
 assert.equal(migrateArticleLinks(image),image);
 const imageResponse=await worker.fetch(new Request(image),env);
 assert.equal(imageResponse.status,200);
 assert.equal(imageResponse.headers.get('Location'),null);
 assert.equal(migrateArticleLinks(`<meta property="og:image" content="${image}">`),`<meta property="og:image" content="${image}">`);
 const html=await(await handleArticleHost(new Request('https://articles.oathwallet.org/'),env)).text();
 assert.ok(html.includes(`property="og:image" content="${image}"`));
 assert.ok(html.includes(`name="twitter:image" content="${image}"`));
});
test('Help sitemap has actual content dates and search noindex can be crawled',async()=>{
 const original=globalThis.fetch;globalThis.fetch=async()=>{throw Error('Use bundled data');};
 try{
  const xml=await(await handleHelp(new Request('https://help.oathwallet.org/sitemap.xml'),env)).text();
  assert.equal([...xml.matchAll(/<loc>/g)].length,data.articles.length+data.categories.length+1);
  for(const match of xml.matchAll(/<lastmod>([^<]+)<\/lastmod>/g))assert.ok(Number.isFinite(Date.parse(match[1])));
  const robots=await(await handleHelp(new Request('https://help.oathwallet.org/robots.txt'),env)).text();
  assert.doesNotMatch(robots,/Disallow:\s*\/search/);
 }finally{globalThis.fetch=original;}
});
test('homepage answers are crawlable, linked and preserved in the enhanced design',async()=>{
 const [html,questions]=await Promise.all([readFile(new URL('../public/index.html',import.meta.url),'utf8'),readFile(new URL('../content/self-custody-questions.json',import.meta.url),'utf8').then(JSON.parse)]);
 const readable=html.split('<!-- oath-server-content:start -->')[1].split('<!-- oath-server-content:end -->')[0];
 const designed=html.split('<!-- oath-self-custody:start -->')[1].split('<!-- oath-self-custody:end -->')[0];
 for(const q of questions){
  assert.ok(readable.includes(q.question));assert.ok(designed.includes(q.question));
  assert.ok(readable.includes('href="'+q.url+'"'));assert.ok(designed.includes('href="'+q.url+'"'));
 }
 assert.doesNotMatch(readable,/&lt;!--/);
 assert.equal((html.match(/<!-- oath-self-custody:start -->/g)||[]).length,1);
 const product=schemas(html).find(s=>s['@type']==='MobileApplication');
 assert.equal(product.aggregateRating.ratingCount,'38');assert.match(html,/38 US ratings/);
});
