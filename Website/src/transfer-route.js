import {coin} from './tokens.js';
import manifest from './tokens-manifest.json' with {type:'json'};
import {wantsMarkdown} from './agent-content.js';
import {renderTransferPreparation, preparationMarkdown, transferPath, transferKey} from './transfer-preparation.js';
const canonical = 'https://oathwallet.org' + transferPath;
const markers = /<!-- oath-transfer-tool:start -->[\s\S]*?<!-- oath-transfer-tool:end -->/;

export async function handleTransferPreparation(request, env) {
  const url = new URL(request.url);
  if (!(url.origin === 'https://oathwallet.org' || ['localhost', '127.0.0.1'].includes(url.hostname))) return null;
  if (![transferPath, transferPath + '.md'].includes(url.pathname) || !url.search) return null;
  const headers = {'Cache-Control':'no-store', 'X-Robots-Tag':'noindex, follow', 'Link':`<${canonical}>; rel="canonical"`, 'Vary':'Accept', 'X-Content-Type-Options':'nosniff'};
  const failure = (status, text) => new Response(request.method === 'HEAD' ? null : text, {status, headers:{...headers, 'Content-Type':'text/plain; charset=utf-8', ...(status === 503 ? {'Retry-After':'60'} : {})}});
  if (!['GET','HEAD'].includes(request.method)) return new Response(null, {status:405, headers:{...headers, Allow:'GET, HEAD'}});
  if ([...url.searchParams.keys()].some(key => !['token','network'].includes(key))) {
    for (const key of [...url.searchParams.keys()]) if (!['token','network'].includes(key)) url.searchParams.delete(key);
    return new Response(null, {status:308, headers:{...headers, Location:canonical + (url.pathname.endsWith('.md') ? '.md' : '') + url.search}});
  }
  const slug = url.searchParams.get('token'), network = url.searchParams.get('network');
  // Reject ambiguous or unbounded identities; never guess from a symbol.
  if ([...url.searchParams.keys()].some(key => !['token','network'].includes(key)) ||
      ['token','network'].some(key => url.searchParams.getAll(key).length !== 1) ||
      !/^[a-z0-9-]{1,200}$/.test(slug || '') || !/^[a-z0-9-]{1,200}$/.test(network || '')) {
    return failure(404, 'This selection is not in the published catalog. Choose an asset at https://oathwallet.org/tokens');
  }
  try {
    const group = await coin(env, slug), asset = group?.assets.find(a => transferKey(a) === network);
    if (!asset) return failure(404, 'This token and network combination is not in the published catalog. Choose an asset at https://oathwallet.org/tokens');
    const template = await env.ASSETS.fetch(new Request(canonical + '.html'));
    if (!template.ok) throw Error('Guide unavailable');
    let html = await template.text();
    if (!markers.test(html)) throw Error('Guide template unavailable');
    const markdown = url.pathname.endsWith('.md') || wantsMarkdown(request.headers.get('Accept') || '');
    // Markdown includes only the selected entry; HTML retains this group's other
    // entries for local selection without a provider or full-catalog download.
    html = html.replace(markers, renderTransferPreparation(markdown ? [asset] : group.assets, manifest.networks, asset.path))
      .replace(/(<meta name="robots" content=")[^"]*"/, '$1noindex,follow"');
    if (!['tether','usd-coin'].includes(group.coinID)) html = html.replace(/<section data-transfer-sources>[\s\S]*?<\/section>/, `<section><h2>Check the catalog source</h2><p><a href="https://www.coingecko.com/en/coins/${encodeURIComponent(group.coinID)}">Catalog provider asset record</a>. Verify the exact identifier with the issuer and sending service before transferring.</p></section>`);
    headers['X-Oath-Catalog-Version'] = manifest.version;
    headers['Content-Type'] = markdown ? 'text/markdown; charset=utf-8' : 'text/html; charset=utf-8';
    let body = html;
    if (markdown) {
      body = preparationMarkdown(html.match(/<main\b[^>]*>([\s\S]*?)<\/main>/)[1]);
      body = `Canonical: ${canonical}\n\n${body.trim()}\n`;
    }
    return new Response(request.method === 'HEAD' ? null : body, {headers});
  } catch {
    return failure(503, 'The accepted catalog is temporarily unavailable. Please try again shortly.');
  }
}
