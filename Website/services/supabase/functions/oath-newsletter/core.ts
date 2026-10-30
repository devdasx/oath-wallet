export const TOPICS = ['oath', 'markets', 'security', 'guides'];
export const NEWS_ORIGIN = 'https://news.oathwallet.org';
export const SENDER = 'care@oathwallet.org';
export const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const encoder = new TextEncoder();
export function normalizeEmail(value: unknown): string {
 const email = typeof value === 'string' ? value.trim().toLowerCase() : '';
 if (email.length > 100 || !/^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,63}$/.test(email)
  || email.includes('..') || email.startsWith('.') || email.includes('.@')) throw new Error('Enter a valid email address (up to 100 characters).');
 return email;
}
export function validateTopics(value: unknown): string[] {
 if (!Array.isArray(value)) throw new Error('Choose at least one newsletter topic.');
 const values = [...new Set(value)];
 if (!values.length || values.some(t => !TOPICS.includes(t))) throw new Error('Choose a valid newsletter topic.');
 return values;
}
export function escapeHtml(v: unknown) { return String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!)); }
export async function hash(value: string) { return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(value))), b => b.toString(16).padStart(2,'0')).join(''); }
export function randomToken() { return Array.from(crypto.getRandomValues(new Uint8Array(32)), b=>b.toString(16).padStart(2,'0')).join(''); }
export async function equal(a: unknown, b: string | undefined) {
 if (typeof a !== 'string' || !b || a.length>4096) return false;
 const [x,y]=await Promise.all([hash(a),hash(b)]); let d=0; for(let i=0;i<x.length;i++)d|=x.charCodeAt(i)^y.charCodeAt(i);return d===0;
}
export async function verifyPassword(password: unknown, verifier: string | undefined) {
 if(typeof password !== 'string' || password.length>256 || !verifier) return false;
 const [scheme,salt,expected]=verifier.split(':'); if(scheme!=='pbkdf2' || !salt || !expected)return false;
 const key=await crypto.subtle.importKey('raw',encoder.encode(password),'PBKDF2',false,['deriveBits']);
 const bits=await crypto.subtle.deriveBits({name:'PBKDF2',hash:'SHA-256',salt:encoder.encode(salt),iterations:100000},key,256);
 return equal(Array.from(new Uint8Array(bits),b=>b.toString(16).padStart(2,'0')).join(''),expected);
}
async function signature(value: string, secret: string) {
 const key=await crypto.subtle.importKey('raw',encoder.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);
 return Array.from(new Uint8Array(await crypto.subtle.sign('HMAC',key,encoder.encode(value))),b=>b.toString(16).padStart(2,'0')).join('');
}
export async function preferenceToken(id: string, secret: string) { return `${id}.${await signature('newsletter-preferences:'+id,secret)}`; }
export async function verifyPreferenceToken(token: unknown, secret: string) {
 if(typeof token!=='string')return null; const [id,sig,...extra]=token.split('.');
 if(!uuid.test(id)||extra.length||!await equal(sig,await signature('newsletter-preferences:'+id,secret)))return null;return id;
}
export function validateCampaign(p: Record<string,unknown>) {
 const text=(key:string,max:number,required=true)=>{const v=typeof p[key]==='string'?String(p[key]).trim():'';if((required&&!v)||v.length>max)throw new Error(`Check ${key}; maximum ${max} characters.`);return v;};
 const topic=String(p.topic||'all'); if(!['all',...TOPICS].includes(topic))throw new Error('Choose a valid audience.');
 return {name:text('name',150),subject:text('subject',200),preheader:text('preheader',180,false),body:text('body',50000),topic,tracking:p.tracking===true};
}
// A deliberately small Markdown subset: no raw HTML, scripts, images, or arbitrary URL schemes.
export function markdown(body: string) {
 const inline=(s:string)=>escapeHtml(s).replace(/\[([^\]\n]{1,200})\]\((https:\/\/[^\s)]+)\)/g,(_m,label,url)=>{
  try { const u=new URL(url.replace(/&amp;/g,'&'));if(u.protocol!=='https:'||u.username||u.password)return label;
   return `<a href="${escapeHtml(u.href)}" style="color:#25654b;text-decoration:underline">${label}</a>`; }catch{return label;}
 }).replace(/\*\*([^*\n]+)\*\*/g,'<strong>$1</strong>');
 return body.split(/\n\s*\n/).map(block=>{
  if(/^#{1,3} /.test(block))return `<h2 style="font:600 24px/1.3 Georgia,serif;margin:28px 0 12px">${inline(block.replace(/^#{1,3} /,''))}</h2>`;
  if(block.split('\n').every(l=>/^[-*] /.test(l)))return `<ul>${block.split('\n').map(l=>`<li style="margin:8px 0">${inline(l.slice(2))}</li>`).join('')}</ul>`;
  return `<p style="margin:0 0 18px;line-height:1.7">${inline(block).replace(/\n/g,'<br>')}</p>`;
 }).join('');
}
export function emailTemplate(subject:string,preheader:string,body:string,preferencesUrl:string,preview=false) {
 const footer=preview?'This is an Oath Notes preview for the Oath Wallet team.':`You’re receiving Oath Notes because you subscribed. <a href="${escapeHtml(preferencesUrl)}" style="color:#56605b">Manage preferences or unsubscribe</a>.`;
 return `<!doctype html><html lang="en" dir="ltr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(subject)}</title></head><body dir="ltr" style="direction:ltr;text-align:left;margin:0;background:#f3f4f0;color:#19261f;font:16px Arial,sans-serif"><div style="display:none;max-height:0;overflow:hidden">${escapeHtml(preheader)}</div><table role="presentation" dir="ltr" style="direction:ltr;text-align:left;width:100%;border-collapse:collapse"><tr><td style="padding:32px 16px"><table role="presentation" style="width:100%;max-width:620px;margin:auto;background:white;border:1px solid #e3e7e1;border-radius:20px"><tr><td dir="ltr" align="left" style="padding:36px;text-align:left"><a href="https://oathwallet.org" style="color:#19261f;text-decoration:none;font-size:18px;font-weight:bold">OATH <span style="font-weight:normal;color:#7c847e">/ NOTES</span></a><div style="border-top:1px solid #e4e8e2;margin:24px 0"></div><h1 style="font:400 34px/1.15 Georgia,serif;margin:0 0 24px">${escapeHtml(subject)}</h1>${body}<div style="border-top:1px solid #e4e8e2;margin:28px 0 20px"></div><p style="font-size:12px;line-height:1.7;color:#68736c">${footer}</p><p style="font-size:12px;line-height:1.7;color:#68736c">Oath Wallet · STAGE AND STYLE COLLECTIVE LLC<br>2103 Condor Ct, Redmond, OR 97756-8281, United States<br><a href="https://oathwallet.org/privacy" style="color:#56605b">Privacy</a> · <a href="mailto:care@oathwallet.org" style="color:#56605b">Contact</a></p></td></tr></table></td></tr></table></body></html>`;
}
export function csvCell(value: unknown) { let s=String(value??'');if(/^[=+\-@\t\r]/.test(s))s="'"+s;return '"'+s.replace(/"/g,'""')+'"'; }
export function providerPayload(message: {id:string,email:string},subject:string,html:string,text:string,unsubscribeURL:string|null) {
 return {from:`Oath Wallet <${SENDER}>`,reply_to:SENDER,to:[message.email],subject,html,text,
 tags:[{name:'oath_message_id',value:message.id}],
 headers:{'X-Entity-Ref-ID':message.id,...(unsubscribeURL?{'List-Unsubscribe':`<${unsubscribeURL}>`,'List-Unsubscribe-Post':'List-Unsubscribe=One-Click'}:{})}};
}
export function providerResult(status:number,body:Record<string,any>) {
 if(status>=200&&status<300&&typeof body.id==='string')return {status:'accepted',provider_id:body.id.replace(/^<|>$/g,''),error:null};
 const rejected=status>=400&&status<500&&status!==408;
 return {status:rejected?'failed':'uncertain',provider_id:null,error:typeof body.message==='string'?body.message.slice(0,600):`Provider returned ${status}; verify before retrying.`};
}
export async function normalizeWebhook(payload:Record<string,any>,eventID:string) {
 const kinds:Record<string,string>={'email.sent':'accepted','email.delivered':'delivered','email.opened':'open','email.clicked':'click','email.bounced':'bounce','email.complained':'complaint','email.failed':'failed','email.suppressed':'suppressed','email.delivery_delayed':'delayed'};
 const kind=kinds[payload.type],row=payload.data;if(!kind||!row)return [];
 const id=row.tags?.oath_message_id;
 const date=Date.parse(payload.created_at);if(!uuid.test(id)||!Number.isFinite(date)||date<1577836800000||date>Date.now()+86400000||!row.email_id)return [];
 if(!Array.isArray(row.to)||row.to.length!==1)return [];
 const email=normalizeEmail(row.to[0]);let detail='';
 if(kind==='click'){try{const u=new URL(row.click.link);detail=u.origin+u.pathname;}catch{detail='Link clicked';}}
 if(kind==='bounce')detail=String(row.bounce?.message||'Permanent bounce').slice(0,500);
 if(kind==='failed')detail=String(row.failed?.reason||'Provider sending failure').slice(0,500);
 if(kind==='suppressed')detail=String(row.suppressed?.reason||'Provider suppression').slice(0,500);
 return [{id:await hash(eventID),message_id:id,email,kind,provider_id:String(row.email_id),occurred_at:new Date(date).toISOString(),detail,hard_bounce:kind==='bounce'}];
}
