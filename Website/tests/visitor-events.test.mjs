import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import {setImmediate} from 'node:timers/promises';

const source=await readFile(new URL('../public/visitor-events.js',import.meta.url),'utf8');
function browser({privacy=false,retry=false,userAgent='Mozilla/5.0 Chrome/145.0.0.0 Safari/537.36'}={}) {
  const listeners={},stored=new Map(),sent=[];
  let sequence=0;
  const context=vm.createContext({
    URL,Date,Promise,JSON,window:{},
    location:{hostname:'oathwallet.org',pathname:'/articles/backup-restore-oath-wallet'},
    navigator:{globalPrivacyControl:privacy,userAgent},
    document:{referrer:'https://www.google.com/',visibilityState:'visible',addEventListener:(type,handler)=>{listeners[type]=handler;}},
    sessionStorage:{getItem:key=>stored.get(key),setItem:(key,value)=>stored.set(key,value)},
    crypto:{randomUUID:()=>`00000000-0000-4000-8000-${String(++sequence).padStart(12,'0')}`},
    fetch:async (url,options)=>{sent.push({url,payload:JSON.parse(options.body)});return {status:retry&&sent.length===1?503:200};},
    setTimeout:callback=>callback()
  });
  vm.runInContext(source,context);
  return {context,sent,listeners,stored,createdIDs:()=>sequence};
}
test('outbound measurement records only the official store action and does not mistake reviews for downloads',async()=>{
  const b=browser();
  for(const href of ['https://apps.apple.com/app/id6780187283?see-all=reviews','https://example.com/','https://apps.apple.com/app/id6780187283']) {
    b.listeners.click({target:{closest:()=>({href})}});
  }
  await setImmediate();
  assert.deepEqual(b.sent.map(s=>s.payload.kind),['page_view','download']);
  assert.equal(b.sent[0].payload.session,b.sent[1].payload.session);
  assert.equal(b.sent[1].payload.path,'/articles/backup-restore-oath-wallet');
});
test('loading measurement twice does not duplicate a view; a retry reuses the same event identity',async()=>{
  const b=browser({retry:true});
  vm.runInContext(source,b.context);
  await setImmediate();
  assert.equal(b.sent.length,2);
  assert.equal(b.sent[0].payload.id,b.sent[1].payload.id);
  assert.equal(b.sent[0].payload.kind,'page_view');
});
test('privacy opt-out prevents both page and click measurement',async()=>{
  const b=browser({privacy:true});await setImmediate();
  assert.equal(b.sent.length,0);assert.equal(b.listeners.click,undefined);
});
test('crawler rendering creates no session, listeners, identifiers or analytics requests',async()=>{
  for(const userAgent of [
    'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)',
    'Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Mobile Safari/537.36 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)',
    'Mozilla/5.0 (compatible; Google-InspectionTool/1.0;)',
    'Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)',
    'Mozilla/5.0 Applebot/0.1',
    'Mozilla/5.0 HeadlessChrome/145.0.0.0 Safari/537.36'
  ]) {
    const b=browser({userAgent});await setImmediate();
    assert.equal(b.sent.length,0,userAgent);
    assert.equal(b.stored.size,0,userAgent);
    assert.equal(b.createdIDs(),0,userAgent);
    assert.deepEqual(Object.keys(b.listeners),[],userAgent);
  }
});
