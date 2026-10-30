import { engagementURL, verifyEngagement, trackBody, openPixel } from './tracking.ts';
import { markdown } from './core.ts';
const id='f877906c-e2df-4e86-9230-834583631e75';
const assert=(v:unknown)=>{if(!v)throw new Error('Assertion failed');};
function request(url:string){const u=new URL(url);return {id,kind:u.pathname.split('/')[2],token:u.searchParams.get('token'),url:u.searchParams.get('url')};}
Deno.test('engagement signatures bind the message, event kind and entire HTTPS destination',async()=>{
 const p=request(await engagementURL(id,'click','https://oathwallet.org/articles?a=1&b=2','secret'));
 assert((await verifyEngagement(p,'secret'))?.target==='https://oathwallet.org/articles?a=1&b=2');
 assert(await verifyEngagement({...p,url:'https://evil.example/'},'secret')===null);
 assert(await verifyEngagement({...p,id:'a877906c-e2df-4e86-9230-834583631e75'},'secret')===null);
 assert(await verifyEngagement({...p,kind:'open'},'secret')===null);
 assert(await verifyEngagement(p,'wrong')===null);
 for(const target of ['javascript:alert(1)','http://oathwallet.org','https://user:pass@oathwallet.org','x'.repeat(5000)]){
  let rejected=false;try{await engagementURL(id,'click',target,'secret');}catch{rejected=true;}assert(rejected);
 }
});
Deno.test('tracked content preserves queries and excludes subscription control links',async()=>{
 const body=markdown('[Read](https://oathwallet.org/articles?a=1&b=2)\n\n[Preferences](https://news.oathwallet.org/preferences?token=private)');
 const tracked=await trackBody(body,id,'secret');
 const href=[...tracked.matchAll(/href="([^"]+)"/g)].map(m=>m[1].replaceAll('&amp;','&'));
 const p=request(href[0]);assert((await verifyEngagement(p,'secret'))?.target==='https://oathwallet.org/articles?a=1&b=2');
 assert(href[1]==='https://news.oathwallet.org/preferences?token=private');
 assert(!tracked.includes('email='));
 const pixel=await openPixel(id,'secret');assert(pixel.includes('https://news.oathwallet.org/t/open/'));assert(pixel.includes('width="1"'));
 const src=/src="([^"]+)"/.exec(pixel)![1].replaceAll('&amp;','&');
 assert((await verifyEngagement(request(src),'secret'))?.kind==='open');
});
