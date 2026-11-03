import networkCatalog from '../content/networks.json' with {type:'json'};
import help from './help/content.json' with {type:'json'};
import facts from '../public/oath-data.json' with {type:'json'};
import evidence from '../content/release-evidence.json' with {type:'json'};
import {migrateArticleLinks} from './article-host.js';
import {articleRoutes} from './article-routes.js';
const main='https://oathwallet.org', support='https://help.oathwallet.org', articles='https://articles.oathwallet.org';
const pages=['index','features','about','networks','press','security','bug-bounty','terms','privacy'];
const articlePath=p=>p.replace(/\/articles(?=\/|$)/,'')||'/';
export const documents=[
 ...networkCatalog.networks.map(n=>({url:main+'/networks/'+n.slug,markdown_url:main+'/networks/'+n.slug+'.md',title:n.name+' wallet: send, receive and dApp connections',summary:n.intro,kind:'network',file:'/networks/'+n.slug+'.md',updated_at:networkCatalog.reviewed})),
 ...pages.map(p=>({url:main+(p==='index'?'/':'/'+p),markdown_url:main+'/'+p+'.md',title:p==='index'?'Oath Wallet':p[0].toUpperCase()+p.slice(1),kind:'page',file:'/'+p+'.md'})),
 {url:support+'/',markdown_url:support+'/index.md',title:'Help Center',kind:'help-index'},
 ...help.categories.map(c=>({url:support+'/collections/'+c.id,markdown_url:support+'/collections/'+c.id+'.md',title:c.title,summary:c.description,kind:'collection',id:c.id})),
 ...help.articles.map(a=>({url:support+'/articles/'+a.slug,markdown_url:support+'/articles/'+a.slug+'.md',title:a.title,summary:a.summary,updated_at:a.updated_at,published_at:a.published_at,app_version:a.app_version,kind:'help',id:a.slug})),
 {url:articles+'/',markdown_url:articles+'/index.md',title:'Articles',kind:'article-index',file:'/articles.md'},
 ...Object.entries(articleRoutes).filter(([,v])=>typeof v==='string').map(([p])=>{
  const url=articles+articlePath(p), a=facts.articles.find(a=>a.url===url || a.url===main+p);
  return {url,markdown_url:url+'.md',title:a?.title||p.split('/').pop().replaceAll('-',' '),summary:a?.description||a?.summary||'',updated_at:a?.updated_at,published_at:a?.published_at,kind:'article',file:p+'.md'};
 })
];
export const publicDocument=d=>Object.fromEntries(Object.entries(d).filter(([k,v])=>!['file','id'].includes(k)&&v!==undefined));
export const evidenceScope={version:evidence.version,build:evidence.build,reviewed_on:evidence.reviewed_on,source_url:`https://github.com/devdasx/oath-wallet/tree/${evidence.source_commit}`,scope:'Pinned source excerpts, not an independent audit or confirmation of the current App Store version.',app_store_url:facts.facts.download};
const link=d=>`- [${d.title}](${d.markdown_url})${d.summary?': '+d.summary:''}`;
export function guide(origin) {
 const docs=documents.filter(d=>origin===main || new URL(d.url).origin===origin);
 return `# Oath Wallet — public documentation\n\nOfficial product information only. Never submit recovery phrases, private keys, passcodes or wallet data to these interfaces.\n\nRead-only MCP: ${main}/mcp\nDocument index: ${main}/agent-documents.json\nApp Store: ${facts.facts.download}\nPublic source and releases: ${facts.facts.source_code}\n\nHelp instructions carry their applicable app version and authored update dates. Source excerpts cover ${evidence.version} (${evidence.build}), reviewed ${evidence.reviewed_on}; this is not an independent audit or proof of App Store availability.\n\n${docs.map(link).join('\n')}\n\nFull text: ${main}/llms-full.txt\n`;
}
export async function documentText(d,env,asset) {
 let body;
 if(d.kind==='help') {
  const a=help.articles.find(a=>a.slug===d.id);
  body=`# ${a.title}\n\n${a.summary}\n\n${a.body.join('\n\n')}\n\n## Steps\n\n${a.steps.map((s,i)=>`${i+1}. ${s}`).join('\n')}\n\n${a.note}\n\n## Related\n\n${a.related.map(id=>documents.find(d=>d.kind==='help'&&d.id===id)).filter(Boolean).map(link).join('\n')}`;
 } else if(d.kind==='help-index'||d.kind==='collection') {
  const selected=documents.filter(x=>d.kind==='help-index'?x.kind==='collection':x.kind==='help'&&help.articles.find(a=>a.slug===x.id).category_id===d.id);
  body=`# ${d.title}\n\n${d.summary||'Official Oath Wallet instructions.'}\n\n${selected.map(link).join('\n')}`;
 } else {
  const r=asset || await env.ASSETS.fetch(new Request(main+d.file));
  if(!r.ok)throw new Error('Published Markdown missing: '+d.file);
  body=await r.text();
 }
 body=migrateArticleLinks(body).replace(/\]\((\/[^)]+)\)/g,(_,path)=>`](${new URL(path,main).href})`);
 body=body.replace(/^[-*][ \t]*\n(?:[ \t]*\n)+(?=\S)/gm,'- ').replace(/[ \t]+$/gm,'');
 return `Canonical: ${d.url}\n${d.updated_at?'Updated: '+d.updated_at+'\n':''}${d.app_version?'Applies to app version: '+d.app_version+'\n':''}\n${body.trim()}\n`;
}
export function searchHelp(query) {
 const words=query.toLowerCase().match(/[\p{L}\p{N}]+/gu)||[];
 if(!words.length)return [];
 return help.articles.map(a=>{
  const title=(a.title+' '+a.tags.join(' ')).toLowerCase(),body=[a.summary,...a.body,...a.steps,a.note].join(' ').toLowerCase();
  return {a,score:words.reduce((n,w)=>n+(title.includes(w)?4:0)+(body.includes(w)?1:0),0)};
 }).filter(x=>x.score>0).sort((a,b)=>b.score-a.score||a.a.slug.localeCompare(b.a.slug)).slice(0,10).map(({a})=>({...publicDocument(documents.find(d=>d.kind==='help'&&d.id===a.slug)),excerpt:a.summary}));
}
// Explicit MIME preferences only; ordinary browsers and wildcard Accept keep HTML.
export function wantsMarkdown(accept='') {
 const entries=accept.toLowerCase().split(',').map(x=>{const [type,...params]=x.trim().split(';');const q=params.find(p=>p.trim().startsWith('q='));return {type,q:q?Number(q.trim().slice(2)):1}});
 const md=entries.find(x=>x.type==='text/markdown');
 return !!md && md.q>0 && md.q>Math.max(0,...entries.filter(x=>x.type==='text/html'||x.type==='application/xhtml+xml').map(x=>x.q));
}
export async function handleAgentContent(request,env) {
 const u=new URL(request.url);
 if(![main,support,articles].includes(u.origin)||!['GET','HEAD'].includes(request.method))return null;
 const headers={'Content-Type':'text/markdown; charset=utf-8','Cache-Control':'public, max-age=60, stale-while-revalidate=120','X-Content-Type-Options':'nosniff','Access-Control-Allow-Origin':'*'};
 let body;
 if(u.pathname==='/llms.txt') {
  body=guide(u.origin);headers['Content-Type']='text/plain; charset=utf-8';headers['X-Robots-Tag']='noindex';
 } else if(u.pathname==='/agent-documents.json') {
  body=JSON.stringify({schema_version:1,source_evidence:evidenceScope,documents:documents.filter(d=>u.origin===main||new URL(d.url).origin===u.origin).map(publicDocument)});headers['Content-Type']='application/json; charset=utf-8';headers['X-Robots-Tag']='noindex';
 } else {
  const d=documents.find(d=>d.markdown_url===u.origin+u.pathname || d.url===u.origin+u.pathname);
  if(!d)return null;
  const negotiated=d.url===u.origin+u.pathname;
  if(negotiated&&!wantsMarkdown(request.headers.get('Accept')||''))return null;
  const asset=d.file?await env.ASSETS.fetch(new Request(main+d.file)):undefined;
  if(asset){for(const [k,v] of asset.headers)if(!['content-length','content-encoding','etag','last-modified','content-type','link','vary','cache-control','access-control-allow-origin','x-content-type-options'].includes(k))headers[k]=v;}
  body=await documentText(d,env,asset);headers.Link=`<${d.url}>; rel="canonical"`;
  if(negotiated)headers.Vary='Accept';
 }
 return new Response(request.method==='HEAD'?null:body,{headers});
}
export function addAgentDiscovery(request,response) {
 const u=new URL(request.url),d=documents.find(d=>d.url===u.origin+u.pathname);
 if(!d||!response.ok||!response.headers.get('Content-Type')?.includes('text/html'))return response;
 const r=new Response(response.body,response);
 const vary=new Set((r.headers.get('Vary')||'').split(',').map(s=>s.trim()).filter(Boolean));vary.add('Accept');r.headers.set('Vary',[...vary].join(', '));
 r.headers.append('Link',`<${d.markdown_url}>; rel="alternate"; type="text/markdown", <${u.origin}/llms.txt>; rel="describedby"; type="text/plain"`);
 return r;
}
