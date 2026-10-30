import { equal, escapeHtml, NEWS_ORIGIN, uuid } from './core.ts';

type Kind = 'open' | 'click';
const encoder = new TextEncoder();
function safeTarget(value: unknown): string | null {
 if(typeof value!=='string'||value.length>4096)return null;
 try {
  const url=new URL(value);
  if(url.protocol!=='https:'||url.username||url.password)return null;
  return url.href;
 }catch{return null;}
}
async function sign(id:string,kind:Kind,target:string,secret:string){
 const key=await crypto.subtle.importKey('raw',encoder.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);
 const bytes=await crypto.subtle.sign('HMAC',key,encoder.encode(`oath-engagement-v1\n${kind}\n${id}\n${target}`));
 return Array.from(new Uint8Array(bytes),v=>v.toString(16).padStart(2,'0')).join('');
}
export async function engagementURL(id:string,kind:Kind,target:string,secret:string){
 if(!uuid.test(id))throw new Error('Invalid message');
 const canonical=kind==='click'?safeTarget(target):'';
 if(canonical===null)throw new Error('Invalid tracking destination');
 const url=new URL(`/t/${kind}/${id}`,NEWS_ORIGIN);
 if(kind==='click')url.searchParams.set('url',canonical);
 url.searchParams.set('token',await sign(id,kind,canonical,secret));
 return url.href;
}
export async function verifyEngagement(p:Record<string,unknown>,secret:string){
 if(typeof p.id!=='string'||!uuid.test(p.id)||(p.kind!=='open'&&p.kind!=='click')||typeof p.token!=='string'||!/^[a-f0-9]{64}$/.test(p.token))return null;
 const target=p.kind==='click'?safeTarget(p.url):'';
 if(target===null||!await equal(p.token,await sign(p.id,p.kind,target,secret)))return null;
 return {id:p.id,kind:p.kind,target,detail:p.kind==='click'?new URL(target).origin+new URL(target).pathname:'HTTPS image request'};
}
function excludeTarget(target:string){
 const u=new URL(target);
 // Never redirect or measure subscription-control and authentication links.
 return u.origin===NEWS_ORIGIN&&/^\/(?:preferences|unsubscribe|confirm|admin|t)(?:\/|$)/.test(u.pathname);
}
export async function trackBody(body:string,id:string,secret:string){
 const links=[...body.matchAll(/href="(https:\/\/[^"\s]+)"/g)];
 let result='',cursor=0;
 for(const link of links){
  const target=link[1].replaceAll('&amp;','&').replaceAll('&quot;','"').replaceAll('&#39;',"'").replaceAll('&lt;','<').replaceAll('&gt;','>');
  const safe=safeTarget(target);
  result+=body.slice(cursor,link.index);
  result+=safe&&!excludeTarget(safe)?`href="${escapeHtml(await engagementURL(id,'click',safe,secret))}"`:link[0];
  cursor=link.index!+link[0].length;
 }
 return result+body.slice(cursor);
}
export async function openPixel(id:string,secret:string){
 return `<img src="${escapeHtml(await engagementURL(id,'open','',secret))}" width="1" height="1" alt="" style="display:block;border:0;width:1px;height:1px" />`;
}
