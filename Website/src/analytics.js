const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const cookieName = '__Host-oath_visitor';
const bot = /bot|crawler|spider|headless|preview|facebookexternalhit|curl|wget/i;
export function classifyAgent(ua = '') {
  return { browser: /Edg\//.test(ua) ? 'Edge' : /Firefox|FxiOS/.test(ua) ? 'Firefox' : /Chrome|CriOS/.test(ua) ? 'Chrome' : /Safari/.test(ua) ? 'Safari' : 'Other',
    os: /iPhone|iPad/.test(ua) ? 'iOS' : /Android/.test(ua) ? 'Android' : /Windows/.test(ua) ? 'Windows' : /Macintosh/.test(ua) ? 'macOS' : /Linux/.test(ua) ? 'Linux' : 'Other',
    device: /iPad|Tablet/.test(ua) ? 'Tablet' : /Mobile|iPhone|Android/.test(ua) ? 'Mobile' : 'Desktop' };
}
async function sign(value, secret) {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey('raw',encoder.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  return Array.from(new Uint8Array(await crypto.subtle.sign('HMAC',key,encoder.encode(value))), b=>b.toString(16).padStart(2,'0')).join('');
}
export async function visitorID(cookie, secret) {
  const value = cookie?.split(';').map(x=>x.trim()).find(x=>x.startsWith(cookieName+'='))?.slice(cookieName.length+1);
  const [id, signature] = (value || '').split('.');
  if (uuid.test(id || '') && signature === await sign(id,secret)) return {id, fresh:false};
  return {id:crypto.randomUUID(), fresh:true};
}
export function eventMetadata(body, request, visitor) {
  if (!uuid.test(body.id || '') || !uuid.test(body.session || '') || !['page_view','download'].includes(body.kind)) return null;
  let path;
  try { const u=new URL(body.path, 'https://oathwallet.org'); if(u.origin!=='https://oathwallet.org') return null; path=u.pathname.slice(0,240); } catch { return null; }
  const cf=request.cf || {};
  const coordinate=(v,max)=>v!==undefined && Number.isFinite(Number(v)) && Math.abs(Number(v))<=max ? Math.round(Number(v)*10)/10 : null;
  let referrer=null;
  try { const u=new URL(body.referrer); if(['http:','https:'].includes(u.protocol)) referrer=u.hostname.slice(0,120); } catch {}
  return {id:body.id, session_id:body.session, visitor_id:visitor, kind:body.kind, path,
    country:/^[A-Z]{2}$/.test(cf.country || '') ? cf.country : null, city:typeof cf.city==='string' ? cf.city.slice(0,80) : null,
    latitude:coordinate(cf.latitude,90), longitude:coordinate(cf.longitude,180),
    ...classifyAgent(request.headers.get('user-agent') || ''),referrer};
}
export async function handleAnalytics(request, env) {
  const headers={'Cache-Control':'no-store','Vary':'Cookie, Origin','Content-Type':'application/json'};
  const reply=(status,body={})=>new Response(JSON.stringify(body),{status,headers});
  if(request.method!=='POST') return reply(405);
  if(request.headers.get('origin')!=='https://oathwallet.org') return reply(403);
  if(request.headers.get('sec-gpc')==='1' || request.headers.get('dnt')==='1' || bot.test(request.headers.get('user-agent')||'')) return reply(202);
  if(!env.WEBSITE_ANALYTICS_KEY) return reply(503);
  if(env.VISITOR_LIMITER) {
    const key=await sign(request.headers.get('cf-connecting-ip')||'unknown',env.WEBSITE_ANALYTICS_KEY);
    if(!(await env.VISITOR_LIMITER.limit({key})).success) return reply(429);
  }
  const text=await request.text();
  if(text.length>2048) return reply(413);
  let body; try { body=JSON.parse(text); } catch { return reply(400); }
  if(!body || typeof body!=='object') return reply(400);
  const visitor=await visitorID(request.headers.get('cookie'),env.WEBSITE_ANALYTICS_KEY);
  const event=eventMetadata(body,request,visitor.id);
  if(!event) return reply(400);
  // First-party edge authentication makes client-supplied geo fields irrelevant.
  const result=await fetch('https://rfjdenxkgjgepgbmxxkd.supabase.co/functions/v1/website-analytics',{
    method:'POST',signal:AbortSignal.timeout(8000),headers:{'Content-Type':'application/json','X-Website-Key':env.WEBSITE_ANALYTICS_KEY},
    body:JSON.stringify({action:'ingest',event})});
  if(!result.ok) return reply(503);
  if(visitor.fresh) headers['Set-Cookie']=`${cookieName}=${visitor.id}.${await sign(visitor.id,env.WEBSITE_ANALYTICS_KEY)}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=31536000`;
  return reply(200,{ok:true});
}
