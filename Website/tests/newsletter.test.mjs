import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { handleNewsletter } from '../src/newsletter.js';
const env={NEWSLETTER_GATEWAY_KEY:'unit-test-key',ASSETS:{fetch:async request=>new Response(await readFile(new URL('../public'+new URL(request.url).pathname,import.meta.url)),{headers:{'Content-Type':'text/html'}})}};
test('admin page is available but protected APIs reject cross-origin requests',async()=>{
 const page=await handleNewsletter(new Request('https://news.oathwallet.org/admin'),env);
 assert.equal(page.status,200);assert.match(page.headers.get('Content-Security-Policy'),/frame-ancestors 'none'/);assert.equal(page.headers.get('X-Robots-Tag'),'noindex, nofollow');assert.match(await page.text(),/Admin password/);
 const r=await handleNewsletter(new Request('https://news.oathwallet.org/api/subscribers',{method:'POST',headers:{Origin:'https://evil.example','Content-Type':'application/json'},body:'{}'}),env);assert.equal(r.status,403);
});
test('public input cannot select privileged backend actions or supply a session',async()=>{
 const original=globalThis.fetch;let sent;
 globalThis.fetch=async(_url,request)=>{sent=JSON.parse(request.body);return Response.json({ok:true});};
 try{const r=await handleNewsletter(new Request('https://oathwallet.org/_newsletter/signup',{method:'POST',headers:{Origin:'https://oathwallet.org','Content-Type':'application/json'},body:JSON.stringify({action:'admin.dashboard',sessionToken:'attacker',email:'care@oathwallet.org'})}),env);assert.equal(r.status,200);assert.equal(sent.action,'public.signup');assert.equal(sent.sessionToken,'');assert.equal(sent.ipHash.length,64);}finally{globalThis.fetch=original;}
});
test('only the newsletter host exposes admin routes',async()=>{
 assert.equal(await handleNewsletter(new Request('https://oathwallet.org/api/subscribers'),env),null);
 const r=await handleNewsletter(new Request('https://news.oathwallet.org/_newsletter/admin'),env);assert.equal(r.status,405);
});
test('admin login keeps its bearer token only in a Secure HttpOnly cookie',async()=>{
 const original=globalThis.fetch;globalThis.fetch=async()=>Response.json({ok:true,sessionToken:'a'.repeat(64)});
 try{const r=await handleNewsletter(new Request('https://news.oathwallet.org/api/login',{method:'POST',headers:{Origin:'https://news.oathwallet.org','Content-Type':'application/json'},body:'{}'}),env);assert.equal((await r.json()).sessionToken,undefined);assert.match(r.headers.get('Set-Cookie'),/Secure; HttpOnly; SameSite=Strict/);}finally{globalThis.fetch=original;}
});
test('webhook signature receives the exact bytes, and GET unsubscribe is non-mutating',async()=>{
 const original=globalThis.fetch;let sent;globalThis.fetch=async(_url,r)=>{sent=JSON.parse(r.body);return Response.json({ok:true});};
 try{const raw=' { "event": "test" } ';
 await handleNewsletter(new Request('https://news.oathwallet.org/api/webhook',{method:'POST',headers:{'svix-id':'test','svix-signature':'signature'},body:raw}),env);assert.equal(sent.raw,raw);
 sent=null;const page=await handleNewsletter(new Request('https://news.oathwallet.org/unsubscribe?token=secret'),env);assert.equal(page.status,200);assert.equal(sent,null);
 const r=await handleNewsletter(new Request('https://news.oathwallet.org/unsubscribe?token=secret&message=message-id',{method:'POST',body:'List-Unsubscribe=One-Click'}),env);assert.equal(r.status,200);assert.equal(sent.action,'public.unsubscribe');assert.equal(sent.token,'secret');assert.equal(sent.message_id,'message-id');
 }finally{globalThis.fetch=original;}
});
test('HTTPS engagement is scoped, validated by the backend, uncached and non-mutating on HEAD',async()=>{
 const original=globalThis.fetch;let sent;
 globalThis.fetch=async(_url,r)=>{sent=JSON.parse(r.body);return Response.json(sent.token==='valid'?{ok:true,redirect:'https://oathwallet.org/articles?a=1'}:{error:'invalid'},{status:sent.token==='valid'?200:404});};
 try{
  const path='/t/open/f877906c-e2df-4e86-9230-834583631e75?token=valid';
  let r=await handleNewsletter(new Request('https://news.oathwallet.org'+path),env);
  assert.equal(r.status,200);assert.equal(r.headers.get('Content-Type'),'image/gif');assert.equal(r.headers.get('Cache-Control'),'no-store');assert.equal(sent.record,true);assert.equal(sent.action,'public.engagement');
  r=await handleNewsletter(new Request('https://news.oathwallet.org'+path,{method:'HEAD'}),env);assert.equal(sent.record,false);assert.equal((await r.arrayBuffer()).byteLength,0);
  r=await handleNewsletter(new Request('https://news.oathwallet.org'+path.replace('/open/','/click/')),env);assert.equal(r.status,302);assert.equal(r.headers.get('Location'),'https://oathwallet.org/articles?a=1');assert.equal(r.headers.get('Referrer-Policy'),'no-referrer');
  r=await handleNewsletter(new Request('https://news.oathwallet.org'+path.replace('valid','forged')),env);assert.equal(r.status,404);
  r=await handleNewsletter(new Request('https://news.oathwallet.org'+path,{method:'POST'}),env);assert.equal(r.status,405);
  assert.equal(await handleNewsletter(new Request('https://oathwallet.org'+path),env),null);
 }finally{globalThis.fetch=original;}
});
