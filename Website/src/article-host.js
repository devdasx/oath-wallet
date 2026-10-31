import { articleRoutes } from './article-routes.js';
import { publicSearchRobots } from './search-crawlers.js';
import published from '../public/oath-data.json' with { type: 'json' };
export const ARTICLE_ORIGIN='https://articles.oathwallet.org';
export function migrateSupportLinks(html) {
  return html.replace(/href=(["'])(?:https:\/\/(?:www\.)?oathwallet\.org)?\/support\1/g,(_,q)=>`href=${q}https://help.oathwallet.org/${q}`)
    .replace(/(<a\b[^>]*href=["']https:\/\/help\.oathwallet\.org\/?["'][^>]*>)Support(<\/a>)/g,'$1Help Center$2');
}
// Match legacy documents, never /og/articles.png or similarly named assets.
const legacyPattern=/^\/(?:[a-z]{2}(?:-[A-Za-z]+)?\/)?articles(?:\/|(?:\.html|\.md)?$)/;
export function articleURL(path) {
  if (['/articles.md','/articles/index.md'].includes(path)) return ARTICLE_ORIGIN+'/index.md';
  const normalized=path.replace(/\/$/,'').replace(/\.html$/,'');
  const target=articleRoutes[normalized];
  const canonical=target && typeof target !== 'string' ? target.redirect : normalized;
  return ARTICLE_ORIGIN+(canonical.replace(/\/articles(?=\/|\.|$)/,'') || '/');
}
export function migrateArticleLinks(text) {
  return text.replace(/https:\/\/(?:www\.)?oathwallet\.org(\/(?:[a-z]{2}(?:-[A-Za-z]+)?\/)?articles(?:\/[^\s"'<>?#]*)?(?:\.md)?)(?=$|[\s"'<>?#])/g,(_,path)=>articleURL(path))
    .replace(/("href"\s*:\s*")(\/(?:[a-z]{2}(?:-[A-Za-z]+)?\/)?articles(?:\/[^"]*)?)(")/g,(_,prefix,path,end)=>prefix+articleURL(path)+end)
    .replace(/(href=["'])(\/(?:[a-z]{2}(?:-[A-Za-z]+)?\/)?articles(?:\/[^"'?#]*)?)(["'?#])/g,(_,prefix,path,end)=>prefix+articleURL(path)+end);
}
export async function handleArticleHost(request,env) {
  const url=new URL(request.url), isHost=url.hostname==='articles.oathwallet.org';
  if (!isHost) {
    if (['oathwallet.org','www.oathwallet.org'].includes(url.hostname) && legacyPattern.test(url.pathname)) return Response.redirect(articleURL(url.pathname)+url.search,308);
    return null;
  }
  if (url.protocol!=='https:') {url.protocol='https:';return Response.redirect(url.href,301);}
  if (!['GET','HEAD'].includes(request.method)) return new Response('Method not allowed',{status:405,headers:{Allow:'GET, HEAD'}});
  if (url.pathname==='/llms.txt') return Response.redirect('https://oathwallet.org/llms.txt',308);
  if (legacyPattern.test(url.pathname)) return Response.redirect(articleURL(url.pathname)+url.search,308);
  if (['/features','/networks','/security','/about','/press','/privacy','/terms'].includes(url.pathname)) return Response.redirect('https://oathwallet.org'+url.pathname+url.search,308);
  if (url.pathname==='/support') return Response.redirect('https://help.oathwallet.org/',308);
  const clean=url.pathname.replace(/\/$/,'').replace(/\.html$/,'');
  let oldPath='/articles'+clean;
  const localized=/^\/([a-z]{2}(?:-[A-Za-z]+)?)\/(.+)$/.exec(clean);
  if (localized) oldPath=`/${localized[1]}/articles/${localized[2]}`;
  const entry=articleRoutes[oldPath.replace(/\.md$/,'')];
  if (entry && typeof entry !== 'string') return Response.redirect(articleURL(entry.redirect)+(clean.endsWith('.md')?'.md':'')+url.search,308);
  if (entry && clean!==url.pathname) return Response.redirect(ARTICLE_ORIGIN+clean+url.search,308);
  if (url.pathname==='/robots.txt') return new Response(request.method==='HEAD'?null:publicSearchRobots(ARTICLE_ORIGIN),{headers:{'Content-Type':'text/plain; charset=utf-8'}});
  if (url.pathname==='/sitemap.xml') {
    const modified = new Map(published.articles.map(a=>[
      new URL(a.url).hostname === 'articles.oathwallet.org' ? a.url : articleURL(new URL(a.url).pathname),
      a.updated_at || a.published_at
    ]));
    const lastmod = value => value && Number.isFinite(Date.parse(value))
      ? `<lastmod>${new Date(value).toISOString()}</lastmod>` : '';
    const latest = [...modified.values()].sort((a,b)=>Date.parse(b)-Date.parse(a))[0];
    const entries = Object.entries(articleRoutes).filter(([,v])=>typeof v==='string')
      .map(([path])=>articleURL(path));
    return new Response(`<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>${ARTICLE_ORIGIN}/</loc>${lastmod(latest)}</url>${entries.map(location=>`<url><loc>${location}</loc>${lastmod(modified.get(location))}</url>`).join('')}</urlset>`,{headers:{'Content-Type':'application/xml'}});
  }
  let file;
  if (url.pathname==='/') file='/articles.html';
  else if (url.pathname==='/index.md' || url.pathname==='/articles.md') file='/articles.md';
  else if (['/feed.xml','/feed.json'].includes(url.pathname)) file='/articles'+url.pathname;
  else if (entry) file=clean.endsWith('.md')?oldPath:entry;
  else if (['/Oath%20Header.dc.html','/Oath%20Footer.dc.html'].includes(url.pathname)) file=url.pathname;
  else if (/\.(css|js|svg|png|jpe?g|webp|avif|woff2|ico|mp4|webm)$/.test(url.pathname) || ['/feed.xml','/feed.json','/oath-data.json','/data/security-model.json'].includes(url.pathname)) file=url.pathname;
  else return new Response('Article not found. Visit https://articles.oathwallet.org/',{status:404,headers:{'Content-Type':'text/plain'}});
  const assetURL=new URL(request.url);assetURL.pathname=file;
  const asset=await env.ASSETS.fetch(new Request(assetURL,request));
  const type=asset.headers.get('Content-Type')||'';
  if (!asset.ok || !/html|xml|json|markdown|text\/plain/.test(type)) return asset;
  let text=migrateArticleLinks(await asset.text());
  if (type.includes('html')) {
    text=migrateSupportLinks(text);
    // Shared archive assets stay local; main-site navigation stays on the main site.
    text=text.replace(/href=(['"])(\/(?:features|support|press|terms|privacy|security|about|networks)?(?:#[^'"]*)?)\1/g,(_,q,path)=>`href=${q}https://oathwallet.org${path}${q}`);
    if (entry) text=text.replace(/(<article\b[^>]*>)/,'$1<aside style="padding:16px 20px;border:1px solid #dfe3eb;border-radius:16px;margin-bottom:28px;font:14px/1.6 system-ui">This is an editorial or release article. For instructions matching the current Oath Atmosphere app, visit the <a href="https://help.oathwallet.org">Help Center</a>.</aside>');
  }
  const headers=new Headers(asset.headers);headers.delete('Content-Length');headers.delete('ETag');
  if (file.endsWith('.md')) {
    const canonicalPath = ['/index.md','/articles.md'].includes(url.pathname) ? '/' : clean.replace(/\.md$/,'');
    headers.set('Content-Type','text/markdown; charset=utf-8');
    headers.set('Link',`<${ARTICLE_ORIGIN+canonicalPath}>; rel="canonical"`);
  }
  return new Response(request.method==='HEAD'?null:text,{status:asset.status,headers});
}
