import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {pathToFileURL} from 'node:url';
import {join} from 'node:path';
import worker from '../src/index.js';
import {indexNowHashes,submissionBatches} from '../scripts/indexnow-pages.mjs';
import {notifyIndexNow} from '../scripts/indexnow-notify.mjs';
import config from '../indexnow.json' with {type:'json'};
const env={ASSETS:{async fetch(req){
  try{return new Response(await readFile(new URL('../public'+new URL(req.url).pathname,import.meta.url)));}
  catch{return new Response('Missing',{status:404});}
}}};

test('each public host serves Bing, Yandex and IndexNow ownership files without page transformations',async()=>{
  for(const host of config.hosts)for(const path of ['/BingSiteAuth.xml','/yandex_c0e2f76d0a57a2e5.html', '/yandex_650043df6dfe689a.html', '/yandex_cc4674c827ce2f19.html',`/${config.key}.txt`]){
    const url=`https://${host}${path}`;
    const response=await worker.fetch(new Request(url),env);
    assert.equal(response.status,200);
    assert.match(response.headers.get('X-Robots-Tag'),/noindex/);
    if(path.endsWith('.html')) assert.equal(response.headers.get('Content-Type'),'text/html; charset=utf-8');
    assert.equal(await response.text(),await readFile(new URL('../public'+path,import.meta.url),'utf8'));
    const head=await worker.fetch(new Request(url,{method:'HEAD'}),env);
    assert.equal(head.status,200);assert.equal(await head.text(),'');
    assert.equal((await worker.fetch(new Request(url,{method:'POST'}),env)).status,405);
    assert.equal((await worker.fetch(new Request(url.replace('https:','http:')),env)).status,301);
  }
  assert.equal((await worker.fetch(new Request('https://help.oathwallet.org/not-a-verification-key.txt'),env)).status,404);
});

test('all three published inventories participate; unchanged pages are skipped',async()=>{
  const hashes=await indexNowHashes();
  const counts=Object.groupBy(Object.keys(hashes),u=>new URL(u).hostname);
  assert.ok(counts['oathwallet.org'].length>37000);
  assert.ok(counts['help.oathwallet.org'].length>100);
  assert.ok(counts['articles.oathwallet.org'].length>30);
  assert.ok(hashes['https://oathwallet.org/tokens/usdt/tron']);
  assert.ok(hashes['https://help.oathwallet.org/articles/revoke-token-access']);
  assert.ok(Object.keys(hashes).every(u=>!u.endsWith('.md')&&!u.includes('/search?')&&!/^\/wc(?:\/|$)/.test(new URL(u).pathname)));
  const plan=submissionBatches(hashes,{},config.hosts);
  assert.equal(plan.changed,Object.keys(hashes).length);
  assert.equal(new Set(plan.batches.flatMap(b=>b.urlList)).size,plan.changed);
  for(const batch of plan.batches){assert.ok(batch.urlList.length<=10000);assert.ok(batch.urlList.every(u=>new URL(u).hostname===batch.host));}
  assert.deepEqual(submissionBatches(hashes,hashes,config.hosts),{changed:0,removed:0,batches:[]});
});

test('removed URLs stay assigned to their own host; invalid hosts are rejected',()=>{
  const before={'https://help.oathwallet.org/removed':'old','https://oathwallet.org/':'same'};
  const after={'https://oathwallet.org/':'same','https://articles.oathwallet.org/new':'new'};
  const plan=submissionBatches(after,before,config.hosts);
  assert.equal(plan.changed,1);assert.equal(plan.removed,1);
  assert.deepEqual(plan.batches.map(b=>b.host),['help.oathwallet.org','articles.oathwallet.org']);
  for(const url of ['https://other.example/','http://oathwallet.org/','https://oathwallet.org/#private'])assert.throws(()=>submissionBatches({[url]:'hash'},{},config.hosts));
});

test('failed ownership and rejected batches preserve the last successful notification state',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'oath-indexnow-'));const stateDir=pathToFileURL(dir+'/');
  const stateFile=new URL('indexnow-hashes.json',stateDir),before={'https://oathwallet.org/':'old'};
  const hashes={'https://oathwallet.org/':'new','https://help.oathwallet.org/':'new'};
  const plan=submissionBatches(hashes,before,config.hosts);
  try{
    await writeFile(stateFile,JSON.stringify(before));
    let posts=0;
    await assert.rejects(notifyIndexNow({config,hashes,...plan,stateDir,fetchImpl:async(_url,options)=>{
      if(options.method)posts++;return new Response('wrong');
    }}),/ownership/);
    assert.equal(posts,0);
    await assert.rejects(notifyIndexNow({config,hashes,...plan,stateDir,fetchImpl:async(_url,options)=>{
      if(!options.method)return new Response(config.key);
      posts++;return new Response('',{status:posts===1?200:429});
    }}),/429/);
    assert.deepEqual(JSON.parse(await readFile(stateFile)),before);
    posts=0;
    const results=await notifyIndexNow({config,hashes,...plan,stateDir,fetchImpl:async(_url,options)=>{
      if(!options.method)return new Response(config.key);
      const body=JSON.parse(options.body);assert.ok(body.urlList.every(u=>new URL(u).hostname===body.host));
      posts++;return new Response('',{status:posts===1?200:202});
    }});
    assert.deepEqual(results.map(r=>r.status),[200,202]);
    assert.deepEqual(JSON.parse(await readFile(stateFile)),hashes);
  }finally{await rm(dir,{recursive:true,force:true});}
});
