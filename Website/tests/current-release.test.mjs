import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {runInNewContext} from 'node:vm';
import {webcrypto} from 'node:crypto';
import evidence from '../content/release-evidence.json' with {type:'json'};
import guideSlugs from '../content/current-guide-slugs.json' with {type:'json'};
import {article} from '../src/help/render.js';
import help from '../src/help/content.json' with {type:'json'};
const read = p => readFile(new URL('../'+p,import.meta.url),'utf8');
const security = await read('public/security.html');
const data = JSON.parse(await read('public/oath-data.json'));
const source = security.match(/<script type="text\/x-dc" data-dc-script>([\s\S]*?)<\/script>/)[1];
function component(overrides={}) {
 const context={DCLogic:class {setState(patch){this.state={...this.state,...patch};}},setTimeout:()=>1,clearTimeout:()=>{},crypto:webcrypto,...overrides};
 runInNewContext(source+'\nglobalThis.subject=new Component();',context);
 return context.subject;
}
test('current source evidence agrees with the interactive code viewer and metadata',()=>{
 assert.equal(evidence.version,'5.0.2');assert.equal(evidence.build,104);
 assert.equal(data.security.reviewed_source_commit,evidence.source_commit);
 assert.equal(data.security.reviewed_on,evidence.reviewed_on);
 const files=JSON.parse(security.match(/const FILES = (\[[\s\S]*?\]);/)[1]);
 assert.deepEqual(files,evidence.files);assert.equal(files.length,6);
 for(const f of files){assert.ok(f.code.trim().length>60);assert.equal(f.code.trimEnd().split('\n').length <= f.end-f.start+1,true);assert.ok(f.start>0);}
 assert.ok(security.includes('const GH = "https://github.com/OathWallet/oath-wallet/blob/'+evidence.source_commit+'/"') || security.includes("const GH = 'https://github.com/OathWallet/oath-wallet/blob/"+evidence.source_commit+"/'"));
 assert.match(security,/November 5, 2026|5 November 2026/);
 assert.doesNotMatch(security,/4\.0\.0|580cf943|210,000|passkey-backed/);
});
test('current guides agree across article text, HTML, feeds and modification dates',async()=>{
 const feed=JSON.parse(await read('public/articles/feed.json'));
 for(const slug of guideSlugs){
  const [html,md]=await Promise.all([read('public/articles/'+slug+'.html'),read('public/articles/'+slug+'.md')]);
  const a=data.articles.find(a=>a.url.endsWith('/'+slug));const item=feed.items.find(a=>a.url.endsWith('/'+slug));
  assert.ok(a&&item,slug);assert.equal(item.title,a.title);assert.equal(item.date_modified,a.updated_at);
  assert.match(a.updated_at,/2026-11-02/);assert.match(html,/5\.0\.0/);assert.match(md,/5\.0\.0/);assert.match(item.content_html,/5\.0\.0/);
  assert.match(html,/Guide source version/);
  assert.ok(html.includes('ecb16953a5766471e1214eae6655cf783d0d062a'));
  assert.doesNotMatch(html,/580cf943|docs\/AUDIT_SCOPE\.md|4\.0\.0/,slug+' has no retired citations, including structured metadata');
  assert.ok(html.includes(a.reading_minutes+' min read'),slug+' reading time agrees with the listing');
 }
});
test('build-verification article feed matches the current article and release',async()=>{
 const slug='open-source-wallets-verifiable-builds';
 const html=await read('public/articles/'+slug+'.html');
 const feed=JSON.parse(await read('public/articles/feed.json'));
 const item=feed.items.find(a=>a.url.endsWith('/'+slug));
 const metadata=data.articles.find(a=>a.url.endsWith('/'+slug));
 assert.equal(item.date_modified,metadata.updated_at);
 assert.match(item.date_modified,/2026-11-05/);
 assert.equal(item.content_html,html.split('<div class="article-body">')[1].split('<div class="article-end">')[0].trim());
 assert.match(item.content_html,/5\.0\.2/);
 assert.doesNotMatch(item.content_html,/4\.1\.14|build 86/);
});
test('help release and historical screenshots keep separate versions',()=>{
 for(const article of help.articles){assert.equal(article.app_version,'Oath 5.0.0');assert.equal(article.screenshot_version,'Oath 4.0.3');assert.ok(!article.tags.some(t=>t.includes('4.0.3')));}
});
test('website version references omit review-status UI and distribution claims',async()=>{
 const copies=await Promise.all(['public/security.html','public/security.md','public/about.html','public/about.md','public/index.html','public/index.md','public/llms.txt','public/llms-full.txt','public/oath-data.json','public/agent-documents.json','public/articles/feed.json'].map(read));
 copies.push(article(help,help.articles[0]));
 for(const copy of copies){
  assert.doesNotMatch(copy,/Waiting for Review|App Store Connect listed|Version 4\.1\.2 is available|app-review-status/);
 }
 assert.equal(data.facts.source_version,'5.0.2 (104)');
 assert.equal(data.facts.app_version,'5.0.2');
 assert.equal(data.facts.app_build,104);
 assert.equal(data.facts.app_store_review_status,undefined);
 assert.equal(data.facts.app_store_version,undefined);
 assert.equal(data.security.source_correspondence.delivery_receipt,undefined);
});
test('copy reports success only after the clipboard accepts text',async()=>{
 let resolve;const pending=new Promise(r=>resolve=r);let copied;
 const subject=component({navigator:{clipboard:{writeText:text=>{copied=text;return pending;}}}});
 const task=subject.copy('public source','code');assert.equal(subject.state.copied,'');
 resolve();await task;assert.equal(copied,'public source');assert.equal(subject.state.copied,'code');assert.equal(subject.state.toast,'Copied');
 const denied=component({navigator:{clipboard:{writeText:async()=>{throw Error('denied');}}}});
 await denied.copy('public source','code');assert.equal(denied.state.copied,'');assert.match(denied.state.toast,/Could not copy/);
});
test('educational checksum uses real browser SHA-256 and never fabricates a result on failure',async()=>{
 const subject=component();await subject.run(true,12);
 const expected=Buffer.from(await webcrypto.subtle.digest('SHA-256',new Uint8Array(16)));
 assert.equal(Buffer.from(subject.state.hash).toString('hex'),expected.toString('hex'));
 const denied=component({crypto:{subtle:{digest:async()=>{throw Error('unavailable');}}}});
 await denied.run(true,12);assert.equal(denied.state.hash.length,0);assert.equal(denied.state.bytes.length,0);assert.equal(denied.state.step,0);assert.match(denied.state.toast,/unavailable/);
});
test('latest educational example wins when digest responses finish out of order',async()=>{
 const finish=[];const subject=component({crypto:{subtle:{digest:()=>new Promise(resolve=>finish.push(resolve))}}});
 const older=subject.run(true,12);const newer=subject.run(true,24);
 finish[1](new Uint8Array(32).fill(2));await newer;finish[0](new Uint8Array(32).fill(1));await older;
 assert.equal(subject.state.n,24);assert.ok(subject.state.hash.every(n=>n===2));
});
