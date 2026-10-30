const EDGE='https://rfjdenxkgjgepgbmxxkd.supabase.co/functions/v1/oath-newsletter';
const COOKIE='__Host-oath-news-admin';
const NEWS='news.oathwallet.org';
const json=(status,body)=>new Response(JSON.stringify(body),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
const cookieValue=request=>request.headers.get('Cookie')?.split(';').map(v=>v.trim()).find(v=>v.startsWith(COOKIE+'='))?.slice(COOKIE.length+1)||'';
export function newsletterSecurity(response){
 const r=new Response(response.body,response);r.headers.set('Cache-Control','no-store');r.headers.set('X-Robots-Tag','noindex, nofollow');r.headers.set('X-Content-Type-Options','nosniff');r.headers.set('X-Frame-Options','DENY');r.headers.set('Referrer-Policy','no-referrer');
 r.headers.set('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' https://oathwallet.org data:; font-src 'self'; connect-src 'self'; frame-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'");
 r.headers.set('Permissions-Policy','camera=(), microphone=(), geolocation=()');return r;
}
async function ipHash(request,env){
 const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(env.NEWSLETTER_GATEWAY_KEY||''),{name:'HMAC',hash:'SHA-256'},false,['sign']);
 return Array.from(new Uint8Array(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(request.headers.get('CF-Connecting-IP')||'local'))),v=>v.toString(16).padStart(2,'0')).join('');
}
export async function newsletterBackend(env,payload){
 if(!env.NEWSLETTER_GATEWAY_KEY)return json(503,{error:'The newsletter service is being set up. Please try again shortly.'});
 return fetch(EDGE,{method:'POST',headers:{'Content-Type':'application/json','X-Newsletter-Key':env.NEWSLETTER_GATEWAY_KEY},body:JSON.stringify(payload),signal:AbortSignal.timeout(payload.action?.includes('dispatch')?95000:25000)});
}
export async function newsletterScheduled(env){
 const r=await newsletterBackend(env,{action:'system.dispatch'});if(!r.ok)throw new Error('Newsletter dispatch failed: '+r.status);
 // Expired authentication tokens and rate-limit buckets have no retention value.
 if(new Date().getUTCMinutes()===0)await newsletterBackend(env,{action:'system.cleanup'});
}
export async function handleNewsletter(request,env){
 const url=new URL(request.url),isNews=url.hostname===NEWS;
 const local=['127.0.0.1','localhost'].includes(url.hostname);
 if(!isNews&&!local&&!url.pathname.startsWith('/_newsletter/'))return null;
 try{
  if(isNews&&url.protocol!=='https:'){url.protocol='https:';return Response.redirect(url.href,301);}
  if(isNews&&url.pathname.startsWith('/t/')){
   if(!['GET','HEAD'].includes(request.method))return newsletterSecurity(json(405,{error:'Method not allowed.'}));
   const match=/^\/t\/(open|click)\/([a-f0-9-]{36})$/.exec(url.pathname);
   if(!match)return newsletterSecurity(json(404,{error:'Invalid link.'}));
   if(env.VISITOR_LIMITER){const limit=await env.VISITOR_LIMITER.limit({key:'newsletter-engagement:'+(request.headers.get('CF-Connecting-IP')||'local')});if(!limit.success)return newsletterSecurity(json(429,{error:'Please try again shortly.'}));}
   const result=await newsletterBackend(env,{action:'public.engagement',kind:match[1],id:match[2],token:url.searchParams.get('token'),url:url.searchParams.get('url'),record:request.method==='GET'});
   if(!result.ok)return newsletterSecurity(json(result.status,{error:'This newsletter link is unavailable.'}));
   const data=await result.json();
   if(match[1]==='click'){
    const target=new URL(data.redirect);
    if(target.protocol!=='https:'||target.username||target.password)return newsletterSecurity(json(404,{error:'Invalid destination.'}));
    return newsletterSecurity(new Response(null,{status:302,headers:{Location:target.href}}));
   }
   const pixel=Uint8Array.from(atob('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7'),c=>c.charCodeAt(0));
   return newsletterSecurity(new Response(request.method==='HEAD'?null:pixel,{headers:{'Content-Type':'image/gif'}}));
  }
  // RFC 8058: mailbox providers POST the bearer link without cookies or an Origin.
  // GET only shows the preference page; scanners cannot unsubscribe by fetching it.
  if((isNews||local)&&url.pathname==='/unsubscribe'&&request.method==='POST'){
   if(Number(request.headers.get('Content-Length')||0)>512)return newsletterSecurity(json(413,{error:'Request too large.'}));
   const body=await request.text();
   if(body.length>512||new URLSearchParams(body).get('List-Unsubscribe')!=='One-Click')return newsletterSecurity(json(400,{error:'Invalid unsubscribe request.'}));
   const result=await newsletterBackend(env,{action:'public.unsubscribe',token:url.searchParams.get('token'),message_id:url.searchParams.get('message')});
   return newsletterSecurity(result);
  }
  const publicPrefix=url.pathname.startsWith('/_newsletter/');
  const apiPrefix=(isNews||local)&&url.pathname.startsWith('/api/');
  if(publicPrefix||apiPrefix){
   if(request.method!=='POST')return newsletterSecurity(json(405,{error:'Method not allowed.'}));
   const name=url.pathname.split('/').at(-1);
   const webhook=apiPrefix&&name==='webhook';
   const origin=request.headers.get('Origin');
   // Cookie-authenticated requests always require the exact origin, even for reads.
   if(!webhook&&origin!==url.origin)return newsletterSecurity(json(403,{error:'Request origin is not allowed.'}));
   if(!webhook&&!request.headers.get('Content-Type')?.includes('application/json'))return newsletterSecurity(json(415,{error:'JSON is required.'}));
   const contentLength=Number(request.headers.get('Content-Length')||0);if(contentLength>300000)return newsletterSecurity(json(413,{error:'Request too large.'}));
   if(['signup','login'].includes(name)&&env.NEWSLETTER_LIMITER){const limited=await env.NEWSLETTER_LIMITER.limit({key:name+':'+(request.headers.get('CF-Connecting-IP')||'local')});if(!limited.success)return newsletterSecurity(json(429,{error:'Too many attempts. Try again in a minute.'}));}
   const raw=await request.text();if(raw.length>300000)return newsletterSecurity(json(413,{error:'Request too large.'}));
   let p;try{p=JSON.parse(raw);}catch{return newsletterSecurity(json(400,{error:'Invalid request.'}));}
   const publics=new Set(['signup','confirm','preferences','updatePreferences','unsubscribe']);
   const admins=new Set(['login','logout','me','dashboard','subscribers','export','unsubscribeSubscriber','campaigns','campaign','saveCampaign','preview','test','send','cancel','dispatch','messages','retry']);
   let action;
   if(webhook)action='provider.webhook';
   else if(publicPrefix&&publics.has(name))action='public.'+name;
   else if(apiPrefix&&admins.has(name))action='admin.'+(name==='unsubscribeSubscriber'?'unsubscribe':name);
   else return newsletterSecurity(json(404,{error:'Not found.'}));
   const payload=webhook?{action,raw,headers:{'svix-id':request.headers.get('svix-id'),'svix-timestamp':request.headers.get('svix-timestamp'),'svix-signature':request.headers.get('svix-signature')}}:{...p,action,ipHash:await ipHash(request,env),sessionToken:cookieValue(request)};
   const result=await newsletterBackend(env,payload);let data;try{data=await result.json();}catch{return newsletterSecurity(json(503,{error:'Newsletter service unavailable.'}));}
   const token=data.sessionToken;delete data.sessionToken;
   const response=new Response(JSON.stringify(data),{status:result.status,headers:{'Content-Type':'application/json'}});
   if(action==='admin.login'&&result.ok&&token)response.headers.set('Set-Cookie',`${COOKIE}=${token}; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=28800`);
   if(action==='admin.logout')response.headers.set('Set-Cookie',`${COOKIE}=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0`);
   return newsletterSecurity(response);
  }
  if(isNews||(local&&['/admin','/confirm','/preferences','/newsletter-preview'].includes(url.pathname))){
   if(url.pathname==='/robots.txt')return newsletterSecurity(new Response('User-agent: *\nDisallow: /\n'));
   if(!['GET','HEAD'].includes(request.method))return newsletterSecurity(json(405,{error:'Method not allowed.'}));
   const paths={'/':'/news/index.html','/admin':'/news/admin.html','/admin/':'/news/admin.html','/confirm':'/news/preferences.html','/preferences':'/news/preferences.html','/unsubscribe':'/news/preferences.html','/newsletter-preview':'/news/index.html'};
   const mapped=paths[url.pathname];
   if(mapped){url.pathname=mapped;url.search='';return newsletterSecurity(await env.ASSETS.fetch(new Request(url,request)));}
   if(url.pathname.startsWith('/news/')||url.pathname==='/newsletter.js'||url.pathname==='/newsletter.css'||url.pathname.startsWith('/assets/brand/')||url.pathname==='/favicon.svg')return newsletterSecurity(await env.ASSETS.fetch(request));
   return newsletterSecurity(new Response('Page not found',{status:404}));
  }
  return null;
 }catch{return newsletterSecurity(json(503,{error:'The newsletter service is temporarily unavailable. Please try again.'}));}
}
