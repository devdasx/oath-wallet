import { equal, hash, normalizeEmail, SENDER, uuid } from './core.ts';
export function mailgunRequest(message:{id:string,email:string},subject:string,html:string,text:string,unsubscribeURL:string|null,tracking:boolean){
 const body=new FormData();
 for(const [key,value] of Object.entries({from:`Oath Wallet <${SENDER}>`,to:message.email,subject,html,text,'h:Reply-To':SENDER,'h:X-Entity-Ref-ID':message.id,'v:oath_message_id':message.id,'o:tag':'oath-notes','o:tracking':tracking?'yes':'no','o:tracking-opens':tracking?'yes':'no','o:tracking-clicks':tracking?'yes':'no','o:require-tls':'yes'}))body.set(key,value);
 if(unsubscribeURL){body.set('h:List-Unsubscribe',`<${unsubscribeURL}>`);body.set('h:List-Unsubscribe-Post','List-Unsubscribe=One-Click');}
 return body;
}
export async function verifyMailgun(payload:Record<string,any>,secret:string){
 const s=payload.signature;
 if(!secret||!s||typeof s.token!=='string'||s.token.length>100||!/^\d{9,12}$/.test(String(s.timestamp))||!/^[a-f0-9]{64}$/i.test(s.signature||''))return false;
 // Mailgun retries delayed webhooks. Event ids are deduplicated permanently in the database.
 if(Math.abs(Date.now()/1000-Number(s.timestamp))>86400)return false;
 const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);
 const digest=Array.from(new Uint8Array(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(String(s.timestamp)+s.token))),b=>b.toString(16).padStart(2,'0')).join('');
 return equal(s.signature,digest);
}
export async function normalizeMailgun(payload:Record<string,any>){
 const row=payload['event-data'];if(!row)return [];
 const kinds:Record<string,string>={accepted:'accepted',delivered:'delivered',opened:'open',clicked:'click',complained:'complaint',unsubscribed:'unsubscribe',failed:row.severity==='temporary'?'delayed':'bounce',rejected:'failed'};
 const kind=kinds[row.event],id=row['user-variables']?.oath_message_id;
 if(!kind||!uuid.test(id)||typeof row.id!=='string'||!Number.isFinite(Number(row.timestamp)))return [];
 const providerID=String(row.message?.headers?.['message-id']||'').replace(/^<|>$/g,'');if(!providerID)return [];
 let detail='';if(kind==='click'){try{const u=new URL(row.url);detail=u.origin+u.pathname;}catch{detail='Link clicked';}}
 if(['bounce','delayed','failed'].includes(kind))detail=String(row['delivery-status']?.message||row.reason||'Delivery failure').slice(0,500);
 return [{id:await hash('mailgun:'+row.id),message_id:id,email:normalizeEmail(row.recipient),kind,provider_id:providerID,occurred_at:new Date(Number(row.timestamp)*1000).toISOString(),detail,hard_bounce:kind==='bounce'}];
}
