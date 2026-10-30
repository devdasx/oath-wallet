import { authorizeDevice, requireAppAccess, deviceError } from "../_shared/vault-device-auth.ts";
import { createClient } from 'npm:@supabase/supabase-js@2';
declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void };
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
async function equal(a: unknown,b: string|undefined) {
 if(typeof a!=='string'||!b||a.length>4096)return false;
 const hash=async(s:string)=>new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s)));
 const [x,y]=await Promise.all([hash(a),hash(b)]); let d=0; for(let i=0;i<x.length;i++)d|=x[i]^y[i]; return d===0;
}
const json=(status:number,body:unknown)=>new Response(JSON.stringify(body),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});
Deno.serve(async request=>{
 if(request.method!=='POST')return json(405,{error:'method_not_allowed'});
 try {
 const text=await request.text();if(text.length>8192)return json(413,{error:'too_large'});
 const p=JSON.parse(text);
 const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
 if(p.action==='ingest') {
  if(!await equal(request.headers.get('X-Website-Key'),Deno.env.get('WEBSITE_ANALYTICS_KEY')))return json(401,{error:'unauthorized'});
  const e=p.event;
  if(!e || !uuid.test(e.id)||!uuid.test(e.visitor_id)||!uuid.test(e.session_id)||!['page_view','download'].includes(e.kind)||typeof e.path!=='string'||!e.path.startsWith('/')||e.path.length>240)return json(400,{error:'invalid_event'});
  const {data,error}=await admin.rpc('website_record_event',{p_event:e}); if(error) return json(503,{error:'event_store_unavailable'});
  if(data) EdgeRuntime.waitUntil(fetch('https://aperture-vault-notifications.thuglifex.workers.dev/website-dispatch',{
    method:'POST',headers:{'X-Website-Key':Deno.env.get('WEBSITE_ANALYTICS_KEY')!},signal:AbortSignal.timeout(15000)
  }).then(()=>{}).catch(()=>{}));
  return json(200,{ok:true});
 }
 if(!await equal(p.password,Deno.env.get('APERTURE_CUSTODIAL_MASTER_SECRET_V2')))return json(401,{error:'unauthorized'});
 delete p.password;
 let device;
 try { device=await authorizeDevice(request,text,"website-analytics",(name,args)=>admin.rpc(name,args)); requireAppAccess(device); }
 catch(error) { return deviceError(error); }
 if(['preferences','setPreferences'].includes(p.action) && String(p.installationID).toLowerCase()!==device.installationID)
  return json(403,{error:'device_access_unavailable'});
 if(p.action==='dashboard') {
  const days=Number(p.days);if(![1,7,30,365].includes(days))return json(400,{error:'invalid_period'});
  const {data,error}=await admin.rpc('website_dashboard',{p_days:days}); if(error)return json(503,{error:'dashboard_unavailable'});
  return json(200,data);
 }
 if(p.action==='visitor' && uuid.test(p.visitorID)) {
  const {data,error}=await admin.from('website_events').select('*').eq('visitor_id',p.visitorID).order('occurred_at',{ascending:false}).limit(200);
  return error?json(503,{error:'history_unavailable'}):json(200,{events:data});
 }
 if(['preferences','setPreferences'].includes(p.action) && uuid.test(p.installationID)) {
  if(p.action==='setPreferences') {
   if(typeof p.visits!=='boolean'||typeof p.downloads!=='boolean')return json(400,{error:'invalid_preferences'});
   const {error}=await admin.from('website_notification_preferences').upsert({installation_id:p.installationID,visits:p.visits,downloads:p.downloads});
   if(error)return json(503,{error:'preferences_unavailable'});
  }
  const {data,error}=await admin.from('website_notification_preferences').select('visits,downloads').eq('installation_id',p.installationID).maybeSingle();
  return error?json(503,{error:'preferences_unavailable'}):json(200,data||{visits:true,downloads:true});
 }
 return json(400,{error:'invalid_action'});
 } catch {return json(400,{error:'invalid_request'});}
});
