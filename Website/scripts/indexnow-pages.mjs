import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {sitemapURLs} from './sitemaps.mjs';
import manifest from '../src/tokens-manifest.json' with {type:'json'};
import {handleHelp} from '../src/help/index.js';
import {handleArticleHost} from '../src/article-host.js';

const root=new URL('../public/',import.meta.url);
const digest=text=>createHash('sha256').update(text).digest('hex');
const assets={ASSETS:{async fetch(request){
  const path=new URL(request.url).pathname;
  if (!path.endsWith('.html')) throw Error('Expected a published HTML document');
  return new Response(await readFile(new URL('.'+path,root)), {headers:{'Content-Type':'text/html; charset=utf-8'}});
}}};

// Use the same offline sources and host renderers as production.
export async function indexNowHashes() {
  const hashes={};
  for(const url of await sitemapURLs()) {
    const parsed=new URL(url),path=parsed.pathname;
    if(parsed.origin!=='https://oathwallet.org')throw Error('Unexpected sitemap origin');
    hashes[url]=path.startsWith('/tokens')||path.endsWith('/tokens') ? manifest.version
      : digest(await readFile(new URL('.'+(path==='/'?'/index.html':path+'.html'),root)));
  }
  for(const [host,handler] of [['help.oathwallet.org',handleHelp],['articles.oathwallet.org',handleArticleHost]]) {
    const sitemap=await handler(new Request(`https://${host}/sitemap.xml`),assets);
    if(!sitemap.ok)throw Error('Host sitemap failed');
    const urls=[...(await sitemap.text()).matchAll(/<loc>([^<]+)<\/loc>/g)].map(m=>m[1].replaceAll('&amp;','&'));
    if(!urls.length)throw Error('Empty host sitemap');
    for(const url of urls) {
      if(new URL(url).origin!==`https://${host}`||url in hashes)throw Error('Invalid host sitemap URL');
      const response=await handler(new Request(url),assets);
      if(!response.ok||!response.headers.get('Content-Type')?.includes('text/html'))throw Error('Invalid sitemap document');
      hashes[url]=digest(await response.text());
    }
  }
  return hashes;
}

export function submissionBatches(hashes,previous,hosts) {
  const changed=Object.keys(hashes).filter(url=>previous[url]!==hashes[url]);
  const removed=Object.keys(previous).filter(url=>!(url in hashes));
  const grouped=new Map(hosts.map(host=>[host,[]]));
  for(const url of [...changed,...removed]) {
    const u=new URL(url);
    if(u.protocol!=='https:'||u.port||u.username||u.password||u.hash||!grouped.has(u.hostname))throw Error('Invalid IndexNow URL');
    grouped.get(u.hostname).push(url);
  }
  const batches=[];
  for(const [host,urls] of grouped)for(let offset=0;offset<urls.length;offset+=10000)batches.push({host,urlList:urls.slice(offset,offset+10000)});
  return {changed:changed.length,removed:removed.length,batches};
}
