// Same-origin, bounded forwarding only. No signing keys, custody or analytics.
const MINTS=new Set(['2vb9ZGWvxXfb8vnBQMtM7VHPSG5FXqNHVx6wFTJ8zgya','EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v','Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB','So11111111111111111111111111111111111111112']);
const RPC_METHODS=new Set(['getGenesisHash','getAccountInfo','getMultipleAccounts','getBalance','getLatestBlockhash','getFeeForMessage',
  'getMinimumBalanceForRentExemption','isBlockhashValid','getSignatureStatuses','simulateTransaction','sendTransaction','getProgramAccounts']);
const CSP="default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; object-src 'none'";
function secured(response,type){
  const out=new Response(response.body,response);
  out.headers.set('X-Content-Type-Options','nosniff');out.headers.set('Referrer-Policy','no-referrer');
  out.headers.set('Content-Security-Policy',CSP);out.headers.set('X-Frame-Options','DENY');
  out.headers.set('Cache-Control','no-store');if(type)out.headers.set('Content-Type',type);
  return out;
}
const failure=(status,message)=>secured(Response.json({error:message},{status}));
async function boundedText(response,limit){
  if(!response.body)return '';
  const reader=response.body.getReader();const chunks=[];let size=0;
  try{for(;;){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>limit)throw Error('Too large');chunks.push(value);}}
  finally{await reader.cancel();}
  const data=new Uint8Array(size);let offset=0;for(const c of chunks){data.set(c,offset);offset+=c.length;}
  return new TextDecoder('utf-8',{fatal:true}).decode(data);
}
async function proxyRpc(request,env,fetchImpl){
  if(request.method!=='POST')return failure(405,'Use POST.');
  if(!request.headers.get('content-type')?.startsWith('application/json'))return failure(415,'JSON required.');
  const origin=request.headers.get('Origin');
  if(origin && origin!==new URL(request.url).origin)return failure(403,'Origin denied.');
  let body;
  try{body=JSON.parse(await boundedText(request,20000));}catch{return failure(400,'Invalid bounded JSON request.');}
  if(!body || Array.isArray(body) || body.jsonrpc!=='2.0' || !RPC_METHODS.has(body.method) ||
    !['number','string'].includes(typeof body.id) || String(body.id).length>80 ||
    (body.params!==undefined && (!Array.isArray(body.params) || body.params.length>3)))return failure(400,'Unsupported RPC request.');
  const p=body.params || [];
  if(body.method==='getProgramAccounts' && !(p[0]==='SQDS4ep65T869zMMBKyuUq6aD6EgTu8psMjkvj52pCf' &&
    JSON.stringify(p[1]?.filters)===JSON.stringify([{memcmp:{offset:0,bytes:'2odkUytTTsV'}},{memcmp:{offset:8,bytes:'d4qjQzFguG7cAkhG8wCqfJsQ1ftZeDY1B6i37CC8X6J'}}]) &&
    p[1]?.dataSlice?.offset===0 && p[1]?.dataSlice?.length===40))return failure(400,'Unsupported account query.');
  if(body.method==='getMultipleAccounts' && (!Array.isArray(p[0]) || p[0].length>80))return failure(400,'Too many accounts.');
  if(body.method==='getSignatureStatuses' && (!Array.isArray(p[0]) || p[0].length!==1))return failure(400,'One signature required.');
  if(['sendTransaction','simulateTransaction','getFeeForMessage'].includes(body.method) &&
    (typeof p[0]!=='string' || p[0].length>2000 || !/^[A-Za-z0-9+/]*={0,2}$/.test(p[0])))return failure(400,'Invalid transaction encoding.');
  // Forward exactly this allowlisted method; never a caller-provided URL or headers.
  const endpoint=env.OUSD_RPC_URL || 'https://api.mainnet-beta.solana.com';
  if(!endpoint.startsWith('https://'))return failure(503,'RPC unavailable.');
  try{
    // Workerd supports only follow/manual. Reject redirects without forwarding
    // the configured endpoint credential to another destination.
    const upstream=await fetchImpl(endpoint,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body),redirect:'manual',signal:AbortSignal.timeout(12000)});
    if(!upstream.ok)return failure(upstream.status===429?429:503,'RPC unavailable.');
    const text=await boundedText(upstream,4000000),parsed=JSON.parse(text);
    if(parsed?.error)return secured(Response.json({jsonrpc:'2.0',id:body.id,error:{
      code:Number.isSafeInteger(parsed.error.code)?parsed.error.code:-32603,message:'RPC request failed.',
    }}));
    return secured(new Response(text), 'application/json');
  }catch{return failure(503,'RPC unavailable.');}
}
async function reconcile(request,env,fetchImpl){
  if(request.method!=='POST')return failure(405,'Use POST.');
  let p;
  try{p=JSON.parse(await boundedText(request,2000));}catch{return failure(400,'Invalid request.');}
  if(!/^[1-9A-HJ-NP-Za-km-z]{80,90}$/.test(p?.signature) || !/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(p?.blockhash) ||
    !Number.isSafeInteger(p?.lastValidBlockHeight) || p.lastValidBlockHeight<=0)return failure(400,'Invalid pending transaction.');
  const endpoints=[env.OUSD_RPC_URL || 'https://api.mainnet-beta.solana.com','https://solana-rpc.publicnode.com'];
  try{
    if(!endpoints.every(url=>typeof url==='string' && new URL(url).protocol==='https:') ||
      new URL(endpoints[0]).hostname===new URL(endpoints[1]).hostname)return failure(503,'Independent confirmation unavailable.');
  }catch{return failure(503,'Independent confirmation unavailable.');}
  try{
    const results=await Promise.all(endpoints.map(async url=>{
      async function call(method,params=[]){const r=await fetchImpl(url,{method:'POST',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({jsonrpc:'2.0',id:1,method,params}),redirect:'manual',signal:AbortSignal.timeout(10000)});
        if(!r.ok)throw Error('Unavailable');
        const body=JSON.parse(await boundedText(r,10000));if(body.error)throw Error('Unavailable');return body.result;}
      if(await call('getGenesisHash')!=='5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d')throw Error('Wrong network');
      const status=await call('getSignatureStatuses',[[p.signature],{searchTransactionHistory:true}]);
      if(status.value[0])return false;
      const [height,valid]=await Promise.all([call('getBlockHeight',[{commitment:'finalized'}]),call('isBlockhashValid',[p.blockhash,{commitment:'confirmed'}])]);
      if(!(Number.isSafeInteger(height) && height>p.lastValidBlockHeight && valid.value===false))return false;
      const final=await call('getSignatureStatuses',[[p.signature],{searchTransactionHistory:true}]);
      return final.value[0]===null && Number.isSafeInteger(final.context?.slot) && Number.isSafeInteger(valid.context?.slot) &&
        final.context.slot>=valid.context.slot;
    }));
    return secured(Response.json({expiredAbsent:results.every(Boolean)}));
  }catch{return failure(503,'Confirmation unavailable.');}
}
async function proxyRoute(request,env,fetchImpl){
  if(request.method!=='GET')return failure(405,'Use GET.');
  const q=new URL(request.url).searchParams;
  const allowed=['inputMint','outputMint','amount','taker','slippageBps','dexes','platformFeeBps','wrapAndUnwrapSol','transactionVersion','maxAccounts'];
  if([...q.keys()].some(k=>!allowed.includes(k) || q.getAll(k).length!==1) || allowed.some(k=>!q.has(k)))return failure(400,'Invalid route request.');
  if(!MINTS.has(q.get('inputMint')) || !MINTS.has(q.get('outputMint')) ||
    ![q.get('inputMint'),q.get('outputMint')].includes('2vb9ZGWvxXfb8vnBQMtM7VHPSG5FXqNHVx6wFTJ8zgya') ||
    q.get('inputMint')===q.get('outputMint') || !/^[1-9]\d{0,19}$/.test(q.get('amount')) ||
    BigInt(q.get('amount'))>((1n<<64n)-1n) || !/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(q.get('taker')) ||
    !/^\d{1,3}$/.test(q.get('slippageBps')) || Number(q.get('slippageBps'))>100 ||
    q.get('dexes')!=='Raydium CP,Raydium CLMM' || q.get('platformFeeBps')!=='0' ||
    q.get('wrapAndUnwrapSol')!=='false' || q.get('transactionVersion')!=='0' || q.get('maxAccounts')!=='64')return failure(400,'Unsupported route.');
  try{
    const headers={Accept:'application/json'};if(env.OUSD_JUPITER_API_KEY)headers['x-api-key']=env.OUSD_JUPITER_API_KEY;
    const response=await fetchImpl(`https://api.jup.ag/swap/v2/build?${q}`,{headers,redirect:'manual',signal:AbortSignal.timeout(10000)});
    if(response.status>=300 && response.status<400)return failure(503,'Route service unavailable.');
    const text=await boundedText(response,250000);JSON.parse(text);
    return secured(new Response(text,{status:response.status}),'application/json');
  }catch{return failure(503,'Route service unavailable.');}
}
export async function handleOusd(request,env,fetchImpl=fetch){
  const url=new URL(request.url);
  if(url.pathname!=='/ousd' && !url.pathname.startsWith('/ousd/'))return null;
  const production=['oathwallet.org','www.oathwallet.org'].includes(url.hostname);
  if(production && (url.protocol!=='https:' || url.hostname==='www.oathwallet.org')){
    url.protocol='https:';url.hostname='oathwallet.org';return Response.redirect(url,308);}
  if(!production && !['localhost','127.0.0.1'].includes(url.hostname))return failure(404,'Not found.');
  if(url.pathname.startsWith('/ousd/api/')){
    // Existing Cloudflare rate limiter; raw IP stays only in the limiter key.
    if(env.VISITOR_LIMITER){const result=await env.VISITOR_LIMITER.limit({key:`ousd:${request.headers.get('CF-Connecting-IP') || 'unknown'}`});
      if(!result.success)return failure(429,'Please wait before trying again.');}
    if(url.pathname==='/ousd/api/rpc')return proxyRpc(request,env,fetchImpl);
    if(url.pathname==='/ousd/api/route')return proxyRoute(request,env,fetchImpl);
    if(url.pathname==='/ousd/api/reconcile')return reconcile(request,env,fetchImpl);
    return failure(404,'Not found.');
  }
  if(!['GET','HEAD'].includes(request.method))return failure(405,'Use GET.');
  if(url.pathname==='/ousd/'){url.pathname='/ousd';return Response.redirect(url,308);}
  if(url.pathname==='/ousd')url.pathname='/ousd/index.html';
  const response=await env.ASSETS.fetch(new Request(url,request));
  return secured(response);
}
