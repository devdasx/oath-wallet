import bundled from './content.json' with { type: 'json' };
import { publicSearchRobots } from '../search-crawlers.js';
import { home, collection, article, searchResults, notFound, HELP_ORIGIN, esc } from './render.js';

const slug = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const strings = value => Array.isArray(value) && value.every(x => typeof x === 'string');
export function validateContent(categories, articles) {
  if (!Array.isArray(categories) || !Array.isArray(articles)) throw new Error('Invalid content');
  const ids = new Set(categories.map(c => c.id));
  if (ids.size !== categories.length || categories.some(c => !slug.test(c.id) || !['title','description','icon'].every(k => typeof c[k] === 'string'))) throw new Error('Invalid collections');
  if (new Set(articles.map(a => a.slug)).size !== articles.length || articles.some(a => !slug.test(a.slug) || !ids.has(a.category_id) || !['title','summary','route','note','app_version'].every(k => typeof a[k] === 'string') || !['steps','body','related','tags'].every(k => strings(a[k])) || (a.screenshot && !slug.test(a.screenshot)) || !Number.isFinite(Date.parse(a.updated_at)) || !Number.isFinite(Date.parse(a.published_at)))) throw new Error('Invalid articles');
  return {categories, articles};
}
// Published help content is versioned and deployed with the website.
const data = validateContent(bundled.categories, bundled.articles);
export async function handleHelp(request, env) {
  const url = new URL(request.url);
  if (url.hostname !== 'help.oathwallet.org' && !(env.HELP_PREVIEW === 'true' && ['localhost','127.0.0.1'].includes(url.hostname))) return null;
  if (!['GET','HEAD'].includes(request.method)) return new Response('Method not allowed',{status:405,headers:{Allow:'GET, HEAD'}});
  if (url.hostname === 'help.oathwallet.org' && url.protocol !== 'https:') {url.protocol='https:';return Response.redirect(url.href,301);}
  if (url.pathname.startsWith('/help/') || ['/favicon.svg','/assets/brand/oath-mark-dark.svg','/assets/brand/oath-mark-light.svg'].includes(url.pathname)) return env.ASSETS.fetch(request);
  if (url.pathname.length > 1 && url.pathname.endsWith('/')) {url.pathname=url.pathname.replace(/\/+$/,'');return Response.redirect(url.href,308);}
  let body, status=200, type='text/html; charset=utf-8';
  if (url.pathname === '/') body=home(data);
  else if (url.pathname === '/search') body=searchResults(data,(url.searchParams.get('q')||'').trim().slice(0,120));
  else if (url.pathname === '/robots.txt') {
    // Search pages carry noindex. Let Google crawl them to see that directive.
    type='text/plain; charset=utf-8';body=publicSearchRobots(HELP_ORIGIN);
  }
  else if (url.pathname === '/sitemap.xml') {
    const latest = articles => articles.map(a=>a.updated_at).sort((a,b)=>Date.parse(b)-Date.parse(a))[0];
    const entries = [
      ['/', latest(data.articles)],
      ...data.categories.map(c=>['/collections/'+c.id,latest(data.articles.filter(a=>a.category_id===c.id))]),
      ...data.articles.map(a=>['/articles/'+a.slug,a.updated_at])
    ];
    type='application/xml';
    body=`<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${entries.map(([path,modified])=>`<url><loc>${esc(HELP_ORIGIN+path)}</loc>${modified?`<lastmod>${esc(new Date(modified).toISOString())}</lastmod>`:''}</url>`).join('')}</urlset>`;
  }
  else {
    const c=/^\/collections\/([a-z0-9-]+)$/.exec(url.pathname), a=/^\/articles\/([a-z0-9-]+)$/.exec(url.pathname);
    const found=c ? data.categories.find(x=>x.id===c[1]) : a ? data.articles.find(x=>x.slug===a[1]) : null;
    if (found) body=c ? collection(data,found) : article(data,found);
    else {body=notFound();status=404;}
  }
  return new Response(request.method==='HEAD'?null:body,{status,headers:{'Content-Type':type,'Cache-Control':'public, max-age=60, stale-while-revalidate=120','X-Oath-Content':'git','X-Content-Type-Options':'nosniff','Referrer-Policy':'strict-origin-when-cross-origin','Content-Security-Policy':"default-src 'self'; script-src 'self'; style-src 'self' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"}});
}
