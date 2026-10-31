// Read-only public requests. Never claims to be a verified crawler.
import assert from 'node:assert/strict';
const origin='https://oathwallet.org';
const request=async(url,options={})=>{
 const response=await fetch(url,{...options,headers:{'User-Agent':'OathDocumentationCheck/1.0 (+https://oathwallet.org/llms.txt)',...options.headers},signal:AbortSignal.timeout(30000)});
 assert.equal(response.status,200,`${url}: HTTP ${response.status}; ray=${response.headers.get('cf-ray')}`);return response;
};
const index=await(await request(origin+'/agent-documents.json')).json();
let completed=0;
// Bounded concurrency: verify every document, not an unbounded request burst.
const queue=[...index.documents];
await Promise.all(Array.from({length:4},async()=>{
 while(queue.length){const d=queue.shift();
  const md=await request(d.markdown_url),neg=await request(d.url,{headers:{Accept:'text/markdown'}});
  assert.match(md.headers.get('content-type'),/text\/markdown/);assert.match(neg.headers.get('vary'),/Accept/i);
  assert.equal(await md.text(),await neg.text(),d.url);
  const html=await request(d.url,{headers:{Accept:'text/html'}});assert.match(html.headers.get('content-type'),/text\/html/);assert.ok(html.headers.get('link')?.includes(d.markdown_url));completed++;
 }
}));
for(const host of ['oathwallet.org','help.oathwallet.org','articles.oathwallet.org']){
 // Reproduce the exact client family previously rejected with error 1010.
 await request(`https://${host}/llms.txt`,{headers:{'User-Agent':'Python-urllib/3.9'}});
}
const rpc=async(name,args={})=>(await(await request(origin+'/mcp',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}})})).json()).result;
assert.equal((await rpc('list_documents')).structuredContent.documents.length,index.documents.length);
assert.ok((await rpc('search_help',{query:'restore iCloud'})).structuredContent.results.some(x=>x.url.includes('restore')));
assert.match((await rpc('read_document',{url:origin+'/networks'})).structuredContent.text,/Bitcoin/);
assert.match((await rpc('get_download')).structuredContent.url,/apps.apple.com/);
assert.equal((await rpc('read_document',{url:'http://169.254.169.254/'})).isError,true);
console.log(`Passed ${completed} live documents (Markdown, negotiated Markdown, HTML); 3 default Python client probes; MCP recovery/network/download and URL restrictions.`);
