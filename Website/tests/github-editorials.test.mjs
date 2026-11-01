import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile, readdir} from 'node:fs/promises';
import {articleRoutes} from '../src/article-routes.js';
import published from '../public/oath-data.json' with {type:'json'};
import feed from '../public/articles/feed.json' with {type:'json'};
import {renderMarkdown} from '../scripts/markdown.mjs';

const root = new URL('../',import.meta.url);
const read = path => readFile(new URL(path,root),'utf8');
test('each GitHub article is built from source with matching routes, metadata, media, feeds and mirrors', async()=>{
  const dirs = (await readdir(new URL('content/articles/',root),{withFileTypes:true})).filter(d=>d.isDirectory());
  assert.equal(published.articles.filter(a=>a.github_editorial).length,dirs.length);
  const rss = await read('public/articles/feed.xml');
  for (const {name} of dirs) {
    const input = 'content/articles/'+name+'/';
    const meta = JSON.parse(await read(input+'metadata.json'));
    const url = 'https://articles.oathwallet.org/'+name;
    assert.equal(articleRoutes['/articles/'+name],'/articles/'+name+'.html');
    const row = published.articles.find(a=>a.url===url);
    assert.equal(row.title,meta.title);
    assert.equal(row.excerpt,meta.excerpt);
    const html = await read('public/articles/'+name+'.html');
    const mirror = await read('public/articles/'+name+'.md');
    const post = JSON.parse(html.match(/<script type="application\/ld\+json">(.*?)<\/script>/s)[1]);
    assert.equal(post.headline,meta.title);
    assert.equal(post.mainEntityOfPage,url);
    assert.equal(post.sameAs,meta.original_url);
    assert.ok(mirror.startsWith('# '+meta.title+'\n'));
    const items = feed.items.filter(i=>i.id===url);
    assert.equal(items.length,1);
    assert.ok(rss.includes('<link>'+url+'</link>'));
    const images = [...(await read(input+'article.md')).matchAll(/^!\[([^\]]+)\]\(([^)]+)\)$/gm)];
    for (const filename of [meta.cover,...images.map(match=>match[2])]) {
      const path = 'assets/articles/editorials/'+name+'/'+filename;
      assert.ok(html.includes('https://articles.oathwallet.org/'+path));
      assert.deepEqual(await readFile(new URL('public/'+path,root)),await readFile(new URL(input+filename,root)));
    }
    for (const [,alt] of images) assert.ok(mirror.includes('!['+alt+'](https://articles.oathwallet.org/'));
  }
});
test('the article renderer escapes raw HTML and rejects executable link schemes',()=>{
  const html=renderMarkdown('<script>alert(1)</script>\n\n[link](javascript:alert)');
  assert.ok(html.includes('&lt;script&gt;'));
  assert.ok(!html.includes('href='));
});
