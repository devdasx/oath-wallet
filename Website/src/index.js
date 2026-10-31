import { handleAgentContent, addAgentDiscovery } from './agent-content.js';
import { handleHelp } from './help/index.js';
import { handleWalletLinks } from './wallet-links.js';
import { handleArticleHost, migrateArticleLinks, migrateSupportLinks } from './article-host.js';
import { handleAnalytics } from './analytics.js';
import { handleMCP } from './mcp.js';
import { articleRoutes } from './article-routes.js';
import { handleNewsletter, newsletterScheduled } from './newsletter.js';
import { handleOusd } from './ousd.js';

const pageNames = new Set(['features', 'articles', 'support', 'press', 'terms', 'privacy', 'security', 'about', 'networks']);
const hstsPolicy = 'max-age=31536000; includeSubDomains; preload';

export default {
  async scheduled(_event, env, ctx) { ctx.waitUntil(newsletterScheduled(env)); },
  async fetch(request, env) {
    let response;
    const special = await handleAgentContent(request, env) || await handleOusd(request, env) || handleWalletLinks(request) || await handleHelp(request, env) || await handleArticleHost(request, env);
    const newsletter = special || await handleNewsletter(request, env);
    if (newsletter) {
      response = newsletter;
    } else if (new URL(request.url).pathname === '/_events') {
      try { response = await handleAnalytics(request, env); }
      catch { response = new Response(null, {status: 503, headers: {'Cache-Control': 'no-store'}}); }
    } else {
      response = await serveRequest(request, env);
      if (response.ok && response.headers.get('Content-Type')?.includes('text/html')) {
        const headers = new Headers(response.headers); headers.delete('Content-Length'); headers.delete('ETag');
        const html = migrateSupportLinks(migrateArticleLinks(await response.text()));
        response = new Response(request.method === 'HEAD' ? null : html, { status:response.status, headers });
      }
      if (response.ok && response.headers.get('Content-Type')?.includes('text/html') && typeof HTMLRewriter !== 'undefined') {
        response = new HTMLRewriter().on('head', {element(el) { el.append('<script src="/visitor-events.js" defer></script><link rel="stylesheet" href="/newsletter.css"><script src="/newsletter.js" defer></script>', {html:true}); }}).transform(response);
      }
    }
    response = addAgentDiscovery(request, response);
    // Cover assets, redirects, API responses and 404s with the same HTTPS policy.
    if (new URL(request.url).protocol !== 'https:') return response;
    const secured = new Response(response.body, response);
    secured.headers.set('Strict-Transport-Security', hstsPolicy);
    return secured;
  }
};

async function serveRequest(request, env) {
  const url = new URL(request.url);
  const isProductionHost = url.hostname === 'oathwallet.org' || url.hostname === 'www.oathwallet.org';
  // Upgrade on the same host before applying the canonical www redirect.
  if (isProductionHost && url.protocol !== 'https:') {
    url.protocol = 'https:';
    return Response.redirect(url.href, 301);
  }
  if (url.hostname === 'www.oathwallet.org') {
    url.hostname = 'oathwallet.org';
    return Response.redirect(url.href, 301);
  }

  // The Help Center replaced this page. A redirect transfers the old URL's
  // signals; serving different content with the Help Center canonical did not.
  if (/^\/support(?:\.html|\/)?$/.test(url.pathname)) {
    return Response.redirect('https://help.oathwallet.org/' + url.search, 308);
  }

  if (url.pathname === '/index.html') {
    url.pathname = '/';
    return Response.redirect(url.href, 308);
  }

  if (url.pathname === '/mcp' || url.pathname === '/mcp/') return handleMCP(request, env);

  const articlePath = url.pathname.replace(/\/$/, '').replace(/\.html$/, '');
  const article = articleRoutes[articlePath];
  if (article) {
    const canonical = typeof article === 'string' ? articlePath : article.redirect;
    if (url.pathname !== canonical) {
      url.pathname = canonical;
      return Response.redirect(url.href, 308);
    }
    url.pathname = article;
    return env.ASSETS.fetch(new Request(url, request));
  }

  const page = url.pathname.replace(/^\//, '').replace(/\/$/, '').replace(/\.html$/, '');
  if (pageNames.has(page)) {
    if (url.pathname !== `/${page}`) {
      url.pathname = `/${page}`;
      return Response.redirect(url.href, 308);
    }
    // Resolve the file internally; the visitor stays on the clean URL.
    url.pathname = `/${page}.html`;
    return env.ASSETS.fetch(new Request(url, request));
  }

  if (url.pathname === '/') {
    url.pathname = '/index.html';
    return env.ASSETS.fetch(new Request(url, request));
  }

  const asset = await env.ASSETS.fetch(request);
  if (asset.ok && url.pathname === '/sitemap.xml') {
    // Keep only canonical main-site URLs. Article editions belong to their
    // own sitemap, including articles authored directly on the new subdomain.
    const xml=(await asset.text()).replace(/<url>[\s\S]*?<\/url>/g, block => {
      const location = block.match(/<loc>([^<]+)<\/loc>/)?.[1];
      if (!location) return '';
      const pageURL = new URL(location);
      return pageURL.origin === 'https://oathwallet.org'
        && (pageURL.pathname === '/' || (pageNames.has(pageURL.pathname.slice(1))
          && !['/articles', '/support'].includes(pageURL.pathname))) ? block : '';
    });
    return new Response(xml,{headers:{'Content-Type':'application/xml'}});
  }
  if (asset.ok && url.pathname === '/robots.txt') return new Response((await asset.text())+'\nSitemap: https://help.oathwallet.org/sitemap.xml\nSitemap: https://articles.oathwallet.org/sitemap.xml\n',{headers:{'Content-Type':'text/plain'}});
  if (asset.ok && /\.(md|json|txt)$/.test(url.pathname)) {
    const headers=new Headers(asset.headers); headers.delete('Content-Length'); headers.delete('ETag'); headers.set('Access-Control-Allow-Origin','*');
    if(url.pathname.endsWith('.md')) { headers.set('Content-Type','text/markdown; charset=utf-8'); headers.set('Link', `<https://oathwallet.org${url.pathname === '/index.md' ? '/' : url.pathname.slice(0,-3)}>; rel="canonical"`); }
    if (url.pathname === '/llms.txt' || url.pathname === '/llms-full.txt') headers.set('X-Robots-Tag','noindex');
    return new Response(migrateArticleLinks(await asset.text()),{status:asset.status,headers});
  }
  const response = new Response(asset.body, asset);
  if (asset.ok && /\.(md|txt|json|xml)$/.test(url.pathname)) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Cache-Control', 'public, max-age=3600');
    if (url.pathname.endsWith('.md')) {
      response.headers.set('Content-Type', 'text/markdown; charset=utf-8');
      const canonicalPath = url.pathname === '/index.md' ? '/' : url.pathname.slice(0, -3);
      if (canonicalPath === '/' || pageNames.has(canonicalPath.slice(1)) || typeof articleRoutes[canonicalPath] === 'string') {
        response.headers.append('Link', `<https://oathwallet.org${canonicalPath}>; rel="canonical"`);
      }
    }
    if (url.pathname === '/llms.txt' || url.pathname === '/llms-full.txt') {
      response.headers.set('X-Robots-Tag', 'noindex');
    }
  }
  return response;
}
