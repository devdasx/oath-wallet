import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import worker from '../src/index.js';
import {articleURL} from '../src/article-host.js';
import {articleRoutes} from '../src/article-routes.js';
const publicURL=new URL('../public/',import.meta.url);
const env={ASSETS:{async fetch(req){try {return new Response(await readFile(new URL('.'+new URL(req.url).pathname,publicURL)),{headers:{'Content-Type':'text/html'}})} catch{return new Response('Missing',{status:404})}}}};
const request=path=>worker.fetch(new Request('https://oathwallet.org'+path),env);
test('all published editions have clean routes, metadata, and only Oath branding',async()=>{
 const paths=Object.entries(articleRoutes).filter(([,v])=>typeof v==='string');assert.ok(paths.length >= 30);
 for(const [path] of paths){
  const moved=await request(path);assert.equal(moved.status,308);
  const response=await worker.fetch(new Request(articleURL(path)),env);assert.equal(response.status,200,path);const html=await response.text();
  assert.ok(html.includes(`rel="canonical" href="${articleURL(path)}"`),path);
  assert.ok(html.includes('<div class="article-body">'),path);
  const body=html.split('<div class="article-body">')[1].split('</article>')[0];
  assert.ok(body.replace(/<[^>]+>/g,'').trim().length>300,path+' has substantial article content');
  assert.doesNotMatch(html,/\baperture\b/i,path);
  assert.doesNotMatch(html,/aperturex\.io|href="\/(?!\/)[^"#?]*\.html(?:["?#])/,path);
  assert.ok(html.includes('hreflang="x-default"'),path);
  for(const variant of [path+'/',path+'.html']){const r=await request(variant+'?from=old');assert.equal(r.status,308);assert.equal(r.headers.get('location'),articleURL(path)+'?from=old');}
 }
});
test('old branded article slugs redirect to Oath and unknown pages remain 404',async()=>{
 for(const [path,v] of Object.entries(articleRoutes).filter(([,v])=>typeof v==='object')){
  for(const suffix of ['','/','.html']){const r=await request(path+suffix);assert.equal(r.status,308);assert.equal(r.headers.get('location'),articleURL(v.redirect));}
 }
 assert.equal((await worker.fetch(new Request('https://articles.oathwallet.org/not-a-real-article'),env)).status,404);
});
test('index, sitemap, feeds and MCP include the migrated archive',async()=>{
 const data=JSON.parse(await readFile(new URL('oath-data.json',publicURL)));assert.equal(data.articles.length,Object.values(articleRoutes).filter(route=>typeof route==='string').length);
 const sitemap=await (await worker.fetch(new Request('https://articles.oathwallet.org/sitemap.xml'),env)).text();const index=await readFile(new URL('articles.html',publicURL),'utf8');
 for(const a of data.articles){const url=new URL(a.url).hostname==='articles.oathwallet.org'?a.url:articleURL(new URL(a.url).pathname);assert.ok(sitemap.includes(url));if(a.locale==='en')assert.ok(index.includes(a.url));}
 const feed=JSON.parse(await readFile(new URL('articles/feed.json',publicURL)));assert.equal(feed.items.length,data.articles.filter(a=>a.locale==='en').length);
 const response=await worker.fetch(new Request('https://oathwallet.org/mcp',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'list_articles'}})}),env);
 assert.equal((await response.json()).result.structuredContent.articles.length,data.articles.length);
});
