// Canonical metadata and visible navigation for the existing three-site layout.
// Does not rewrite editorial dates to the build time or manufacture translations.
import {readFile,writeFile} from 'node:fs/promises';
import networkCatalog from '../content/networks.json' with {type:'json'};
import {articleRoutes} from '../src/article-routes.js';
import {articleURL,ARTICLE_ORIGIN} from '../src/article-host.js';
const publicDir=new URL('../public/',import.meta.url);
const read=p=>readFile(new URL(p,publicDir),'utf8');
const write=(p,text)=>writeFile(new URL(p,publicDir),text);
const esc=v=>String(v).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
const json=v=>JSON.stringify(v).replaceAll('<','\\u003c');
const questions=JSON.parse(await readFile(new URL('../content/self-custody-questions.json',import.meta.url),'utf8'));
const data=JSON.parse(await read('oath-data.json'));

// Preserve the designed homepage; provide the same useful answers before and
// after enhancement. Do not add FAQ rich-result markup: this is not a health
// or government site eligible for Google's FAQ feature.
let home=await read('index.html');
home=home.replace(/<link rel="stylesheet" href="\/self-custody\.css[^"]*">\s*/g,'');
home=home.replace('</head>','<link rel="stylesheet" href="/self-custody.css?v=20261031-list"></head>');
const section=`<!-- oath-self-custody:start --><section id="self-custody" style="max-width:1320px;margin:0 auto;padding:80px clamp(20px,5vw,32px);border-top:1px solid rgba(242,240,234,.14)">
<h2 style="margin:0 0 24px;font:400 clamp(36px,5vw,64px)/1.08 'Instrument Serif',serif">Self-custody, explained.</h2>
<p style="max-width:64ch;font:400 18px/1.6 'Instrument Sans',sans-serif;color:#B9B7B0">A crypto wallet is a tool for using a blockchain. Understand the tradeoffs, prepare your backup, and check the network before moving funds.</p>
<div class="custody-question-list">${questions.map(q=>`<details class="custody-question"><summary><span>${esc(q.question)}</span><span class="custody-question-toggle" aria-hidden="true"></span></summary><div class="custody-answer"><p>${esc(q.answer)}</p><a href="${esc(q.url)}">${esc(q.label)}</a></div></details>`).join('')}</div>
<p style="margin:40px 0 0;font:400 16px/1.6 'Instrument Sans',sans-serif">New to Oath? <a href="https://help.oathwallet.org/articles/create-wallet" style="text-decoration:underline">Create your first wallet</a>, learn to <a href="https://help.oathwallet.org/articles/receive-crypto" style="text-decoration:underline">receive crypto</a>, or browse the <a href="https://help.oathwallet.org/" style="text-decoration:underline">Help Center</a>.</p>
</section><!-- oath-self-custody:end -->`;
home=home.replace(/<!-- oath-self-custody:start -->[\s\S]*?<!-- oath-self-custody:end -->\s*/g,'');
if(!home.includes('<section id="get"'))throw new Error('Homepage CTA anchor missing');
home=home.replace('<section id="get"',section+'\n<section id="get"');
const title='Oath Wallet | Self-Custody Crypto Wallet for iPhone';
const description='Explore Oath Wallet, a self-custody Bitcoin and crypto wallet for iPhone and iPad. Compare features, check supported networks, and learn backup and recovery.';
home=home.replace(/<title>[\s\S]*?<\/title>/,`<title>${title}</title>`)
 .replace(/(<meta (?:name|property)="(?:description|og:description|twitter:description)" content=")[^"]*"/g,`$1${description}"`)
 .replace(/(<meta property="og:site_name" content=")[^"]*"/,'$1Oath Wallet"')
 .replace(/(<meta (?:property|name)="(?:og:title|twitter:title)" content=")[^"]*"/g,`$1${title}"`)
 .replaceAll('37 US ratings','38 US ratings').replace(/Rating checked (?:September 28|October 20), 2026/g,'Rating checked October 27, 2026');
home=home.replace(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g,(_,raw)=>{
 const schema=JSON.parse(raw);
 for(const node of schema['@graph']||[]) {
  if(node['@type']==='WebPage'){node.name=title;node.description=description;}
  if(node['@type']==='MobileApplication'){
   node.name='Oath: Crypto & Bitcoin Wallet';node.softwareVersion='4.1.2';
   node.aggregateRating={...node.aggregateRating,ratingValue:'4.8',ratingCount:'38'};
   node.softwareHelp='https://help.oathwallet.org/';
  }
 }
 return `<script type="application/ld+json">${json(schema)}</script>`;
});
await write('index.html',home);
let markdown=await read('index.md');
markdown=markdown.replace(/\n<!-- oath-questions:start -->[\s\S]*?<!-- oath-questions:end -->\n?/g,'')
 .replace('from 37 ratings','from 38 ratings').replace(/checked (?:September 28|October 20), 2026 on the App Store/g,'checked October 27, 2026 on the App Store');
markdown+='\n<!-- oath-questions:start -->\n## Self-custody, explained\n\n'+questions.map(q=>`### ${q.question}\n\n${q.answer}\n\n[${q.label}](${q.url})`).join('\n\n')+'\n<!-- oath-questions:end -->\n';
await write('index.md',markdown);
const homePage=data.pages.find(p=>p.url==='https://oathwallet.org/');
if(homePage){homePage.title=title;homePage.description=description;}
const addedQuestions=new Set(questions.map(q=>q.question));
data.faq=[
 ...data.faq.filter(q=>!addedQuestions.has(q.q)),
 ...questions.map(q=>({category:'Self-custody',q:q.question,a:q.answer}))
];
await write('oath-data.json',JSON.stringify(data,null,2)+'\n');

// Article breadcrumbs describe the hierarchy readers can actually navigate.
for(const [route,file] of Object.entries(articleRoutes).filter(([,v])=>typeof v==='string')) {
 let html=await read(file.slice(1));
 const schemaMatch=html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/);
 const post=JSON.parse(schemaMatch[1]);
 const canonical=articleURL(route);
 const breadcrumb={'@context':'https://schema.org','@type':'BreadcrumbList',itemListElement:[
  {'@type':'ListItem',position:1,name:'Oath articles',item:ARTICLE_ORIGIN+'/'},
  {'@type':'ListItem',position:2,name:post.headline,item:canonical}
 ]};
 html=html.replace(/<!-- oath-breadcrumb-schema:start -->[\s\S]*?<!-- oath-breadcrumb-schema:end -->/g,'')
  .replace('</head>',`<!-- oath-breadcrumb-schema:start --><script type="application/ld+json">${json(breadcrumb)}</script><!-- oath-breadcrumb-schema:end --></head>`);
 if(!html.includes('aria-label="Breadcrumb"')){
  const nav=`<nav aria-label="Breadcrumb" style="font:14px/1.5 'Instrument Sans',sans-serif;margin-bottom:24px"><a href="${ARTICLE_ORIGIN}/">Oath articles</a> / <span aria-current="page">${esc(post.headline)}</span></nav>`;
  // Both older archive pages and newly authored articles use this container.
  html=html.replace(/(<(?:div|header) class="article-hero"[^>]*>)/,`$1${nav}`);
  if(!html.includes('aria-label="Breadcrumb"'))throw new Error('Missing article hero: '+file);
 }
 if(!/name="robots"/.test(html))html=html.replace('</head>','<meta name="robots" content="max-image-preview:large"></head>');
 await write(file.slice(1),html);
}
let archive=await read('articles.html');
archive=archive.replace(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g,(_,raw)=>{
 const schema=JSON.parse(raw);
 for(const node of schema['@graph']||[]) {
  if(node['@type']==='WebSite'){node['@id']=ARTICLE_ORIGIN+'/#site';node.url=ARTICLE_ORIGIN+'/';node.name='Oath articles';node.alternateName='Oath Wallet articles';}
  if(node['@type']==='WebPage')node.isPartOf={'@id':ARTICLE_ORIGIN+'/#site'};
 }
 return `<script type="application/ld+json">${json(schema)}</script>`;
});
await write('articles.html',archive);

// The main sitemap must not retain moved support or article URLs.
const oldSitemap=await read('sitemap.xml');
const mainPaths=['/','/features','/press','/terms','/privacy','/security','/bug-bounty','/about','/networks',...networkCatalog.networks.map(n=>'/networks/'+n.slug)];
const dates=new Map([...oldSitemap.matchAll(/<url>[\s\S]*?<loc>([^<]+)<\/loc>[\s\S]*?<lastmod>([^<]+)<\/lastmod>[\s\S]*?<\/url>/g)].map(m=>[m[1],m[2]]));
dates.set('https://oathwallet.org/press','2026-10-31');
for (const path of mainPaths) {
 if(path==='/bug-bounty') dates.set('https://oathwallet.org'+path,'2026-10-31');
 else if(path==='/' || path.startsWith('/networks')) dates.set('https://oathwallet.org'+path,networkCatalog.reviewed);
 else if(!dates.has('https://oathwallet.org'+path)) dates.set('https://oathwallet.org'+path,'2026-10-27');
}
const xml=`<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${mainPaths.map(path=>{const url='https://oathwallet.org'+path;return `  <url><loc>${url}</loc>${dates.has(url)?`<lastmod>${esc(dates.get(url))}</lastmod>`:''}</url>`;}).join('\n')}\n</urlset>\n`;
await write('sitemap.xml',xml);
console.log('Built canonical sitemap, homepage answers, article breadcrumbs and site identity.');
