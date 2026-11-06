import manifest from './tokens-manifest.json' with {type:'json'};
import {wantsMarkdown} from './agent-content.js';

const origin='https://oathwallet.org';
const download='https://apps.apple.com/us/app/oath-bitcoin-crypto-wallet/id6780187283';
export const escapeHTML=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const h=escapeHTML, count=n=>n.toLocaleString('en-US');
const networks=Object.values(manifest.networks);
const link=(url,label,cls='')=>`<a${cls?` class="${cls}"`:''} href="${h(url)}">${h(label)}</a>`;
const badge=id=>{const n=manifest.networks[id];return `<span class="token-badge"><img src="${h(n.icon)}" alt="" width="20" height="20">${h(n.name)}</span>`;};
const cache=new WeakMap();
export async function cachedTokens(request,env,ctx){
  const u=new URL(request.url);
  const eligible=ctx&&typeof caches!=='undefined'&&u.origin===origin&&request.method==='GET'&&!wantsMarkdown(request.headers.get('Accept')||'')&&/^\/(?:tokens(?:\/|$)|networks\/[^/]+\/tokens$)/.test(u.pathname)&&!u.pathname.includes('.')&&[...u.searchParams.keys()].every(k=>k==='page');
  if(!eligible)return handleTokens(request,env);
  const key=new Request(`${origin}/_token-cache/${manifest.version}${u.pathname}${u.search}`,{headers:{Accept:'text/html'}});
  try{const hit=await caches.default.match(key);if(hit)return hit;}catch{/* A cache outage must not prevent serving the accepted snapshot. */}
  const response=await handleTokens(request,env);
  if(response?.status===200&&response.headers.get('Content-Type')?.includes('text/html')&&!response.headers.has('X-Robots-Tag')){
    const saved=response.clone();saved.headers.set('Cache-Control','public, max-age=3600');
    ctx.waitUntil(caches.default.put(key,saved).catch(()=>{}));
  }
  return response;
}
async function data(env,path){
  // Cache accepted public data only. Keep at most 16 small shards plus one search
  // index per isolate; failed reads are never cached or presented as empty pages.
  let entries=cache.get(env.ASSETS);if(!entries){entries=new Map();cache.set(env.ASSETS,entries);}
  if(entries.has(path)){const value=entries.get(path);entries.delete(path);entries.set(path,value);return value;}
  const response=await env.ASSETS.fetch(new Request(origin+manifest.prefix+'/'+path));
  if(!response.ok)throw Error('Catalog unavailable');
  const value=await response.json();entries.set(path,value);
  while(entries.size>17)entries.delete(entries.keys().next().value);
  return value;
}
async function coin(env,slug){
  const hash=new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(slug)));
  const shard=hash[0].toString(16).padStart(2,'0');
  const shardData=await data(env,`coins/${shard}.json`);
  return Object.hasOwn(shardData,slug)?shardData[slug]:undefined;
}
const sourceNote=()=>`<p class="token-source">Catalog snapshot ${h(manifest.source.date)} · Oath ${h(manifest.source.version)} (${manifest.source.build}). ${link(`https://github.com/OathWallet/oath-wallet/blob/${manifest.source.revision}/Packages/OathAnkr/Sources/OathAnkr/Resources/TokenDiscoverySeed.json`,'View the released catalog')}.</p>`;
const listingNote='<p class="token-notice">A catalog listing means an asset appears in Oath’s discovery source. It does not mean issuer verification, safety approval or individually tested sending. Availability depends on your account, app version and the token’s rules.</p>';
export function tokenRows(rows){return `<ul class="token-list">${rows.map(a=>`<li><a class="token-row" href="${h(a.path)}"><span class="token-monogram" aria-hidden="true">${h(Array.from(a.symbol).slice(0,2).join(''))}</span><span class="token-row-name"><strong>${h(a.name)}</strong><span>${h(a.symbol)}</span></span><span class="token-networks">${(a.networks||[a.network]).slice(0,3).map(badge).join('')}${a.networks?.length>3?`<span class="token-badge">+${a.networks.length-3} networks</span>`:''}</span></a></li>`).join('')}</ul>`;}
function pager(path,page,total,query=''){
  const href=p=>path+((p>1||query)?'?'+[query,p>1?'page='+p:''].filter(Boolean).join('&'):'');
  return `<nav class="token-pagination" aria-label="Pagination">${page>1?link(href(page-1),'Previous','token-button'):''}<span>Page ${page} of ${total}</span>${page<total?link(href(page+1),'Next','token-button'):''}</nav>`;
}
function form(q='',network=''){
  return `<form class="token-search" action="/tokens" method="get" role="search"><div><label for="token-query">Find a token</label><input id="token-query" name="q" type="search" maxlength="160" value="${h(q)}" placeholder="Name, symbol or full token identifier"></div><div><label for="token-network">Network</label><select id="token-network" name="network"><option value="">All networks</option>${networks.map(n=>`<option value="${h(n.id)}"${network===n.id?' selected':''}>${h(n.name)} (${count(n.count)})</option>`).join('')}</select></div><button class="token-button" type="submit">Search</button>${q?link('/tokens','Clear search'):''}</form>`;
}
const identifierLabel=n=>({solana:'Token mint',ton:'Jetton master',stellar:'Contract or asset and issuer',xrpl:'Currency and issuer',near:'Token account',aptos:'Coin type or fungible asset',sui:'Coin type',polkadot:'Asset reference',thorchain:'Asset denomination'}[n]||'Token contract');
function priorityText(c,a,n){
  if(!['tether','usd-coin'].includes(c.coinID))return '';
  const name=c.coinID==='tether'?'USDT':'USDC';
  const specific=a.network==='tron'?'For USDT on TRON, select the TRON network (often labelled TRC-20 by exchanges). Sending ERC-20 USDT to this receiving flow is not the same transfer. TRON’s bandwidth and energy requirements can result in a TRX charge.':a.network==='base'?'For USDC on Base, the sender must withdraw on Base. An Ethereum address can look identical, but an Ethereum mainnet transfer does not arrive on Base. Keep ETH on Base for a later token transfer.':a.network==='solana'?'For USDC on Solana, select Solana at the sending service and compare the mint below. SOL is used for transaction fees and, where required, token-account creation. An EVM address is not a Solana receiving address.':`Select ${n.name} on both sides of the transfer. ${name} on a different network may use a different contract, mint or issuer. A transfer does not bridge funds automatically.`;
  const issuer=c.coinID==='tether'?['https://tether.to/en/supported-protocols/','Tether supported protocols']:['https://developers.circle.com/stablecoins/usdc-contract-addresses','Circle USDC contract addresses'];
  return `<section><h2>Choose the right ${name} network</h2><p>${h(specific)}</p><p>Compare the exact identifier with the sending service and the issuer’s current information. The catalog’s grouping is not proof that every version is directly issued or redeemable by the issuer. Wrapped and bridged assets have their own issuer or bridge risks.</p><p>${link(issuer[0],issuer[1])}</p></section>`;
}
export function detailContent(c,a){
  const n=manifest.networks[a.network];
  const title=`${a.name} (${a.symbol}) on ${n.name}`;
  const fee=n.symbol;
  const related=c.assets.filter(x=>x.path!==a.path);
  const content=`<header class="token-hero"><p class="token-eyebrow">${badge(n.id)} · Token guide</p><h1>${h(title)}</h1><p>Find this exact ${h(a.symbol)} asset in Oath’s catalog, check its network and prepare to receive it on iPhone or iPad.</p>${link(download,'Get Oath for iPhone','token-button')}</header>
  <section class="token-identity"><h2>Check the identity</h2><dl><div><dt>Asset</dt><dd>${h(a.name)} (${h(a.symbol)})</dd></div><div><dt>Network</dt><dd>${link('/networks/'+n.slug,n.name)}${n.chainId?' · Chain ID '+n.chainId:''}</dd></div><div><dt>${identifierLabel(a.network)}</dt><dd><code dir="ltr">${h(a.reference)}</code></dd></div>${a.decimals!=null&&a.network!=='xrpl'?`<div><dt>Catalog decimals</dt><dd>${a.decimals}</dd></div>`:''}<div><dt>Catalog asset ID</dt><dd><code>${h(c.coinID)}</code></dd></div></dl><p><strong>This token identifier is not your receiving address.</strong> Copy your personal address from Receive in Oath. Never send funds to the contract, mint or issuer shown here.</p></section>
  ${priorityText(c,a,n)}
  <div class="token-columns"><section><h2>Receive ${h(a.symbol)} on ${h(n.name)}</h2><ol><li>Open Oath, select your wallet and open Receive.</li><li>Choose ${h(n.name)} and find ${h(a.name)} (${h(a.symbol)}). Match the full identifier above; symbols can be shared by unrelated assets.</li><li>Use the receiving address or QR code shown in the app. Confirm the exact network with the sender and include any required memo or tag.</li><li>Check that the sender and your account support this token before transferring. For a first transfer, start with a small amount.</li></ol><p>${h(n.receive)}</p></section>
  <section><h2>Sending and fees</h2><p>${h(n.send)}</p><p>The network’s fee asset is ${h(fee)}. Receiving an ordinary transfer does not mean you can send it without a fee balance. Account activation, reserves, storage or token-account creation can add requirements.</p><p>Select the exact asset in Oath, choose Send if available, and review the destination, amount and final fee. Token-specific restrictions, missing metadata or unsupported token extensions can prevent a transfer; catalog presence alone is not a sending test.</p></section></div>
  <section><h2>What this listing covers</h2><p>This entry is discoverable on ${h(n.name)} in the released catalog. Oath provides the network’s receive and supported-asset transfer flows. WalletConnect ${n.walletConnect?'is available for compatible '+h(n.name)+' requests; it does not guarantee a dApp supports this token.':'is not listed as available for this network in this guide.'}</p><p>Check issuer restrictions before using an asset. A token can be paused, frozen, transfer-restricted or subject to eligibility requirements. Bridged and wrapped tokens remain separate assets; a familiar name or symbol does not establish backing or redemption rights.</p>${listingNote}</section>
  ${related.length?`<section><h2>Other networks in this asset group</h2><p>Grouped by the catalog asset ID, not by symbol. Compare each network’s exact identifier.</p>${tokenRows(related)}</section>`:''}
  <section><h2>Continue exploring</h2><p>${link('/networks/'+n.slug+'/tokens','All '+n.name+' tokens')} · ${link('/networks/'+n.slug,n.name+' network guide')} · ${link('https://www.coingecko.com/en/coins/'+encodeURIComponent(c.coinID),'Catalog provider asset record')}</p><h3>More on ${h(n.name)}</h3>${tokenRows(n.featured.filter(x=>x.path!==a.path).slice(0,4))}</section>${sourceNote()}`;
  return {title:`${a.symbol} Wallet on ${n.name} for iPhone | ${a.name} | Oath`,description:`${a.name} (${a.symbol}) on ${n.name}: exact token identity, Oath receiving steps, ${fee} fee requirements and transfer limitations. Compare networks before sending.`,heading:title,content};
}
function markdown(html){return html.replace(/<img\b[^>]*>/g,'').replace(/<a\b[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/g,(_,u,t)=>`[${t.replace(/<[^>]*>/g,'')}](${u.startsWith('/')?origin:''}${u})`).replace(/<h([1-6])[^>]*>([\s\S]*?)<\/h\1>/g,(_,n,t)=>'\n\n'+'#'.repeat(+n)+' '+t+'\n\n').replace(/<li>/g,'\n- ').replace(/<\/(?:p|section|div|dl|dd|header|form|nav)>/g,'\n\n').replace(/<dt>/g,'\n').replace(/<\/dt>/g,': ').replace(/<[^>]+>/g,'').replace(/&(?:amp|lt|gt|quot|#39);/g,s=>({'&amp;':'&','&lt;':'<','&gt;':'>','&quot;':'"','&#39;':"'"}[s])).replace(/\n{3,}/g,'\n\n').trim();}
async function pageResponse(request,env,model,path,{status=200,noindex=false,md=false,crumbs=[]}={}){
  const canonical=origin+path;
  const headers={'Content-Type':md?'text/markdown; charset=utf-8':'text/html; charset=utf-8','Cache-Control':noindex||status!==200?'no-store':'public, max-age=300, stale-while-revalidate=3600','Vary':'Accept','X-Content-Type-Options':'nosniff','Link':`<${canonical}>; rel="canonical"`};
  if(noindex||md||status!==200)headers['X-Robots-Tag']='noindex, follow';
  if(md){headers['Access-Control-Allow-Origin']='*';return new Response(request.method==='HEAD'?null:`Canonical: ${canonical}\n\n${markdown(model.content)}\n`,{status,headers});}
  const chrome=await data(env,'chrome.json');
  const trail=[['/', 'Home'],['/tokens','Tokens'],...crumbs];
  const schema={'@context':'https://schema.org','@graph':[{'@type':'WebPage','@id':canonical,url:canonical,name:model.title,description:model.description,inLanguage:'en',isPartOf:{'@id':origin+'/#website'}},{'@type':'BreadcrumbList',itemListElement:trail.map(([p,name],i)=>({'@type':'ListItem',position:i+1,name,item:origin+p}))}]};
  const mdpath=path.split('?')[0]+'.md'+(path.includes('?')?'?'+path.split('?')[1]:'');
  headers.Link+=`, <${origin+mdpath}>; rel="alternate"; type="text/markdown"`;
  const html=`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${h(model.title)}</title><meta name="description" content="${h(model.description)}"><meta name="robots" content="${noindex||status!==200?'noindex':'index'},follow"><link rel="canonical" href="${h(canonical)}"><meta property="og:title" content="${h(model.title)}"><meta property="og:description" content="${h(model.description)}"><meta property="og:url" content="${h(canonical)}"><meta property="og:type" content="website"><link rel="icon" href="/favicon.ico"><link rel="stylesheet" href="/site-chrome.css"><link rel="stylesheet" href="/tokens.css"><script src="/site-chrome.js" defer></script><script type="application/ld+json">${JSON.stringify(schema).replace(/</g,'\\u003c')}</script></head><body><a class="token-skip" href="#main">Skip to content</a>${chrome.header}<main id="main" class="token-main" tabindex="-1"><nav class="token-breadcrumbs" aria-label="Breadcrumb">${trail.map(([p,t])=>link(p,t)).join('<span aria-hidden="true">/</span>')}</nav>${model.content}</main>${chrome.footer}</body></html>`;
  return new Response(request.method==='HEAD'?null:html,{status,headers});
}
export async function handleTokens(request,env){
  const u=new URL(request.url);
  if(!/^\/tokens(?:\/|$|\.(?:md|html)$)/.test(u.pathname)&&!/^\/networks\/[^/]+\/tokens(?:[/.]|$)/.test(u.pathname)&&!u.pathname.startsWith('/token-data/'))return null;
  if(!['GET','HEAD'].includes(request.method))return new Response(null,{status:405,headers:{Allow:'GET, HEAD','Cache-Control':'no-store'}});
  if(u.pathname.startsWith('/token-data/')){const r=await env.ASSETS.fetch(request);const headers=new Headers(r.headers);headers.set('X-Robots-Tag','noindex');headers.set('Cache-Control',r.ok?'public, max-age=31536000, immutable':'no-store');return new Response(request.method==='HEAD'?null:r.body,{status:r.status,headers});}
  const explicitMD=u.pathname.endsWith('.md'), md=explicitMD||wantsMarkdown(request.headers.get('Accept')||'');
  let path=u.pathname.replace(/\.md$/,'');
  const redirect=target=>new Response(null,{status:308,headers:{Location:origin+target,'Cache-Control':'public, max-age=300'}});
  const failure=status=>pageResponse(request,env,{title:status===404?'Token page not found | Oath':'Catalog temporarily unavailable | Oath',description:'Browse Oath’s released token catalog.',content:`<header class="token-hero"><h1>${status===404?'This token page is unavailable.':'Please try again shortly.'}</h1><p>${status===404?'The requested identity or page is not in the published catalog.':'The published catalog could not be loaded.'}</p>${link('/tokens','Browse tokens')}</header>`},path,{status,noindex:true,md});
  try{
    if(path.endsWith('/')||path.endsWith('.html'))return redirect(path.replace(/\/$/,'').replace(/\.html$/,'')+u.search);
    const rawpage=u.searchParams.get('page')||'1';
    if(!/^[1-9][0-9]{0,5}$/.test(rawpage))return failure(404);
    const page=Number(rawpage);
    if(path==='/tokens/documents.json'){
      if(page>manifest.documentPages)return failure(404);
      const body=await data(env,`documents/${page}.json`);
      return new Response(request.method==='HEAD'?null:JSON.stringify(body),{headers:{'Content-Type':'application/json; charset=utf-8','X-Robots-Tag':'noindex','Cache-Control':'public, max-age=300','Access-Control-Allow-Origin':'*'}});
    }
    const match=/^\/networks\/([a-z0-9-]+)\/tokens$/.exec(path);
    if(path==='/tokens'||match){
      const network=match?networks.find(n=>n.slug===match[1]):null;
      if(match&&!network)return failure(404);
      const q=(u.searchParams.get('q')||'').trim();
      const filter=u.searchParams.get('network')||network?.id||'';
      if(q.length>160 || (filter&&!manifest.networks[filter]))return failure(404);
      if(filter&&!q&&(!network||network.id!==filter))return redirect('/networks/'+manifest.networks[filter].slug+'/tokens'+(page>1?'?page='+page:''));
      let rows,total,pages;
      if(q){
        const words=q.toLocaleLowerCase('en').split(/\s+/);
        const matches=(await data(env,'search.json')).filter(a=>(!filter||a[3]===filter)&&words.every(w=>[a[0],a[1],a[4],a[5]].some(x=>x.toLocaleLowerCase('en').includes(w))));
        total=matches.length;pages=Math.max(1,Math.ceil(total/50));
        rows=matches.slice((page-1)*50,page*50).map(a=>({name:a[0],symbol:a[1],path:a[2],network:a[3]}));
      }else{total=network?.count||manifest.coinCount;pages=network?.pages||manifest.pages;if(page<=pages)rows=await data(env,network?`networks/${network.slug}/${page}.json`:`directory/${page}.json`);}
      if(page>pages)return failure(404);
      const query=q?new URLSearchParams({q,...filter?{network:filter}:{}}).toString():'';
      const canonical=path+(page>1?'?page='+page:'');
      if(!q&&u.searchParams.has('page')&&page===1)return redirect(path+(explicitMD?'.md':''));
      const title=q?'Search the token catalog':network?`${network.name} tokens`:'Find your token. Choose its network.';
      const description=network?`Browse ${count(total)} ${network.name} token entries from Oath’s released catalog, with exact identifiers and network fee guidance.`:`Explore ${count(manifest.coinCount)} assets and ${count(manifest.count)} token/network entries across ${networks.length} networks in Oath’s released catalog.`;
      const content=`<header class="token-hero"><p class="token-eyebrow">${network?badge(network.id):'Oath token catalog'}</p><h1>${h(title)}</h1><p>${h(description)}</p>${network?`<p>${link('/networks/'+network.slug,network.symbol+' native coin and network guide')}</p>`:''}</header>${form(q,filter)}${!network&&!q&&page===1?'<nav class="token-priority" aria-label="Popular token guides">'+link('/tokens/usdt','USDT wallet')+link('/tokens/usdc','USDC wallet')+link('/tokens/usdt/tron','USDT on TRON')+link('/tokens/usdc/base','USDC on Base')+link('/tokens/usdc/solana','USDC on Solana')+'</nav>':''}<section aria-labelledby="results"><h2 id="results">${count(total)} ${q?'matching token entries':network?'token entries':'assets'}${page>1?' · Page '+page:''}</h2>${total?tokenRows(rows):'<p>No entries match this search. Try another name or the full token identifier.</p>'}${pager(path,page,pages,query)}</section>${listingNote}${sourceNote()}`;
      return pageResponse(request,env,{title:`${q?'Token search':network?network.name+' token catalog':'Crypto token catalog'}${page>1?' · Page '+page:''} | Oath`,description,content},canonical,{md,noindex:!!q,crumbs:network?[[path,network.name+' tokens']]:[]});
    }
    const parts=/^\/tokens\/([a-z0-9-]+)(?:\/([a-z0-9-]+))?$/.exec(path);
    if(!parts)return failure(404);
    const c=await coin(env,parts[1]);if(!c)return failure(404);
    if(parts[2]){const a=c.assets.find(a=>a.path===path);if(!a)return failure(404);return pageResponse(request,env,detailContent(c,a),path,{md,crumbs:[['/tokens/'+c.slug,c.name],[path,manifest.networks[a.network].name]]});}
    if(c.assets.length===1)return redirect(c.assets[0].path+(explicitMD?'.md':''));
    const description=`Compare ${c.name} (${c.symbol}) on ${c.assets.length} networks in Oath. Choose the exact network to check its token identifier, receiving steps and fee requirements.`;
    return pageResponse(request,env,{title:`${c.symbol} Wallet for iPhone | ${c.name} Networks | Oath`,description,content:`<header class="token-hero"><p class="token-eyebrow">${c.assets.length} networks · One catalog asset group</p><h1>${h(c.name)} (${h(c.symbol)}) wallet for iPhone</h1><p>${h(description)}</p>${link(download,'Get Oath for iPhone','token-button')}</header><section><h2>Choose your network</h2><p>The sender and recipient must use the same network. These entries share the catalog’s asset ID; each has its own token identity. Bridged versions and separate issuer records are kept distinct.</p>${tokenRows(c.assets)}</section>${listingNote}${sourceNote()}`},path,{md,crumbs:[[path,c.name]]});
  }catch{return new Response(request.method==='HEAD'?null:'The catalog is temporarily unavailable. Please try again shortly.',{status:503,headers:{'Content-Type':'text/plain; charset=utf-8','Cache-Control':'no-store','X-Robots-Tag':'noindex','Retry-After':'60'}});}
}
