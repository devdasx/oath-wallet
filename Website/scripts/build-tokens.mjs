import {artworkSnapshot,attachArtwork} from './token-artwork.mjs';
import {tokenArtwork} from '../src/token-artwork.js';
import {readFile,writeFile,mkdir,rm,rename,readdir} from 'node:fs/promises';
import {gunzipSync} from 'node:zlib';
import {buildSiteChrome} from './build-help-chrome.mjs';
import {validateSnapshot,assignRoutes,digest,identity,readLedger,writeLedger} from './token-catalog.mjs';
import networks from '../content/networks.json' with {type:'json'};

const base=new URL('../',import.meta.url), root=new URL('public/',base);
const source=validateSnapshot(JSON.parse(gunzipSync(await readFile(new URL('content/tokens/source.json.gz',base)))));
source.networks=networks.networks.filter(n=>source.enabled.includes(n.id));
if(source.networks.length!==source.enabled.length)throw Error('Released networks differ from the website catalog; reconcile before publication.');
const ledgerFile=new URL('content/tokens/routes.json',base);
let previous;
try{previous=readLedger(JSON.parse(await readFile(ledgerFile)));}catch(e){if(e.code!=='ENOENT')throw e;}
const {ledger,rows:baseRows}=assignRoutes(source,previous);
const artwork=await artworkSnapshot(), rows=attachArtwork(baseRows,artwork);
const template=await Promise.all(['src/artwork-manifest.json','src/token-artwork.js','public/token-artwork.css','src/tokens.js','src/transfer-preparation.js','src/seo-guidance.js','content/priority-guidance.json','public/seo-guidance.css','public/tokens.css','public/Oath Header.dc.html','public/Oath Footer.dc.html'].map(p=>readFile(new URL(p,base),'utf8')));
const version=digest(JSON.stringify({source,ledger,template})).slice(0,16), prefix=`/token-data/${version}`;
const stage=new URL('public/token-data-next/',base);
await rm(stage,{recursive:true,force:true});await mkdir(stage,{recursive:true});
const put=async(path,data)=>{const file=new URL(path,stage);await mkdir(new URL('.',file),{recursive:true});await writeFile(file,typeof data==='string'?data:JSON.stringify(data));};
const coins=new Map(), byNetwork=new Map(), byPath=new Map();
for(const row of rows){
  if(!coins.has(row.slug))coins.set(row.slug,{slug:row.slug,coinID:row.coinID,name:row.name,symbol:row.symbol,assets:[]});
  coins.get(row.slug).assets.push(row);
  if(!byNetwork.has(row.network))byNetwork.set(row.network,[]);
  byNetwork.get(row.network).push(row);byPath.set(row.path,row);
}
const order=(a,b)=>a.name.localeCompare(b.name,'en')||a.symbol.localeCompare(b.symbol,'en')||(a.path||a.slug).localeCompare(b.path||b.slug,'en');
const summaries=[...coins.values()].sort(order).map(c=>({name:c.name,symbol:c.symbol,slug:c.slug,artwork:c.assets.find(a=>a.artwork)?.artwork,path:c.assets.length===1?c.assets[0].path:'/tokens/'+c.slug,networks:c.assets.map(a=>a.network)}));
const shards={};
for(const coin of coins.values()){
  coin.artwork=coin.assets.find(a=>a.artwork)?.artwork;
  const shard=digest(coin.slug).slice(0,2);(shards[shard]??={})[coin.slug]=coin;
}
for(const [id,data]of Object.entries(shards))await put(`coins/${id}.json`,data);
const pageSize=50, allURLs=[];
const addURL=(path,kind,network)=>allURLs.push({path,kind,...network?{network}:{}});
for(let offset=0;offset<summaries.length;offset+=pageSize){
  const page=1+offset/pageSize;await put(`directory/${page}.json`,summaries.slice(offset,offset+pageSize));
  addURL('/tokens'+(page===1?'':`?page=${page}`),'directory');
}
const networkInfo={};
for(const n of source.networks){
  const assets=(byNetwork.get(n.id)||[]).sort(order);
  if(!assets.length)continue;
  const ranked=(source.featured[n.id]||[]).map(f=>assets.find(a=>identity(a)===f.id || (n.group==='EVM'&&identity(a)===f.id.toLowerCase()))).filter(Boolean);
  const featured=[...ranked,...assets.filter(a=>!ranked.includes(a))].slice(0,12);
  networkInfo[n.id]={...n,count:assets.length,pages:Math.ceil(assets.length/pageSize),featured};
  for(let offset=0;offset<assets.length;offset+=pageSize){
    const page=1+offset/pageSize;await put(`networks/${n.slug}/${page}.json`,assets.slice(offset,offset+pageSize));
    addURL(`/networks/${n.slug}/tokens`+(page===1?'':`?page=${page}`),'network-directory',n.id);
  }
}
for(const coin of coins.values()){
  if(coin.assets.length>1)addURL('/tokens/'+coin.slug,'token-hub');
  for(const a of coin.assets)addURL(a.path,'token',a.network);
}
// A compact server-side index; clients receive only the matching page of results.
await put('search.json',rows.map(a=>[a.name,a.symbol,a.path,a.network,a.reference,a.coinID,a.artwork||null]));
const chrome=await buildSiteChrome();
await put('chrome.json',{header:chrome.header,footer:chrome.footer});
const manifest={format:1,version,prefix,pageSize,count:rows.length,coinCount:coins.size,
  hubCount:[...coins.values()].filter(c=>c.assets.length>1).length,pages:Math.ceil(summaries.length/pageSize),
  source:{version:source.version,build:source.build,revision:source.revision,sha256:source.sha256,date:source.sourceDate},
  networks:networkInfo,nativeOnly:source.nativeOnly,enabled:source.enabled,
  samples:[...Object.values(networkInfo).map(n=>n.featured[0].path),'/tokens/usdt','/tokens/usdc','/tokens/usdt/tron','/tokens/usdc/base','/tokens/usdc/solana'],
  documents:'/tokens/documents.json'};
await put('manifest.json',manifest);
await put('routes.json',allURLs);
// Bounded discovery batches are useful to tools without inflating the existing document index.
for(let offset=0;offset<allURLs.length;offset+=100){
  const page=1+offset/100;
  await put(`documents/${page}.json`,{documents:allURLs.slice(offset,offset+100).map(r=>({url:'https://oathwallet.org'+r.path,markdown_url:'https://oathwallet.org'+r.path.split('?')[0]+'.md'+(r.path.includes('?')?'?'+r.path.split('?')[1]:''),kind:r.kind})),next:offset+100<allURLs.length?`https://oathwallet.org/tokens/documents.json?page=${page+1}`:null});
}
manifest.documentPages=Math.ceil(allURLs.length/100);await put('manifest.json',manifest);
const target=new URL(`token-data/${version}/`,root);await mkdir(new URL('token-data/',root),{recursive:true});
await rm(target,{recursive:true,force:true});await rename(stage,target);
for(const old of await readdir(new URL('token-data/',root)))if(old!==version)await rm(new URL('token-data/'+old,root),{recursive:true,force:true});
await writeFile(new URL('src/tokens-manifest.json',base),JSON.stringify(manifest,null,2)+'\n');
await writeFile(ledgerFile,JSON.stringify(writeLedger(ledger))+'\n');

// The regular SEO builder has just emitted the canonical core sitemap.
const xmlEscape=s=>s.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
const htmlEscape=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
for(const n of source.networks){
  const file=new URL(`networks/${n.slug}.html`,root),mdFile=new URL(`networks/${n.slug}.md`,root);
  let html=await readFile(file,'utf8'),md=await readFile(mdFile,'utf8');
  html=html.replace(/<!-- token-catalog:start -->[\s\S]*?<!-- token-catalog:end -->/g,'');
  md=md.replace(/\n<!-- token-catalog:start -->[\s\S]*?<!-- token-catalog:end -->\n?/g,'');
  const info=networkInfo[n.id];
  if(info){
    const section=`<!-- token-catalog:start --><section class="network-token-section" aria-labelledby="network-tokens"><h2 id="network-tokens">Tokens on ${htmlEscape(n.name)}</h2><p>Native coin: ${htmlEscape(n.symbol)}. Browse ${info.count.toLocaleString('en-US')} token entries from Oath’s released discovery catalog.</p><ul class="token-list">${info.featured.map(a=>`<li><a class="token-row" href="${a.path}">${tokenArtwork(a)}<span class="token-row-name"><strong>${htmlEscape(a.name)}</strong><span>${htmlEscape(a.symbol)}</span></span><span class="token-badge">${htmlEscape(n.name)}</span></a></li>`).join('')}</ul><p><a href="/networks/${n.slug}/tokens">Browse all ${htmlEscape(n.name)} tokens</a></p><p class="token-notice">Catalog inclusion is not issuer verification, safety approval or individually tested sending. Match the exact network and token identifier.</p></section><!-- token-catalog:end -->`;
    html=html.replace('</main>',section+'</main>');
    if(!html.includes('href="/token-artwork.css"'))html=html.replace('</head>','<link rel="stylesheet" href="/token-artwork.css"><script src="/token-artwork.js" defer></script></head>');
    if(!html.includes('href="/tokens.css"'))html=html.replace('</head>','<link rel="stylesheet" href="/tokens.css"></head>');
    md+=`\n<!-- token-catalog:start -->\n## Tokens on ${n.name}\n\nNative coin: ${n.symbol}. ${info.count} catalog token entries.\n\n${info.featured.map(a=>`- [${a.name} (${a.symbol}) on ${n.name}](https://oathwallet.org${a.path})`).join('\n')}\n\n[Browse all ${n.name} tokens](https://oathwallet.org/networks/${n.slug}/tokens). Catalog inclusion is not issuer verification or individually tested sending.\n<!-- token-catalog:end -->\n`;
  }
  await writeFile(file,html);await writeFile(mdFile,md);
}
await mkdir(new URL('sitemaps/',root),{recursive:true});
let core=await readFile(new URL('sitemap.xml',root),'utf8');
if(core.includes('<sitemapindex'))core=await readFile(new URL('sitemaps/pages.xml',root),'utf8');
core=core.replace(/<url>[\s\S]*?<\/url>/g,block=>{
  if(!Object.values(networkInfo).some(n=>block.includes(`<loc>https://oathwallet.org/networks/${n.slug}</loc>`)))return block;
  const existing=block.match(/<lastmod>([^<]+)<\/lastmod>/)?.[1]||'';
  const modified=[existing,source.updatedDate].sort().at(-1);
  return block.replace(/<lastmod>[^<]+<\/lastmod>/,'').replace('</url>',`<lastmod>${modified}</lastmod></url>`);
});
await writeFile(new URL('sitemaps/pages.xml',root),core);
const maps=['https://oathwallet.org/sitemaps/pages.xml'];
for(let offset=0;offset<allURLs.length;offset+=10000){
  const name=`tokens-${String(1+offset/10000).padStart(4,'0')}.xml`;
  const xml=`<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${allURLs.slice(offset,offset+10000).map(r=>`<url><loc>${xmlEscape('https://oathwallet.org'+r.path)}</loc></url>`).join('\n')}\n</urlset>\n`;
  await writeFile(new URL('sitemaps/'+name,root),xml);maps.push('https://oathwallet.org/sitemaps/'+name);
}
await writeFile(new URL('sitemap.xml',root),`<?xml version="1.0" encoding="UTF-8"?>\n<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${maps.map(url=>`<sitemap><loc>${url}</loc></sitemap>`).join('\n')}\n</sitemapindex>\n`);
console.log(`Built ${rows.length} token identities, ${manifest.hubCount} multi-network hubs and ${allURLs.length} canonical catalog URLs from Oath ${source.version}.`);
