import retired from '../content/retired-articles.json' with {type:'json'};

const slugs = new Set(retired.articles.flatMap(a => [a.slug, ...a.aliases]));
export function handleRetiredArticle(request) {
  const url = new URL(request.url);
  if (!['oathwallet.org', 'www.oathwallet.org', 'articles.oathwallet.org'].includes(url.hostname)) return null;
  const path = url.pathname.replace(/\/$/, '').replace(/\.(?:html|md)$/, '');
  const match = url.hostname === 'articles.oathwallet.org'
    ? /^\/(?:articles\/)?([^/]+)$/.exec(path)
    : /^\/articles\/([^/]+)$/.exec(path);
  if (!match || !slugs.has(match[1])) return null;
  if (url.protocol !== 'https:') { url.protocol = 'https:'; return Response.redirect(url.href, 301); }
  return new Response(request.method === 'HEAD' ? null : 'This article is no longer available.', {
    status: 410,
    headers: {'Content-Type': 'text/plain; charset=utf-8', 'X-Robots-Tag': 'noindex', 'Cache-Control': 'public, max-age=300'}
  });
}
