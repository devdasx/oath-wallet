import test from 'node:test';
import assert from 'node:assert/strict';
import {webcrypto} from 'node:crypto';
import {classifyAgent,eventMetadata,visitorID,handleAnalytics} from '../src/analytics.js';
if(!globalThis.crypto)globalThis.crypto=webcrypto;
const id='00000000-0000-4000-8000-000000000001';
const body={id,session:id,kind:'page_view',path:'/privacy?secret=never',referrer:'https://google.com/search?q=private'};
test('metadata uses edge geo, strips query and referrer path, coarsens coordinates',()=>{
 const req=new Request('https://oathwallet.org/_events',{headers:{'user-agent':'Mozilla iPhone Mobile Safari'}});
 req.cf={country:'JO',city:'Amman',latitude:'31.9539',longitude:'35.9106'};
 const event=eventMetadata({...body,country:'US'},req,id);
 assert.equal(event.country,'JO');assert.equal(event.latitude,32);assert.equal(event.longitude,35.9);
 assert.equal(event.path,'/privacy');assert.equal(event.referrer,'google.com');assert.equal(event.device,'Mobile');
 assert.ok(!('ip' in event));assert.ok(!('userAgent' in event));
});
test('rejects off-site pages and invalid ids',()=>{
 const req=new Request('https://oathwallet.org');
 assert.equal(eventMetadata({...body,path:'https://evil.com'},req,id),null);
 assert.equal(eventMetadata({...body,id:'wrong'},req,id),null);
 assert.equal(eventMetadata({...body,kind:'gps'},req,id),null);
});
test('invalid visitor cookie cannot forge an existing browser identity',async()=>{
 const result=await visitorID(`__Host-oath_visitor=${id}.forged`,'test-key');
 assert.equal(result.fresh,true);assert.notEqual(result.id,id);
});
test('privacy signals and bots are excluded without touching upstream',async()=>{
 for(const extra of [{'sec-gpc':'1'},{dnt:'1'},{'user-agent':'Googlebot'}]){
  const req=new Request('https://oathwallet.org/_events',{method:'POST',headers:{origin:'https://oathwallet.org',...extra},body:'{}'});
  assert.equal((await handleAnalytics(req,{})).status,202);
 }
});
test('cross-site injection and malformed payloads rejected',async()=>{
 assert.equal((await handleAnalytics(new Request('https://oathwallet.org/_events',{method:'POST'}),{})).status,403);
 assert.equal((await handleAnalytics(new Request('https://oathwallet.org/_events',{method:'POST',headers:{origin:'https://oathwallet.org'},body:'bad'}),{WEBSITE_ANALYTICS_KEY:'test'})).status,400);
});
test('browser and platform are coarse categories',()=>{
 assert.deepEqual(classifyAgent('Mozilla Macintosh Chrome/123 Edg/123'),{browser:'Edge',os:'macOS',device:'Desktop'});
});
