import { emailTemplate, normalizeEmail, validateTopics, markdown, preferenceToken, verifyPreferenceToken, providerPayload, providerResult, normalizeWebhook, csvCell, hash, verifyPassword } from './core.ts';
import { verifyMailgun, normalizeMailgun, mailgunRequest } from './mailgun.ts';
const assert=(v:unknown,m='Assertion failed')=>{if(!v)throw new Error(m);};
const rejects=(f:()=>unknown)=>{let threw=false;try{f();}catch{threw=true;}assert(threw);};
const id='f877906c-e2df-4e86-9230-834583631e75';
Deno.test('email normalization rejects header injection, malformed domains, and duplicates in topics',()=>{
 assert(normalizeEmail('  CARE@OATHWALLET.ORG ')==='care@oathwallet.org');
 for(const v of ['x@','a..b@example.com','x@example.com\r\nBcc: victim@example.com','<a@example.com>','a@-example.com'])rejects(()=>normalizeEmail(v));
 assert(validateTopics(['oath','oath','security']).join(',')==='oath,security');rejects(()=>validateTopics([]));rejects(()=>validateTopics(['unexpected']));
});
Deno.test('preference links are scoped to the subscriber and reject tampering',async()=>{
 const token=await preferenceToken(id,'test-secret');assert(await verifyPreferenceToken(token,'test-secret')===id);
 assert(await verifyPreferenceToken(token,'different-secret')===null);assert(await verifyPreferenceToken(token.replace(id,'a877906c-e2df-4e86-9230-834583631e75'),'test-secret')===null);
 assert(await verifyPreferenceToken(token+'.extra','test-secret')===null);
});
Deno.test('safe email renderer cannot execute raw HTML or javascript links',()=>{
 const result=markdown('## Hello\n\n<img src=x onerror=alert(1)>\n\n[x](javascript:alert(1))\n\n[Read](https://oathwallet.org/?a=1&b=2)\n\n**Useful**');
 assert(!result.includes('<img'));assert(!result.includes('href="javascript:'));assert(result.includes('<strong>Useful</strong>'));assert(result.includes('https://oathwallet.org/?a=1&amp;b=2'));
 assert(csvCell('=HYPERLINK("bad")').startsWith('"\''));
});
Deno.test('provider sends use the requested address, individual recipients and one-click unsubscribe',()=>{
 const payload=providerPayload({id,email:'care@oathwallet.org'},'Subject','<p>Hello</p>','Hello','https://news.oathwallet.org/unsubscribe?token=test');
 assert(payload.from==='Oath Wallet <care@oathwallet.org>');assert(payload.to.length===1);assert(payload.headers['List-Unsubscribe-Post']==='List-Unsubscribe=One-Click');
 const form=mailgunRequest({id,email:'care@oathwallet.org'},'Subject','<p>Hello</p>','Hello','https://news.oathwallet.org/unsubscribe?token=test',false);
 assert(form.get('o:tracking')==='no');assert(form.get('o:require-tls')==='yes');assert(form.get('v:oath_message_id')===id);assert(form.get('h:Reply-To')==='care@oathwallet.org');
});
Deno.test('unknown outcomes cannot be mistaken for success or safe retry',()=>{
 assert(providerResult(200,{id:'<123@mail.example>'}).provider_id==='123@mail.example');
 assert(providerResult(200,{message:'unexpected'}).status==='uncertain');assert(providerResult(503,{message:'outage'}).status==='uncertain');assert(providerResult(429,{message:'quota'}).status==='failed');
});
Deno.test('webhook signature rejects unsigned and stale events; normalization drops private telemetry',async()=>{
 const payload:any={signature:{timestamp:String(Math.floor(Date.now()/1000)),token:'a'.repeat(50)},'event-data':{id:'event1',event:'delivered',timestamp:Date.now()/1000,recipient:'care@oathwallet.org','user-variables':{oath_message_id:id},message:{headers:{'message-id':'123@mail.example'}},ip:'secret-ip'}};
 const key=await crypto.subtle.importKey('raw',new TextEncoder().encode('test-signing-key'),{name:'HMAC',hash:'SHA-256'},false,['sign']);
 payload.signature.signature=Array.from(new Uint8Array(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(payload.signature.timestamp+payload.signature.token))),b=>b.toString(16).padStart(2,'0')).join('');
 assert(await verifyMailgun(payload,'test-signing-key'));assert(!await verifyMailgun(payload,'wrong-key'));
 const events=await normalizeMailgun(payload);assert(events.length===1&&events[0].kind==='delivered');assert(!JSON.stringify(events).includes('secret-ip'));
 assert((await normalizeMailgun(payload))[0].id===events[0].id);
 payload.signature.token='b'.repeat(50);assert((await normalizeMailgun(payload))[0].id===events[0].id);
 payload.signature.timestamp='1000000000';assert(!await verifyMailgun(payload,'test-signing-key'));
});
Deno.test('Resend events use the same internal recipient model',async()=>{
 const data=await normalizeWebhook({type:'email.bounced',created_at:new Date().toISOString(),data:{email_id:'provider-id',to:['care@oathwallet.org'],tags:{oath_message_id:id},bounce:{message:'Bad address'}}},'eventid');
 assert(data[0].hard_bounce&&data[0].kind==='bounce');assert(data[0].message_id===id);
});
Deno.test('admin password verifier rejects incorrect passwords without comparing plaintext',async()=>{
 const salt='test-salt',password='This-is-a-test-password';const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(password),'PBKDF2',false,['deriveBits']);
 const bits=await crypto.subtle.deriveBits({name:'PBKDF2',hash:'SHA-256',salt:new TextEncoder().encode(salt),iterations:100000},key,256);
 const expected=Array.from(new Uint8Array(bits),b=>b.toString(16).padStart(2,'0')).join('');
 assert(await verifyPassword(password,`pbkdf2:${salt}:${expected}`));assert(!await verifyPassword('wrong',`pbkdf2:${salt}:${expected}`));assert((await hash('secret')).length===64);
});

Deno.test('newsletter footer describes signup consent without claiming mailbox confirmation',()=>{
 const html=emailTemplate('Subject','Preview','<p>News</p>','https://news.oathwallet.org/preferences?token=test');
 assert(html.includes('because you subscribed.'));
 assert(html.includes('Manage preferences or unsubscribe'));
 assert(!html.includes('confirmed your subscription'));
 const preview=emailTemplate('Subject','Preview','<p>News</p>','https://news.oathwallet.org/',true);
 assert(preview.includes('preview for the Oath Wallet team'));
 assert(!preview.includes('until you confirm'));
});
