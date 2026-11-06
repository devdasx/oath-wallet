import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import migrations from '../content/wallet-migrations.json' with {type:'json'};
import evidence from '../Reports/wallet-migrations/compatibility.json' with {type:'json'};
const root=new URL('../../',import.meta.url);
const read=p=>readFile(new URL(p,root),'utf8');
test('migration scope is tied to the distributed release and exact reviewed source',async()=>{
 const distribution=JSON.parse(await read('releases/'+migrations.version+'-distribution.json'));
 assert.equal(distribution.source_commit,migrations.sourceCommit);
 assert.equal(evidence.sourceCommit,migrations.sourceCommit);
 assert.equal(evidence.version,migrations.version);
 assert.equal(evidence.build,migrations.build);
 assert.equal(evidence.checks.length,18);
 for(const source of evidence.sources){
  const pinned=execFileSync('git',['show',migrations.sourceCommit+':'+source.path],{cwd:root});
  assert.equal(createHash('sha256').update(pinned).digest('hex'),source.sha256,source.path);
 }
});
test('every migration guide is discoverable from both features views and retains its evidence and scope',async()=>{
 const hub=await read('Website/public/features.html'), markdown=await read('Website/public/features.md');
 const fallback=hub.match(/<!-- oath-server-content:start -->([\s\S]*?)<!-- oath-server-content:end -->/)[1];
 const styleHash=createHash('sha256').update(await read('Website/public/article.css')).digest('hex').slice(0,12);
 for(const guide of migrations.guides){
  const url='https://articles.oathwallet.org/'+guide.slug;
  const body=await read('Website/content/articles/'+guide.slug+'/article.md');
  const html=await read('Website/public/articles/'+guide.slug+'.html');
  assert.ok(hub.includes('href="'+url+'"'),guide.slug);
  assert.ok(markdown.includes(']('+url+')'),guide.slug);
  assert.ok(fallback.includes(url),guide.slug);
  assert.ok(html.includes('/article.css?v='+styleHash),'Updated table styling must invalidate cached CSS');
  assert.ok(html.includes('role="region" aria-label="Article table" tabindex="0"'),'Overflowing tables need keyboard access');
  assert.ok(body.includes(migrations.sourceCommit));
  assert.ok(body.includes('## What we verified'));
  assert.ok(body.includes('5.0.2 (104)'));
  assert.ok(!/<(?:input|textarea|iframe)\b/i.test(html),'Recovery guide must not collect recovery material');
  assert.ok(!body.includes('abandon abandon'),'Public test recovery material belongs in test fixtures, not user instructions');
 }
});
