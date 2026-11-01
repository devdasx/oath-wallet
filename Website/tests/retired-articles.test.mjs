import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile, access} from 'node:fs/promises';
import worker from '../src/index.js';
import retired from '../content/retired-articles.json' with {type:'json'};
import {documents} from '../src/agent-content.js';
import {articleRoutes} from '../src/article-routes.js';
const root = new URL('../public/', import.meta.url);
const env = {ASSETS:{async fetch(req) {
  try { return new Response(await readFile(new URL('.'+new URL(req.url).pathname, root)), {headers:{'Content-Type':'text/html'}}); }
  catch { return new Response('Missing', {status:404}); }
}}};

test('retired articles and aliases cannot be served through HTML, Markdown or legacy URLs', async () => {
  assert.equal(retired.articles.length, 11);
  const noAssets = {ASSETS:{fetch() { throw new Error('Retired requests must not reach assets'); }}};
  for (const a of retired.articles) {
    for (const extension of ['html','md']) await assert.rejects(access(new URL(`articles/${a.slug}.${extension}`, root)));
    for (const slug of [a.slug,...a.aliases]) {
      for (const origin of ['https://oathwallet.org/articles/','https://www.oathwallet.org/articles/','https://articles.oathwallet.org/','https://articles.oathwallet.org/articles/']) {
        for (const suffix of ['', '/', '.html', '.md']) {
          for (const method of ['GET','HEAD']) {
            const response = await worker.fetch(new Request(origin+slug+suffix+'?from=old', {method,headers:{Accept:'text/markdown'}}), noAssets);
            assert.equal(response.status,410,origin+slug+suffix);
            assert.equal(response.headers.get('X-Robots-Tag'),'noindex');
            if (method === 'HEAD') assert.equal(await response.text(),'');
          }
        }
      }
      assert.ok(!Object.keys(articleRoutes).some(p=>p.endsWith('/'+slug)));
      assert.ok(!documents.some(d=>d.url.endsWith('/'+slug)));
      for (const file of ['articles.html','articles.md','oath-data.json','articles/feed.json','articles/feed.xml','articles/sitemap.xml','llms.txt','llms-full.txt','agent-documents.json']) {
        assert.ok(!(await readFile(new URL(file,root),'utf8')).includes(slug),file+': '+slug);
      }
    }
  }
});

test('every retained article renders without the removed editorial notice',async()=>{
  for (const d of documents.filter(d=>d.kind==='article')) {
    const r=await worker.fetch(new Request(d.url),env);
    assert.equal(r.status,200,d.url);
    const html=await r.text();
    assert.doesNotMatch(html,/This is an editorial or release article|For instructions matching the current Oath Atmosphere app/);
    assert.doesNotMatch(html,/<div class="related-grid">\s*<\/div>/);
  }
});
