import manifest from './artwork-manifest.json' with {type:'json'};
import {permittedArtworkURL,artworkCandidates} from './token-artwork.js';
const origin='https://oathwallet.org', memory=new WeakMap(), flights=new Map();
const byteLimit=2*1024*1024;
let activeDownloads=0;
const waiting=[];
async function download(source) {
  if(activeDownloads>=12)await new Promise((resolve,reject)=>{
    const waiter={resolve:()=>{clearTimeout(timer);resolve();}};
    const timer=setTimeout(()=>{const i=waiting.indexOf(waiter);if(i>=0)waiting.splice(i,1);reject(Error('Artwork busy'));},4000);
    waiting.push(waiter);
  });
  else activeDownloads++;
  try{return await fetchArtwork(source);}
  finally{const next=waiting.shift();if(next)next.resolve();else activeDownloads--;}
}
const security={'X-Content-Type-Options':'nosniff','Content-Security-Policy':"default-src 'none'; style-src 'unsafe-inline'; img-src data:; sandbox",'Referrer-Policy':'no-referrer'};
export function imageType(bytes) {
  if(bytes.length>byteLimit)return null;
  if(bytes.length>=24 && bytes[0]===137 && String.fromCharCode(...bytes.slice(1,4))==='PNG') {
    const v=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
    if(v.getUint32(16)>4096 || v.getUint32(20)>4096)return null;
    return 'image/png';
  }
  if(bytes[0]===255 && bytes[1]===216 && bytes[2]===255)return 'image/jpeg';
  if(String.fromCharCode(...bytes.slice(0,4))==='RIFF' && String.fromCharCode(...bytes.slice(8,12))==='WEBP')return 'image/webp';
  if(/^GIF8[79]a/.test(String.fromCharCode(...bytes.slice(0,6))))return 'image/gif';
  if(String.fromCharCode(...bytes.slice(4,12))==='ftypavif')return 'image/avif';
  const text=new TextDecoder('utf-8',{fatal:false}).decode(bytes);
  // SVG stays in an image context; the response CSP also isolates direct visits.
  if(/<svg\b/i.test(text) && !/<(?:!DOCTYPE|!ENTITY|\?xml-stylesheet)|<(?:[\w.-]+:)?(?:script|foreignObject|iframe|object|embed)\b|\son\w+\s*=|@import|(?:href|src)\s*=\s*["'](?!#)|url\(\s*(?:["'](?!#)|[^\s"'#])/i.test(text))return 'image/svg+xml';
  return null;
}
async function record(env,key) {
  let shards=memory.get(env.ASSETS);if(!shards){shards=new Map();memory.set(env.ASSETS,shards);}
  const shard=key.slice(0,2);
  if(!shards.has(shard)){
    const response=await env.ASSETS.fetch(new Request(origin+manifest.prefix+'/'+shard+'.json'));
    if(response.status===404)return null;
    if(!response.ok)throw Error('Artwork metadata unavailable');
    shards.set(shard,await response.json());if(shards.size>16)shards.delete(shards.keys().next().value);
  }
  const data=shards.get(shard);return Object.hasOwn(data,key)?data[key]:null;
}
export async function fetchArtwork(source, fetcher=fetch) {
  const signal=AbortSignal.timeout(8000);
  let failure;
  for(const candidate of artworkCandidates(source)){
    try{return await fetchCandidate(candidate,fetcher,signal);}
    catch(error){failure=error;if(signal.aborted)break;}
  }
  throw failure;
}
async function fetchCandidate(source,fetcher,signal) {
  let url=source;
  for(let hop=0;hop<4;hop++){
    if(!permittedArtworkURL(url))throw Error('Unaccepted artwork source');
    const response=await fetcher(url,{redirect:'manual',signal,headers:{Accept:'image/avif,image/webp,image/png,image/jpeg,image/svg+xml'}});
    if([301,302,303,307,308].includes(response.status)) {await response.body?.cancel();url=new URL(response.headers.get('Location'),url).href;continue;}
    if(!response.ok || Number(response.headers.get('Content-Length'))>byteLimit){await response.body?.cancel();throw Error('Artwork unavailable');}
    const reader=response.body.getReader(),chunks=[];let length=0;
    while(true){const {done,value}=await reader.read();if(done)break;length+=value.length;if(length>byteLimit){await reader.cancel();throw Error('Artwork too large');}chunks.push(value);}
    const bytes=new Uint8Array(length);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
    const type=imageType(bytes);if(!type)throw Error('Not a supported passive image');
    return new Response(bytes,{headers:{...security,'Content-Type':type,'Cache-Control':'public, max-age=86400','X-Oath-Artwork':'image','X-Oath-Artwork-Fetched':String(Date.now())}});
  }
  throw Error('Artwork redirect limit');
}
const fallback=initials=>new Response(`<svg xmlns="http://www.w3.org/2000/svg" width="80" height="80" viewBox="0 0 80 80"><rect width="80" height="80" rx="18" fill="#242427"/><text x="40" y="46" text-anchor="middle" fill="#d6d4cd" font-family="sans-serif" font-size="22">${String(initials).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}</text></svg>`,{headers:{...security,'Content-Type':'image/svg+xml','Cache-Control':'public, max-age=60','X-Oath-Artwork':'fallback'}});
export async function handleArtwork(request,env,ctx) {
  const u=new URL(request.url);
  if(u.pathname.startsWith('/token-artwork-data/')) {const response=await env.ASSETS.fetch(request),headers=new Headers(response.headers);headers.set('X-Robots-Tag','noindex');return new Response(request.method==='HEAD'?null:response.body,{status:response.status,headers});}
  if(!u.pathname.startsWith('/token-artwork/'))return null;
  const fail=status=>new Response(null,{status,headers:{...security,'Cache-Control':'no-store','X-Robots-Tag':'noindex',...(status===405?{Allow:'GET, HEAD'}:{})}});
  if(!['GET','HEAD'].includes(request.method))return fail(405);
  const match=/^\/token-artwork\/([a-f0-9]{16})\/([a-f0-9]{32})$/.exec(u.pathname);
  if(!match || match[1]!==manifest.version || u.search)return fail(404);
  const key=new Request(origin+u.pathname),cache=typeof caches!=='undefined'?caches.default:null;
  const refresh=async record=>{
    const image=await download(record.source);
    if(cache){const saved=image.clone();saved.headers.set('Cache-Control','public, max-age=2592000');await cache.put(key,saved).catch(()=>{});}
    return image;
  };
  try{
    let hit;try{hit=await cache?.match(key);}catch{/* Cache loss must not hide available artwork. */}
    if(hit){
      if(hit.headers.get('X-Oath-Artwork')==='image' && Date.now()-Number(hit.headers.get('X-Oath-Artwork-Fetched'))>604800000 && ctx && !flights.has(match[2]) && flights.size<12){
        const stale=hit.clone();
        const flight=record(env,match[2]).then(r=>r?refresh(r):stale.clone()).catch(()=>stale.clone()).finally(()=>flights.delete(match[2]));
        flights.set(match[2],flight);ctx.waitUntil(flight);
      }
      const headers=new Headers(hit.headers);headers.set('Cache-Control',hit.headers.get('X-Oath-Artwork')==='image'?'public, max-age=86400':'public, max-age=60');return new Response(request.method==='HEAD'?null:hit.body,{headers});
    }
    const asset=await record(env,match[2]);if(!asset || !permittedArtworkURL(asset.source))return fail(404);
    let flight=flights.get(match[2]);
    if(!flight){
      if(flights.size>=64){const response=fallback(asset.initials);return new Response(request.method==='HEAD'?null:response.body,response);}
      flight=refresh(asset).catch(async()=>{
        const response=fallback(asset.initials);
        if(cache){const saved=response.clone();saved.headers.set('Cache-Control','public, max-age=60');await cache.put(key,saved).catch(()=>{});}
        return response;
      }).finally(()=>flights.delete(match[2]));flights.set(match[2],flight);
    }
    const response=(await flight).clone();return new Response(request.method==='HEAD'?null:response.body,response);
  }catch{return fail(503);}
}
