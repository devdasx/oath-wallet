import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import worker from '../src/index.js';
const env={ASSETS:{async fetch(req){
  try{return new Response(await readFile(new URL('../public'+new URL(req.url).pathname,import.meta.url)));}
  catch{return new Response('Missing',{status:404});}
}}};
for(const host of ['oathwallet.org','help.oathwallet.org','articles.oathwallet.org']) {
  test(`${host} explicitly permits search and user retrieval with a host sitemap`,async()=>{
    const response=await worker.fetch(new Request(`https://${host}/robots.txt`),env);
    assert.equal(response.status,200);
    assert.match(response.headers.get('Content-Type'),/^text\/plain/);
    const body=await response.text();
    for(const agent of ['OAI-SearchBot','ChatGPT-User','*']) {
      assert.ok(body.includes(`User-agent: ${agent}\nAllow: /\n`));
    }
    assert.ok(body.includes(`Sitemap: https://${host}/sitemap.xml`));
    assert.doesNotMatch(body,/^Disallow:\s*\//m);
    assert.doesNotMatch(response.headers.get('X-Robots-Tag')||'',/noindex/);
  });
}
test('training permission remains unchanged and separate from search',async()=>{
  const text=await readFile(new URL('../public/robots.txt',import.meta.url),'utf8');
  assert.match(text,/User-agent: GPTBot\nAllow: \/\n/);
});
test('article crawler reading-guide request resolves to the existing public guide',async()=>{
  const response=await worker.fetch(new Request('https://articles.oathwallet.org/llms.txt'),env);
  assert.equal(response.status,308);
  assert.equal(response.headers.get('Location'),'https://oathwallet.org/llms.txt');
});
test('sensitive wallet-link routes retain noindex despite public crawl permission',async()=>{
  const response=await worker.fetch(new Request('https://oathwallet.org/wc'),env);
  assert.match(response.headers.get('X-Robots-Tag'),/noindex/);
});
