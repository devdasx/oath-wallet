import config from '../indexnow.json' with {type:'json'};

// Public ownership records, not private credentials.
export async function handleSearchVerification(request, env) {
  const url = new URL(request.url);
  if (!config.hosts.includes(url.hostname)
    || !['/BingSiteAuth.xml', `/${config.key}.txt`].includes(url.pathname)) return null;
  if (!['GET','HEAD'].includes(request.method)) return new Response('Method not allowed', {status:405, headers:{Allow:'GET, HEAD'}});
  if (url.protocol !== 'https:') {url.protocol='https:';return Response.redirect(url.href,301);}
  const asset = await env.ASSETS.fetch(request);
  const headers = new Headers(asset.headers);
  headers.set('Content-Type', url.pathname.endsWith('.xml') ? 'application/xml; charset=utf-8' : 'text/plain; charset=utf-8');
  headers.set('X-Robots-Tag','noindex');
  headers.set('Cache-Control','public, max-age=3600');
  return new Response(request.method==='HEAD'?null:asset.body, {status:asset.status,headers});
}
