import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {runInNewContext} from 'node:vm';
import worker from '../src/index.js';
import {documents} from '../src/agent-content.js';
const root=new URL('../public/',import.meta.url);
const read=p=>readFile(new URL(p,root),'utf8');
const env={ASSETS:{async fetch(req){try{return new Response(await readFile(new URL('.'+new URL(req.url).pathname,root)));}catch{return new Response('Missing',{status:404});}}}};
test('bug bounty is reachable, discoverable and agrees with its published policy',async()=>{
 const r=await worker.fetch(new Request('https://oathwallet.org/bug-bounty'),env);
 assert.equal(r.status,200);const html=await r.text();
 assert.equal((html.match(/<h1\b/g)||[]).length,1);
 for(const [name,amount] of [['low','$0'],['medium','$250'],['high','$1,000'],['critical','$10,000']]){
  assert.ok(html.includes(`data-severity="${name}"`));assert.ok(html.includes(amount));
  assert.ok((await read('bug-bounty.md')).includes(amount));
 }
 for(const id of ['rewards','scope','rules','report','questions'])assert.ok(html.includes(`id="${id}"`));
 assert.match(html,/https:\/\/github.com\/devdasx\/oath-wallet\/security\/advisories\/new/);
 assert.doesNotMatch(html,/<form\b|<input\b|<textarea\b/,'never collect vulnerability contents in a public form');
 assert.ok((await read('sitemap.xml')).includes('https://oathwallet.org/bug-bounty</loc>'));
 assert.ok(documents.some(d=>d.url==='https://oathwallet.org/bug-bounty'));
 assert.ok((await read('.well-known/security.txt')).includes('Policy: https://oathwallet.org/bug-bounty'));
 for(const alias of ['/bug-bounty/','/bug-bounty.html']){
  const response=await worker.fetch(new Request('https://oathwallet.org'+alias),env);
  assert.equal(response.status,308);assert.equal(response.headers.get('Location'),'https://oathwallet.org/bug-bounty');
 }
 const md=await worker.fetch(new Request('https://oathwallet.org/bug-bounty',{headers:{Accept:'text/markdown'}}),env);
 assert.match(await md.text(),/Critical: \$10,000/);
 const image=await readFile(new URL('og/bug-bounty.png',root));assert.equal(image.readUInt32BE(16),1200);assert.equal(image.readUInt32BE(20),630);
});
test('report template copying succeeds or offers an accessible fallback without transmitting a report',async()=>{
 const source=await read('bug-bounty.js');let click;const details={open:false},status={textContent:''};let copied='';
 const template={textContent:await read('bug-bounty-report-template.txt'),closest:()=>details};
 const nodes={'copy-report':{addEventListener:(event,cb)=>{assert.equal(event,'click');click=cb;}},'report-template':template,'copy-status':status};
 const clipboard={writeText:async value=>{copied=value;}};
 runInNewContext(source,{document:{getElementById:id=>nodes[id]},navigator:{clipboard}});
 await click();assert.equal(copied,template.textContent);assert.match(status.textContent,/Template copied/);assert.equal(details.open,false);
 clipboard.writeText=async()=>{throw new Error('Permission denied');};await click();assert.equal(details.open,true);assert.match(status.textContent,/download/);
});
