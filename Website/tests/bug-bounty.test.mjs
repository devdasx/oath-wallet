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
 runInNewContext(source,{document:{getElementById:id=>nodes[id],querySelector:()=>null},navigator:{clipboard}});
 await click();assert.equal(copied,template.textContent);assert.match(status.textContent,/Template copied/);assert.equal(details.open,false);
 clipboard.writeText=async()=>{throw new Error('Permission denied');};await click();assert.equal(details.open,true);assert.match(status.textContent,/download/);
});

test('countdown uses the policy launch instant, rolls over and stops at launch',async()=>{
 const source=await read('bug-bounty.js');
 const policy=JSON.parse(await readFile(new URL('../content/bug-bounty.json',import.meta.url),'utf8'));
 const start=Date.parse(policy.startsAt);
 assert.equal(policy.startsAt,'2026-12-01T00:00:00Z');
 const html=await read('bug-bounty.html');
 assert.ok(html.includes(`data-bounty-start="${policy.startsAt}"`));
 assert.match(html,/December 1, 2026 · 00:00 UTC/);
 assert.match(await read('bug-bounty.md'),/Bounty program opens December 1, 2026/);
 let now=start-90061000,tick,cleared=false;
 const status={textContent:'Program opens'},time={hidden:false};
 const fields=Object.fromEntries(['days','hours','minutes','seconds'].map(x=>[x,{textContent:''}]));
 const timer={hidden:true,querySelector:selector=>fields[selector.match(/"(\w+)"/)[1]]};
 const launch={dataset:{bountyStart:policy.startsAt},querySelector:s=>s==='time'?time:timer};
 const context={document:{getElementById:id=>id==='bounty-launch-status'?status:null,querySelector:()=>launch},Date:{parse:Date.parse,now:()=>now},setInterval:fn=>{tick=fn;return 1;},clearInterval:id=>{assert.equal(id,1);cleared=true;}};
 runInNewContext(source,{...context});
 assert.deepEqual(Object.values(fields).map(x=>x.textContent),['01','01','01','01']);
 assert.equal(timer.hidden,false);
 now=start-1;tick();assert.deepEqual(Object.values(fields).map(x=>x.textContent),['00','00','00','01']);
 now=start;tick();assert.equal(timer.hidden,true);assert.equal(time.hidden,true);assert.equal(status.textContent,'Program is open');assert.equal(cleared,true);
 let scheduled=false;context.setInterval=()=>{scheduled=true;};now=start+86400000;
 runInNewContext(source,{...context});assert.equal(scheduled,false);assert.equal(status.textContent,'Program is open');
 launch.dataset.bountyStart='invalid';status.textContent='Program opens';
 runInNewContext(source,{...context});assert.equal(scheduled,false);assert.equal(status.textContent,'Program opens');
});
