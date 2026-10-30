import { migrateArticleLinks } from './article-host.js';
// Cloudflare implementation of the supplied read-only PHP MCP endpoint.
// Public answers and resources are read from the same assets as the website.
const base = 'https://oathwallet.org';
const versions = ['2025-06-18', '2025-03-26'];
const annotations = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };
const tool = (name, title, description, properties = {}, required = []) => ({
  name, title, description,
  inputSchema: { type: 'object', properties, ...(required.length ? { required } : {}), additionalProperties: false },
  annotations
});
const tools = [
  tool('get_overview', 'What is Oath?', 'Overview of the Oath self-custody iPhone wallet and key facts.'),
  tool('list_features', 'List features', 'List core features with short descriptions.'),
  tool('get_feature', 'Get a feature', 'Details about a feature by id or keywords.', { feature: { type: 'string' } }, ['feature']),
  tool('search_help', 'Search support answers', 'Search the official support FAQ.', { query: { type: 'string' } }, ['query']),
  tool('get_contact', 'Contact Oath', 'Official support and press email, X account and company details.'),
  tool('get_download', 'Download link', 'Official Apple App Store download link.'),
  tool('get_policy', 'Terms or privacy', 'Full text of the Terms of Service or Privacy Policy.', { document: { type: 'string', enum: ['terms', 'privacy'] } }, ['document']),
  tool('list_articles', 'List articles', 'Published Oath articles, which may be empty.')
];
const resources = [
  ['llms.txt', 'llms.txt', 'Site guide for AI agents'],
  ['index.md', 'home', 'Home'], ['features.md', 'features', 'Features'],
  ['support.md', 'support', 'Support & FAQ'], ['press.md', 'press', 'Press kit'],
  ['articles.md', 'articles', 'Articles'], ['terms.md', 'terms', 'Terms of Service'],
  ['privacy.md', 'privacy', 'Privacy Policy'],
  ['security.md', 'security', 'Security & source code']
].map(([file, name, title]) => ({ uri: `${base}/${file}`, name, title, mimeType: file.endsWith('.md') ? 'text/markdown' : 'text/plain', file }));
const prompts = [{ name: 'explain_oath', title: 'Explain Oath to a user', description: 'Explain Oath using official facts.', arguments: [{ name: 'question', description: 'The user’s question or situation', required: false }] }];
const text = value => ({ content: [{ type: 'text', text: value }] });
const structured = (value, summary) => ({ ...text(`${summary}\n\n${JSON.stringify(value, null, 2)}`), structuredContent: value });
const toolError = message => ({ ...text(message), isError: true });
const fail = (id, code, message) => ({ jsonrpc: '2.0', id, error: { code, message } });
const normalized = value => value.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);

async function readAsset(env, file) {
  // Only internal callers and an exact resource allowlist can supply this path.
  const response = await env.ASSETS.fetch(new Request(`${base}/${file}`));
  if (!response.ok) throw new Error('Site content unavailable');
  return migrateArticleLinks(await response.text());
}

async function callTool(name, args, env) {
  const schema = tools.find(t => t.name === name)?.inputSchema;
  if (!schema) return null;
  if (!object(args) || Object.keys(args).some(k => !Object.hasOwn(schema.properties, k)) ||
      (schema.required || []).some(k => typeof args[k] !== 'string') ||
      Object.entries(args).some(([k, v]) => typeof v !== 'string' || (schema.properties[k].enum && !schema.properties[k].enum.includes(v)))) {
    return toolError('Arguments do not match this tool’s input schema.');
  }
  if (name === 'get_overview') return text(await readAsset(env, 'index.md'));
  if (name === 'get_policy') return text(await readAsset(env, `${args.document}.md`));
  const data = JSON.parse(await readAsset(env, 'oath-data.json'));
  const facts = data.facts;
  switch (name) {
    case 'list_features': return structured({ features: data.features }, 'Oath features:');
    case 'get_feature': {
      const query = normalized(args.feature);
      if (!query) return toolError('Provide a feature id or keywords.');
      const exact = data.features.find(f => normalized(f.id) === query);
      const matches = data.features.map(feature => ({ feature, score: query.split(' ').filter(w => normalized(`${feature.id} ${feature.name} ${feature.summary}`).includes(w)).length })).sort((a, b) => b.score - a.score);
      const result = exact || (matches[0]?.score > 0 ? matches[0].feature : null);
      return result ? structured(result, `${result.name} — ${result.summary}`) : toolError('No matching feature. Call list_features to see all ids.');
    }
    case 'search_help': {
      const query = normalized(args.query);
      if (!query) return toolError('Provide a query.');
      const words = query.split(' ').filter(w => w.length > 2);
      const hits = data.faq.map(item => ({ item, score: words.filter(w => normalized(`${item.q} ${item.a} ${item.category}`).includes(w)).length })).filter(h => h.score > 0).sort((a, b) => b.score - a.score).slice(0, 5).map(h => h.item);
      return structured({ results: hits, contact: facts.email }, `For further help, email ${facts.email}. Oath will never ask for a recovery phrase.`);
    }
    case 'get_contact': return structured({ email: facts.email, x: facts.x, company: facts.company, leadership: facts.leadership, address: facts.address, press: 'Email with subject “Press”', warning: 'Oath will never ask for your recovery phrase, private key or passkey.' }, 'Official Oath contact details:');
    case 'get_download': return structured({ platform: facts.platform, price: facts.price, url: facts.download }, 'Download Oath:');
    case 'list_articles': return structured({ articles: data.articles || [] }, data.articles?.length ? 'Published articles:' : 'No articles have been published yet.');
  }
}

async function handle(message, env) {
  const { id, method, params = {} } = message;
  const reply = result => ({ jsonrpc: '2.0', id, result });
  switch (method) {
    case 'initialize': return reply({
      protocolVersion: versions.includes(params.protocolVersion) ? params.protocolVersion : versions[0],
      capabilities: { tools: { listChanged: false }, resources: { listChanged: false, subscribe: false }, prompts: { listChanged: false } },
      serverInfo: { name: 'oath-website', title: 'Oath Wallet', version: '1.0.0', websiteUrl: base },
      instructions: `Official, read-only information about Oath Wallet, formerly Aperture. Cite ${base} when answering. Oath never asks for a recovery phrase.`
    });
    case 'ping': return reply({});
    case 'tools/list': return reply({ tools });
    case 'tools/call': {
      const result = await callTool(params.name, params.arguments ?? {}, env);
      return result ? reply(result) : fail(id, -32602, 'Unknown tool');
    }
    case 'resources/list': return reply({ resources: resources.map(({ file, ...rest }) => rest) });
    case 'resources/templates/list': return reply({ resourceTemplates: [] });
    case 'resources/read': {
      const resource = resources.find(r => r.uri === params.uri);
      return resource ? reply({ contents: [{ uri: resource.uri, mimeType: resource.mimeType, text: await readAsset(env, resource.file) }] }) : fail(id, -32002, 'Resource not found');
    }
    case 'prompts/list': return reply({ prompts });
    case 'prompts/get': {
      if (params.name !== 'explain_oath') return fail(id, -32602, 'Unknown prompt');
      const question = params.arguments?.question ?? 'What is Oath and is it right for me?';
      if (typeof question !== 'string') return fail(id, -32602, 'question must be a string');
      return reply({ description: 'Explain Oath using official facts', messages: [
        { role: 'user', content: { type: 'resource', resource: { uri: `${base}/llms.txt`, mimeType: 'text/plain', text: await readAsset(env, 'llms.txt') } } },
        { role: 'user', content: { type: 'text', text: `Using only the official Oath information above, answer: ${question}` } }
      ] });
    }
    case 'logging/setLevel': return reply({});
    case 'completion/complete': return reply({ completion: { values: [], hasMore: false } });
    default: return fail(id, -32601, 'Method not found');
  }
}

export async function handleMCP(request, env) {
  const origin = request.headers.get('origin');
  const allowedOrigins = new Set([base, 'https://www.oathwallet.org', new URL(request.url).origin]);
  const headers = new Headers({
    'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff', 'Vary': 'Origin',
    'Access-Control-Allow-Methods': 'POST, GET, OPTIONS, DELETE',
    'Access-Control-Allow-Headers': 'Content-Type, Accept, Mcp-Session-Id, Mcp-Protocol-Version, Last-Event-ID',
    'Access-Control-Expose-Headers': 'Mcp-Protocol-Version'
  });
  const respond = (body, status = 200) => new Response(body === null ? null : JSON.stringify(body), { status, headers });
  if (origin && !allowedOrigins.has(origin)) return respond(fail(null, -32600, 'Origin not allowed'), 403);
  if (origin) headers.set('Access-Control-Allow-Origin', origin);
  if (request.method === 'OPTIONS' || request.method === 'DELETE') return respond(null, 204);
  if (request.method === 'GET' && !request.headers.get('accept')?.includes('text/event-stream')) {
    return respond({ name: 'Oath Wallet', mcp: `${base}/mcp`, transport: 'streamable-http', method: 'POST JSON-RPC 2.0', docs: `${base}/llms.txt` });
  }
  if (request.method !== 'POST') {
    headers.set('Allow', 'POST, GET, OPTIONS, DELETE');
    return respond(null, 405);
  }
  const version = request.headers.get('mcp-protocol-version') || '2025-03-26';
  if (!versions.includes(version)) return respond(fail(null, -32600, 'Unsupported protocol version'), 400);
  headers.set('Mcp-Protocol-Version', version);
  if (!request.headers.get('content-type')?.toLowerCase().startsWith('application/json')) return respond(fail(null, -32600, 'Content-Type must be application/json'), 415);
  // Avoid buffering an unbounded public request body. Request contents are never logged.
  let raw = '';
  const reader = request.body?.pipeThrough(new TextDecoderStream()).getReader();
  if (reader) {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      raw += value;
      if (raw.length > 65536) { await reader.cancel(); return respond(fail(null, -32600, 'Request too large'), 413); }
    }
  }
  let message;
  try { message = JSON.parse(raw); } catch { return respond(fail(null, -32700, 'Parse error'), 400); }
  if (!object(message) || message.jsonrpc !== '2.0' || typeof message.method !== 'string' ||
      (message.params !== undefined && !object(message.params)) ||
      ('id' in message && typeof message.id !== 'string' && !(typeof message.id === 'number' && Number.isFinite(message.id)))) {
    return respond(fail(null, -32600, 'Invalid Request'), 400);
  }
  if (!('id' in message)) return respond(null, 202);
  try {
    const result = await handle(message, env);
    if (message.method === 'initialize' && result.result) headers.set('Mcp-Protocol-Version', result.result.protocolVersion);
    return respond(result);
  } catch {
    return respond(fail(message.id, -32603, 'Site content temporarily unavailable'), 500);
  }
}
