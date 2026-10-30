import { Webhook } from 'npm:svix@2.5.0';
import { mailgunRequest, verifyMailgun, normalizeMailgun } from './mailgun.ts';
import { openPixel, trackBody, verifyEngagement } from './tracking.ts';
import { createClient } from 'npm:@supabase/supabase-js@2';
import { TOPICS, NEWS_ORIGIN, SENDER, uuid, normalizeEmail, validateTopics, hash, randomToken, equal, verifyPassword, preferenceToken, verifyPreferenceToken, validateCampaign, markdown, emailTemplate, escapeHtml, csvCell, providerPayload, providerResult, normalizeWebhook } from './core.ts';
const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
const json=(status:number,data:unknown)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
const provider=()=>Deno.env.get('NEWSLETTER_PROVIDER')==='resend'?'Resend':'Mailgun';
const sendingEnabled=()=>Deno.env.get('NEWSLETTER_PROVIDER_ENABLED')==='true';
// Oath's signed HTTPS endpoints provide engagement reporting; provider rewriting stays off.
const trackingEnabled=()=>Deno.env.get('NEWSLETTER_TRACKING_ENABLED')==='true';
const ready=()=>sendingEnabled()&&(provider()==='Resend'?Boolean(Deno.env.get('RESEND_API_KEY')&&Deno.env.get('RESEND_WEBHOOK_SECRET')):Boolean(Deno.env.get('MAILGUN_API_KEY')&&Deno.env.get('MAILGUN_DOMAIN')&&Deno.env.get('MAILGUN_WEBHOOK_SECRET')));
const mode=()=>ready()?'sending':sendingEnabled()?'setup_required':'collecting';
const linkSecret=()=>Deno.env.get('NEWSLETTER_LINK_SECRET')!;
class RequestError extends Error { constructor(message:string,public status=400){super(message);} }
async function query<T=any>(request:PromiseLike<{data:T,error:any}>) {const r=await request;if(r.error)throw new RequestError('The database is temporarily unavailable. Please try again.',503);return r.data;}
async function rpc(name:string,args:Record<string,unknown>={}){return await query(db.rpc(name,args));}
async function audit(action:string,detail:Record<string,unknown>={}){await query(db.from('newsletter_audit').insert({action,detail}));}
async function health(key:string,value:unknown){await query(db.from('newsletter_health').upsert({key,value,updated_at:new Date().toISOString()}));}
async function rate(key:string,limit:number,seconds:number){if(!await rpc('newsletter_rate_limit',{p_key:key,p_limit:limit,p_seconds:seconds}))throw new RequestError('Too many attempts. Please try again later.',429);}
async function session(token:unknown){
 if(typeof token!=='string'||!/^[a-f0-9]{64}$/.test(token))throw new RequestError('Please sign in.',401);
 const rows=await query(db.from('newsletter_admin_sessions').select('token_hash').eq('token_hash',await hash(token)).eq('credential_version',await hash(Deno.env.get('NEWSLETTER_ADMIN_VERIFIER')||'')).gt('expires_at',new Date().toISOString()));
 if(!rows?.length)throw new RequestError('Your session expired. Please sign in again.',401);
}
async function preferenceID(token:unknown){const id=await verifyPreferenceToken(token,linkSecret());if(!id)throw new RequestError('This link is invalid. Use the link in a recent Oath email.');return id;}
async function campaign(id:unknown){if(typeof id!=='string'||!uuid.test(id))throw new RequestError('Choose a valid campaign.');const row=await query(db.from('newsletter_campaigns').select('*').eq('id',id).maybeSingle());if(!row)throw new RequestError('Campaign not found.',404);return row;}
async function audience(topic:string){let q=db.from('newsletter_subscribers').select('id',{count:'exact',head:true}).eq('status','active');if(topic!=='all')q=q.contains('topics',[topic]);const r=await q;if(r.error)throw new RequestError('Audience is unavailable.',503);return r.count||0;}
async function processMessages(){
 await health('dispatcher',{state:ready()?'running':mode()});
 if(!ready())return {ok:true,processed:0,sending_enabled:false,mode:mode()};
 const messages=await rpc('newsletter_claim_messages',{p_limit:10,p_daily_limit:Number(Deno.env.get('NEWSLETTER_DAILY_LIMIT')||100)});let processed=0;
 // Three bounded send requests at a time; each record has an atomic database lease.
 for(let i=0;i<messages.length;i+=3)await Promise.all(messages.slice(i,i+3).map(async(m:any)=>{
  try{
   let subject:string,html:string,text:string,tracking=false;
   let prefs='https://news.oathwallet.org/';
   if(m.subscriber_id)prefs=`${NEWS_ORIGIN}/preferences?token=${await preferenceToken(m.subscriber_id,linkSecret())}&message=${m.id}`;
   if(m.kind==='confirmation'){
    await query(db.from('newsletter_messages').update({status:'cancelled',payload:{},error:'Email confirmation is no longer required.'}).eq('id',m.id).eq('status','sending'));
    return;
   }else{
    const c=m.kind==='test'?m.payload:await campaign(m.campaign_id);
    if(m.kind==='campaign'){
     const s=await query(db.from('newsletter_subscribers').select('status,topics').eq('id',m.subscriber_id).single());
     if(!s||s.status!=='active'||(c.topic!=='all'&&!s.topics.includes(c.topic))||c.status==='cancelled'){
      await query(db.from('newsletter_messages').update({status:'skipped'}).eq('id',m.id));return;
     }
     await query(db.from('newsletter_campaigns').update({status:'sending'}).eq('id',c.id).eq('status','queued'));
    }
    subject=(m.kind==='test'?'[Preview] ':'')+c.subject;tracking=m.kind==='campaign'&&c.tracking&&trackingEnabled();
    const content=markdown(c.body);
    html=emailTemplate(subject,c.preheader,tracking?await trackBody(content,m.id,linkSecret()):content,prefs,m.kind==='test');
    if(tracking){
     html=html.replace('</body>',await openPixel(m.id,linkSecret())+'</body>');
     await query(db.from('newsletter_messages').update({tracking_enabled:true}).eq('id',m.id).eq('status','sending'));
    }
    text=`${c.subject}\n\n${c.body}\n\nManage preferences / unsubscribe: ${prefs}\nOath Wallet · STAGE AND STYLE COLLECTIVE LLC · 2103 Condor Ct, Redmond, OR 97756-8281, United States`;
   }
   const unsubscribeURL=m.kind==='campaign'?`${NEWS_ORIGIN}/unsubscribe?token=${await preferenceToken(m.subscriber_id,linkSecret())}&message=${m.id}`:null;
   const response=provider()==='Resend'?await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${Deno.env.get('RESEND_API_KEY')}`,'Content-Type':'application/json','Idempotency-Key':`oath-${m.id}`},body:JSON.stringify(providerPayload(m,subject,html,text,unsubscribeURL)),signal:AbortSignal.timeout(20000)}):
    await fetch(`https://${Deno.env.get('MAILGUN_REGION')==='eu'?'api.eu.mailgun.net':'api.mailgun.net'}/v3/${Deno.env.get('MAILGUN_DOMAIN')}/messages`,{method:'POST',headers:{Authorization:'Basic '+btoa('api:'+Deno.env.get('MAILGUN_API_KEY'))},body:mailgunRequest(m,subject,html,text,unsubscribeURL,false),signal:AbortSignal.timeout(20000)});
   let result:any;try{result=await response.json();}catch{result={};}
   const outcome=providerResult(response.status,result);
   // A webhook may have already reconciled this row. Never overwrite its stronger evidence.
   await query(db.from('newsletter_messages').update({...outcome,accepted_at:outcome.status==='accepted'?new Date().toISOString():null}).eq('id',m.id).eq('status','sending'));
   if(outcome.status!=='accepted')await health('provider_error',{message:outcome.error,at:new Date().toISOString()});
   processed++;
  }catch{
   await query(db.from('newsletter_messages').update({status:'uncertain',error:'The request was interrupted. Check the provider before retrying to prevent duplicate email.'}).eq('id',m.id).eq('status','sending'));
  }
 }));
 const active=await query(db.from('newsletter_campaigns').select('id').in('status',['queued','sending']).limit(100));
 for(const c of active||[]){const r=await db.from('newsletter_messages').select('id',{count:'exact',head:true}).eq('campaign_id',c.id).in('status',['queued','sending']);if(!r.error&&r.count===0)await query(db.from('newsletter_campaigns').update({status:'complete',updated_at:new Date().toISOString()}).eq('id',c.id).in('status',['queued','sending']));}
 await health('dispatcher',{state:'ready',processed});return {ok:true,processed};
}

Deno.serve(async request=>{
 if(request.method!=='POST')return json(405,{error:'Method not allowed.'});
 if(!await equal(request.headers.get('X-Newsletter-Key'),Deno.env.get('NEWSLETTER_GATEWAY_KEY')))return json(401,{error:'Unauthorized.'});
 try{
  const raw=await request.text();if(raw.length>300000)throw new RequestError('Request is too large.',413);
  const p=JSON.parse(raw);const action=String(p.action||'');
  if(action==='public.signup'){
   await rate('signup:'+p.ipHash,10,3600);
   if(p.website)return json(200,{ok:true,message:'Thank you. Your signup has been received.'});
   if(p.consent!==true)throw new RequestError('Please agree to receive the newsletter.');
   const email=normalizeEmail(p.email),topics=validateTopics(p.topics);
   const signup=await rpc('newsletter_signup',{p_email:email,p_topics:topics,p_source:typeof p.source==='string'&&p.source.startsWith('/')?p.source.split(/[?#]/)[0].slice(0,200):'/'});
   if(!signup.subscribed)throw new RequestError('We can’t subscribe this address. Please use a different email address or contact care@oathwallet.org.');
   return json(200,{ok:true,mode:mode(),subscribed:true,message:'You’re subscribed to Oath Notes. No email confirmation is needed — you’re all set.'});
  }
  if(action==='public.confirm'){
   await rate('confirm:'+p.ipHash,30,3600);
   const active=typeof p.token==='string'&&/^[a-f0-9]{64}$/.test(p.token)&&await rpc('newsletter_confirm',{p_hash:await hash(p.token)});
   return json(200,{ok:true,active,message:active?'Your Oath Notes subscription is active. No further action is needed.':'Email confirmation is no longer required. Subscribe on our newsletter page to join Oath Notes.'});
  }
  if(action==='public.engagement'){
   const event=await verifyEngagement(p,linkSecret());
   if(!event)throw new RequestError('Invalid link.',404);
   const eligible=await rpc('newsletter_record_engagement',{p_id:event.id,p_kind:event.kind,p_detail:event.detail,p_record:p.record!==false});
   if(!eligible)throw new RequestError('This link is unavailable.',404);
   return json(200,{ok:true,...(event.kind==='click'?{redirect:event.target}:{})});
  }
  if(action==='public.preferences'){
   const id=await preferenceID(p.token);const data=await query(db.from('newsletter_subscribers').select('topics,status').eq('id',id).maybeSingle());
   if(!data)throw new RequestError('Subscription not found.',404);return json(200,data);
  }
  if(action==='public.updatePreferences'){
   const id=await preferenceID(p.token);const topics=validateTopics(p.topics);
   const rows=await query(db.from('newsletter_subscribers').update({topics,updated_at:new Date().toISOString()}).eq('id',id).eq('status','active').select('id'));
   if(!rows?.length)throw new RequestError('This subscription is inactive. Sign up again to start a new subscription.');
   await audit('preferences_updated',{subscriber_id:id});return json(200,{ok:true,message:'Your preferences are saved.'});
  }
  if(action==='public.unsubscribe'){
   const id=await preferenceID(p.token);await rpc('newsletter_unsubscribe',{p_id:id});
   if(uuid.test(p.message_id)){
    const m=await query(db.from('newsletter_messages').select('id,email,provider_id,campaign_id').eq('id',p.message_id).eq('subscriber_id',id).maybeSingle());
    if(m?.campaign_id&&m.provider_id)await rpc('newsletter_record_event',{p_event:{id:await hash('unsubscribe:'+m.id),message_id:m.id,email:m.email,provider_id:m.provider_id,kind:'unsubscribe',occurred_at:new Date().toISOString(),detail:'Subscriber request'}});
   }
   return json(200,{ok:true,message:'You’re unsubscribed. You will receive no further newsletters.'});
  }
  if(action==='provider.webhook'){
   let events;
   if(provider()==='Mailgun'){
    const payload=JSON.parse(p.raw);
    if(!await verifyMailgun(payload,Deno.env.get('MAILGUN_WEBHOOK_SECRET')||'')){
     if(!payload.signature?.token||!payload.signature?.timestamp)throw new RequestError('Missing Mailgun webhook signature fields.',401);
     if(Math.abs(Date.now()/1000-Number(payload.signature.timestamp))>86400)throw new RequestError('Webhook signature timestamp is outside the permitted window.',401);
     throw new RequestError('Invalid webhook signature.',401);
    }
    events=await normalizeMailgun(payload);
   }else{
    let payload;try{new Webhook(Deno.env.get('RESEND_WEBHOOK_SECRET')||'').verify(p.raw,p.headers);payload=JSON.parse(p.raw);}catch{throw new RequestError('Invalid webhook signature.',401);}
    events=await normalizeWebhook(payload,p.headers['svix-id']);
   }
   for(const event of events)await rpc('newsletter_record_event',{p_event:event});
   await health('webhook',{state:'receiving',events:events.length});return json(200,{ok:true});
  }
  if(action==='system.dispatch')return json(200,await processMessages());
  if(action==='system.cleanup'){
   await query(db.from('newsletter_admin_sessions').delete().lt('expires_at',new Date().toISOString()));
   await query(db.from('newsletter_limits').delete().lt('expires_at',new Date().toISOString()));
   await query(db.from('newsletter_tokens').delete().lt('expires_at',new Date(Date.now()-86400000*7).toISOString()));
   await query(db.from('newsletter_messages').update({payload:{}}).lt('created_at',new Date(Date.now()-86400000*7).toISOString()).in('status',['accepted','cancelled','skipped']));
   return json(200,{ok:true});
  }
  if(action==='admin.login'){
   await rate('login:'+p.ipHash,10,900);
   if(!await verifyPassword(p.password,Deno.env.get('NEWSLETTER_ADMIN_VERIFIER')))throw new RequestError('Incorrect admin password.',401);
   const token=randomToken();await query(db.from('newsletter_admin_sessions').insert({token_hash:await hash(token),credential_version:await hash(Deno.env.get('NEWSLETTER_ADMIN_VERIFIER')!),expires_at:new Date(Date.now()+8*3600000).toISOString()}));
   await audit('admin_signed_in');return json(200,{ok:true,sessionToken:token});
  }
  await session(p.sessionToken);
  if(action==='admin.logout') {await query(db.from('newsletter_admin_sessions').delete().eq('token_hash',await hash(p.sessionToken)));return json(200,{ok:true});}
  if(action==='admin.me')return json(200,{ok:true,email:SENDER});
  if(action==='admin.dashboard'){
   const days=[7,30,90,365].includes(p.days)?p.days:30;
   const [data,signupTopics]=await Promise.all([rpc('newsletter_dashboard',{p_days:days}),rpc('newsletter_signup_topics')]);return json(200,{...data,signup_topics:signupTopics,days,provider:{ready:ready(),mode:mode(),signup_enabled:true,opt_in:'single',sending_enabled:sendingEnabled(),tracking_enabled:trackingEnabled(),name:provider(),sender:SENDER,mailbox_host:'Zoho Mail',rate_per_minute:10,daily_limit:Number(Deno.env.get('NEWSLETTER_DAILY_LIMIT')||100)},generated_at:new Date().toISOString()});
  }
  if(action==='admin.subscribers'||action==='admin.export'){
   const page=Math.max(0,Math.floor(Number(p.page)||0));const size=action==='admin.export'?1000:50;
   let q=db.from('newsletter_subscribers').select('id,email,status,topics,source,consent_version,created_at,subscribed_at,opt_in_method,confirmed_at,unsubscribed_at',{count:'exact'}).order('created_at',{ascending:false}).order('id').range(page*size,(page+1)*size-1);
   if(['pending','active','unsubscribed','bounced','complained'].includes(p.status))q=q.eq('status',p.status);
   if(typeof p.search==='string'&&p.search.trim())q=q.ilike('email','%'+p.search.trim().slice(0,100).replace(/[\\%_]/g,'\\$&')+'%');
   const r=await q;if(r.error)throw new RequestError('Subscribers are temporarily unavailable.',503);
   if(action==='admin.export'&&page===0)await audit('subscribers_exported',{count:r.count,status:p.status||'all'});
   return json(200,{rows:r.data,total:r.count,page,size});
  }
  if(action==='admin.unsubscribe'){
   if(!uuid.test(p.id))throw new RequestError('Invalid subscriber.');await rpc('newsletter_unsubscribe',{p_id:p.id});return json(200,{ok:true});
  }
  if(action==='admin.campaigns')return json(200,{rows:await query(db.from('newsletter_campaigns').select('*').order('created_at',{ascending:false}).limit(200))});
  if(action==='admin.campaign'){
   const c=await campaign(p.id);return json(200,{campaign:c,audience:await audience(c.topic),stats:await rpc('newsletter_campaign_stats',{p_id:c.id})});
  }
  if(action==='admin.saveCampaign'){
   const values=validateCampaign(p.campaign||{});values.tracking=values.tracking&&trackingEnabled();let c;
   if(p.id){await campaign(p.id);c=await query(db.from('newsletter_campaigns').update({...values,updated_at:new Date().toISOString()}).eq('id',p.id).eq('status','draft').select().maybeSingle());if(!c)throw new RequestError('Only drafts can be edited.',409);}
   else c=await query(db.from('newsletter_campaigns').insert(values).select().single());
   await audit('campaign_saved',{campaign_id:c.id});return json(200,{campaign:c,audience:await audience(c.topic)});
  }
  if(action==='admin.preview'){
   const c=validateCampaign(p.campaign||{});return json(200,{html:emailTemplate(c.subject,c.preheader,markdown(c.body),`${NEWS_ORIGIN}/`),audience:await audience(c.topic)});
  }
  if(action==='admin.test'){
   if(!ready())throw new RequestError('Email sending is off. Signups and drafts are saved; sending will be activated separately.',409);
   await rate('admin-test',20,3600);const c=validateCampaign(p.campaign||{});
   // The test endpoint cannot be used as an arbitrary mail relay.
   await query(db.from('newsletter_messages').insert({kind:'test',email:SENDER,dedupe_key:'test:'+randomToken(),payload:c}));
   await audit('test_queued',{recipient:SENDER});return json(200,{ok:true,message:`Preview queued for ${SENDER}. The delivery worker runs every minute.`});
  }
  if(action==='admin.send'){
   if(!ready())throw new RequestError('Email sending is off. Signups and drafts are saved; sending will be activated separately.',409);
   const c=await campaign(p.id);let schedule=null;
   if(p.scheduled_at){const d=new Date(p.scheduled_at);if(!Number.isFinite(d.getTime())||d.getTime()<Date.now()-60000||d.getTime()>Date.now()+86400000*365)throw new RequestError('Choose a future date within one year.');schedule=d.toISOString();}
   const result=await rpc('newsletter_queue_campaign',{p_id:c.id,p_expected:Number(p.expected_count),p_schedule:schedule});if(result.error)throw new RequestError(result.error,409);return json(200,result);
  }
  if(action==='admin.cancel')return json(200,{ok:await rpc('newsletter_cancel_campaign',{p_id:(await campaign(p.id)).id})});
  if(action==='admin.dispatch')return json(200,await processMessages());
  if(action==='admin.messages')return json(200,{rows:await rpc('newsletter_delivery_log')});
  if(action==='admin.retry'){
   if(!ready())throw new RequestError('Email sending is off. No retry has been queued.',409);
   if(!uuid.test(p.id))throw new RequestError('Invalid message.');
   const m=await query(db.from('newsletter_messages').select('*').eq('id',p.id).eq('status','failed').maybeSingle());
   if(!m)throw new RequestError('Only explicitly rejected messages can be retried. Uncertain sends must be checked with the email provider first.');
   if(m.kind==='test'&&!m.payload.body)throw new RequestError('Create a new preview from the campaign editor.');
   if(m.campaign_id&&(await campaign(m.campaign_id)).status==='cancelled')throw new RequestError('This campaign was cancelled.');
   await query(db.from('newsletter_messages').upsert({subscriber_id:m.subscriber_id,campaign_id:m.campaign_id,kind:m.kind,email:m.email,dedupe_key:'retry:'+m.id,payload:m.payload},{onConflict:'dedupe_key',ignoreDuplicates:true}));
   if(m.campaign_id)await query(db.from('newsletter_campaigns').update({status:'sending'}).eq('id',m.campaign_id).eq('status','complete'));
   await audit('message_retried',{message_id:m.id});return json(200,{ok:true});
  }
  throw new RequestError('Unknown action.',404);
 }catch(e){
  if(e instanceof RequestError)return json(e.status,{error:e.message});
  if(e instanceof SyntaxError)return json(400,{error:'Invalid request.'});
  // Validation messages contain no credentials; unexpected errors never reach clients.
  if(e instanceof Error&&/^(Enter |Choose |Check |Invalid webhook)/.test(e.message))return json(400,{error:e.message});
  return json(503,{error:'The newsletter service is temporarily unavailable. Please try again.'});
 }
});
