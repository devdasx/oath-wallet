import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import worker from '../src/index.js';
import {documents,documentText,guide,wantsMarkdown} from '../src/agent-content.js';
import help from '../src/help/content.json' with {type:'json'};
const env={ASSETS:{async fetch(req){const path=new URL(req.url).pathname;try{return new Response(await readFile(new URL('../public'+path,import.meta.url)),{headers:{'Content-Type':path.endsWith('.html')?'text/html':path.endsWith('.md')?'text/markdown':'text/plain'}});}catch{return new Response(null,{status:404});}}}};
const call=async(name,args={})=>(await(await worker.fetch(new Request('https://oathwallet.org/mcp',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}})}),env)).json()).result;
test('every document supports discoverable HTML and identical explicit/negotiated Markdown',async()=>{
 for(const d of documents){
  const md=await worker.fetch(new Request(d.markdown_url),env), negotiated=await worker.fetch(new Request(d.url,{headers:{Accept:'text/markdown'}}),env),html=await worker.fetch(new Request(d.url),env);
  assert.equal(md.status,200,d.url);assert.equal(negotiated.status,200,d.url);assert.equal(html.status,200,d.url);
  assert.equal(await md.text(),await negotiated.text(),d.url);assert.match(md.headers.get('Content-Type'),/text\/markdown/);
  assert.match(negotiated.headers.get('Vary'),/Accept/);assert.match(html.headers.get('Vary'),/Accept/);assert.ok(html.headers.get('Link').includes(d.markdown_url));
  const head=await worker.fetch(new Request(d.url,{method:'HEAD',headers:{Accept:'text/markdown'}}),env);assert.equal(await head.text(),'');assert.match(head.headers.get('Content-Type'),/markdown/);
 }
});
test('all help words, steps and version scope use the HTML content source',async()=>{
 for(const a of help.articles){const d=documents.find(d=>d.kind==='help'&&d.id===a.slug),text=await documentText(d,env);for(const s of [a.title,a.summary,...a.steps,...a.body,a.note,a.app_version,a.updated_at])assert.ok(text.includes(s),a.slug);}
});
test('generated guides, full text and index cannot silently become stale',async()=>{
 assert.equal(await readFile(new URL('../public/llms.txt',import.meta.url),'utf8'),guide('https://oathwallet.org'));
 const full=await readFile(new URL('../public/llms-full.txt',import.meta.url),'utf8');assert.doesNotMatch(full,/Editorial article: historical statements describe their publication context/);for(const d of documents)assert.ok(full.includes(await documentText(d,env)),d.url);
 const index=JSON.parse(await readFile(new URL('../public/agent-documents.json',import.meta.url),'utf8'));assert.equal(index.documents.length,documents.length);
});
test('MCP finds recovery guides, networks and the official download',async()=>{
 const r=await call('search_help',{query:'restore iCloud'});assert.ok(r.structuredContent.results.some(x=>x.url.includes('restore')));for(const x of r.structuredContent.results){assert.ok(x.updated_at);assert.ok(x.app_version);assert.ok(x.excerpt);}
 assert.equal((await call('list_documents')).structuredContent.documents.length,documents.length);
 assert.match((await call('read_document',{url:'https://oathwallet.org/networks'})).structuredContent.text,/Bitcoin/);
 assert.equal((await call('read_document',{url:'http://169.254.169.254/'})).isError,true);
 assert.match((await call('get_download')).structuredContent.url,/apps.apple.com/);
});
test('Accept preferences preserve browsers and q=0',()=>{
 for(const a of ['', '*/*','text/html,text/markdown;q=0.2','text/markdown;q=0','text/html,text/markdown'])assert.equal(wantsMarkdown(a),false,a);
 assert.equal(wantsMarkdown('text/markdown, text/html;q=0.5'),true);
});
test('private routes, redirects and cross-origin MCP protections remain intact',async()=>{
 assert.equal((await worker.fetch(new Request('https://oathwallet.org/mcp',{method:'POST',headers:{Origin:'https://evil.invalid','Content-Type':'application/json'},body:'{}'}),env)).status,403);
 assert.equal((await worker.fetch(new Request('https://help.oathwallet.org/admin.md',{headers:{Accept:'text/markdown'}}),env)).status,404);
 assert.equal((await worker.fetch(new Request('http://help.oathwallet.org/articles/create-wallet',{headers:{Accept:'text/markdown'}}),env)).status,301);
 assert.match((await worker.fetch(new Request('https://oathwallet.org/wc',{headers:{Accept:'text/markdown'}}),env)).headers.get('X-Robots-Tag'),/noindex/);
 for(const host of ['oathwallet.org','help.oathwallet.org','articles.oathwallet.org'])assert.equal((await worker.fetch(new Request(`https://${host}/llms.txt`),env)).status,200);
});
