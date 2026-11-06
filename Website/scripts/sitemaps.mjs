import {readFile} from 'node:fs/promises';
const root=new URL('../public/',import.meta.url);
export async function sitemapURLs(path='/sitemap.xml',seen=new Set()){
  if(!/^\/(?:sitemap\.xml|sitemaps\/[a-z0-9-]+\.xml)$/.test(path)||seen.has(path)||seen.size>=20)throw Error('Invalid sitemap traversal');
  seen.add(path);
  const xml=await readFile(new URL('.'+path,root),'utf8');
  const urls=[...xml.matchAll(/<loc>([^<]+)<\/loc>/g)].map(m=>m[1].replaceAll('&amp;','&'));
  if(!urls.length)throw Error('Empty sitemap');
  if(xml.includes('<sitemapindex')){
    const result=[];for(const url of urls){const u=new URL(url);if(u.origin!=='https://oathwallet.org')throw Error('Invalid sitemap origin');result.push(...await sitemapURLs(u.pathname,seen));}return result;
  }
  if(urls.length>10000||!xml.includes('<urlset'))throw Error('Invalid URL sitemap');
  return urls;
}
