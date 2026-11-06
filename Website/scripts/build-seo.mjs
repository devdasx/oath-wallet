import priorityGuidance from '../content/priority-guidance.json' with {type:'json'};
import decisionGuides from '../content/decision-guides.json' with {type:'json'};
// Canonical metadata and visible navigation for the existing three-site layout.
// Does not rewrite editorial dates to the build time or manufacture translations.
import {readFile,writeFile} from 'node:fs/promises';
import featureCatalog from '../content/features.json' with {type:'json'};
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
const release=JSON.parse(await read('release-status.json'));
if(data.facts.app_version!==release.version || data.facts.app_build!==release.build)throw Error('Current product facts disagree with the published release record');
const rating=data.facts.app_store_rating;
if(!Number.isFinite(rating.value)||rating.value<1||rating.value>5||!Number.isInteger(rating.count)||rating.count<1||!/^\d{4}-\d{2}-\d{2}$/.test(rating.checked_on))throw Error('Invalid attributed App Store rating snapshot');
const ratingDate=new Intl.DateTimeFormat('en-US',{month:'long',day:'numeric',year:'numeric',timeZone:'UTC'}).format(new Date(rating.checked_on+'T00:00:00Z'));
function productMetadata(node){
 node.name='Oath: Crypto & Bitcoin Wallet';
 node.softwareVersion=release.version;
 node.operatingSystem='iOS, iPadOS';
 node.featureList=data.features.map(f=>f.name);
 node.softwareHelp='https://help.oathwallet.org/';
 // codeRepository belongs to SoftwareSourceCode, not MobileApplication.
 node.subjectOf={'@type':'SoftwareSourceCode','@id':data.facts.source_code+'#source',name:'Oath Wallet public source',url:data.facts.source_code,codeRepository:data.facts.source_code};
 delete node.codeRepository;
 // Imported App Store ratings remain attributed, dated visible content.
 delete node.aggregateRating;
 delete node.review;
}

// Current product metadata comes from the same reviewed facts as agent discovery.
// Historical articles and screenshot versions keep their original provenance.
let features=await read('features.html');
features=features.replace(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g,(_,raw)=>{
 const schema=JSON.parse(raw);
 for(const node of schema['@graph']||[]){
  if(node['@type']==='MobileApplication')productMetadata(node);
  if(node['@type']==='ItemList'&&node.name==='Oath features')node.itemListElement=data.features.map((f,i)=>({'@type':'ListItem',position:i+1,name:f.name,description:f.summary}));
 }
 return `<script type="application/ld+json">${json(schema)}</script>`;
});
await write('features.html',features);

// Keep one identified WebPage for Security, retaining its genuine editorial date.
let security=await read('security.html');
security=security.replace(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g,(_,raw)=>{
 const schema=JSON.parse(raw),graph=schema['@graph']||[];
 const page=graph.find(n=>n['@id']==='https://oathwallet.org/security');
 if(page){
  const duplicate=graph.find(n=>n!==page&&n['@type']==='WebPage'&&n.url===page.url);
  if(duplicate?.dateModified&&!page.dateModified)page.dateModified=duplicate.dateModified;
  schema['@graph']=graph.filter(n=>n===page||n['@type']!=='WebPage'||n.url!==page.url);
 }
 return `<script type="application/ld+json">${json(schema)}</script>`;
});
await write('security.html',security);

// Preserve the designed homepage; provide the same useful answers before and
// after enhancement. Do not add FAQ rich-result markup: this is not a health
// or government site eligible for Google's FAQ feature.
let home=await read('index.html');
const transferStart='<!-- oath-transfer-entry:start -->',transferEnd='<!-- oath-transfer-entry:end -->';
const transferBlock=new RegExp(transferStart+'[\\s\\S]*?'+transferEnd+'\\s*','g');
const transferSection=`${transferStart}<section id="transfer-preparation" style="max-width:1320px;margin:0 auto;padding:72px clamp(20px,5vw,32px);border-top:1px solid rgba(242,240,234,.14)"><p style="font:12px/1.5 'IBM Plex Mono',monospace;letter-spacing:.1em;text-transform:uppercase;color:#B9B7B0">Before your next transfer</p><h2 style="margin:16px 0 24px;font:400 clamp(36px,5vw,64px)/1.08 'Instrument Serif',serif">The right token.<br>The right network.</h2><p style="max-width:64ch;font:400 18px/1.6 'Instrument Sans',sans-serif;color:#B9B7B0">A familiar symbol is only the beginning. Match the exact token, check its receiving network and find the fee asset before you send.</p><p style="font:400 17px/1.6 'Instrument Sans',sans-serif"><a href="/networks/choose-token-network#prepare-transfer" style="display:inline-block;padding:14px 22px;background:#F2F0EA;color:#0A0A0B;border-radius:8px;text-decoration:none">Prepare a transfer →</a></p><p style="font:400 15px/1.6 'Instrument Sans',sans-serif;color:#B9B7B0">Start with USDT or USDC, or <a href="/tokens">find your token</a> in Oath’s catalog.</p></section>${transferEnd}`;
home=home.replace(transferBlock,'');
if(!home.includes('<section id="get"'))throw Error('Homepage transfer entry anchor missing');
home=home.replace('<section id="get"',transferSection+'\n<section id="get"');
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
 .replace(/(<span\b[^>]*font:400 clamp\(96px,14vw,200px\)[^>]*>)[\d.]+(<\/span>)/g,`$1${rating.value.toFixed(1)}$2`)
 .replace(/\d+ US ratings/g,`${rating.count} US ratings`)
 .replace(/Rating checked [A-Z][a-z]+ \d{1,2}, \d{4}/g,`Rating checked ${ratingDate}`);
home=home.replace(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g,(_,raw)=>{
 const schema=JSON.parse(raw);
 for(const node of schema['@graph']||[]) {
  if(node['@type']==='WebPage'){node.name=title;node.description=description;}
  if(node['@type']==='MobileApplication')productMetadata(node);
 }
 return `<script type="application/ld+json">${json(schema)}</script>`;
});
await write('index.html',home);
let markdown=await read('index.md');
markdown=markdown.replace(transferBlock,'');
markdown+='\n'+transferStart+'\n## The right token. The right network.\n\nMatch the exact token, check its receiving network and find the fee asset before you send. Start with USDT or USDC, or find your token in Oath’s catalog.\n\n[Prepare a transfer](https://oathwallet.org/networks/choose-token-network#prepare-transfer) · [Find your token](https://oathwallet.org/tokens)\n'+transferEnd+'\n';
markdown=markdown.replace(/\n<!-- oath-questions:start -->[\s\S]*?<!-- oath-questions:end -->\n?/g,'')
 .replace(/Rated \*\*[\d.]+ out of 5\*\* from \d+ ratings in the US App Store · checked [A-Z][a-z]+ \d{1,2}, \d{4} on the App Store\./,`Rated **${rating.value.toFixed(1)} out of 5** from ${rating.count} ratings in the US App Store · checked ${ratingDate} on the App Store.`);
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
  {'@type':'ListItem',position:1,name:'Oath Wallet Articles',item:ARTICLE_ORIGIN+'/'},
  {'@type':'ListItem',position:2,name:post.headline,item:canonical}
 ]};
 html=html.replace(/(<meta property="og:site_name" content=")[^"]*"/g,'$1Oath Wallet Articles"');
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
const publishedArticles=JSON.parse(await read('oath-data.json')).articles;
archive=archive.replace(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g,(_,raw)=>{
 const schema=JSON.parse(raw);
 for(const node of schema['@graph']||[]) {
  if(node['@type']==='WebSite'){node['@id']=ARTICLE_ORIGIN+'/#site';node.url=ARTICLE_ORIGIN+'/';node.name='Oath Wallet Articles';node.alternateName='Oath Articles';}
  if(node['@type']==='WebPage')node.isPartOf={'@id':ARTICLE_ORIGIN+'/#site'};
  if(node['@type']==='Blog')node.blogPost=publishedArticles.filter(a=>a.locale==='en').map(a=>({
   '@type':'BlogPosting',headline:a.title,url:new URL(a.url).origin===ARTICLE_ORIGIN?a.url:articleURL(new URL(a.url).pathname),datePublished:a.published_at
  }));
 }
 return `<script type="application/ld+json">${json(schema)}</script>`;
});
archive=archive.replace(/(<meta property="og:site_name" content=")[^"]*"/g,'$1Oath Wallet Articles"');
await write('articles.html',archive);

// The main sitemap must not retain moved support or article URLs.
const currentSitemap=await read('sitemap.xml');
const oldSitemap=currentSitemap.includes('<sitemapindex')?await read('sitemaps/pages.xml'):currentSitemap;
const mainPaths=[...decisionGuides.pages.map(p=>p.path),'/','/features','/press','/terms','/privacy','/security','/bug-bounty','/about','/networks',...networkCatalog.networks.map(n=>'/networks/'+n.slug),...featureCatalog.features.map(f=>f.path)];
const dates=new Map([...oldSitemap.matchAll(/<url>[\s\S]*?<loc>([^<]+)<\/loc>[\s\S]*?<lastmod>([^<]+)<\/lastmod>[\s\S]*?<\/url>/g)].map(m=>[m[1],m[2]]));
dates.set('https://oathwallet.org/press','2026-10-31');
for (const path of mainPaths) {
 if(decisionGuides.pages.some(p=>p.path===path)||priorityGuidance.pages[path]||path==='/about') dates.set('https://oathwallet.org'+path,'2026-11-06');
 else if(path==='/features'||path.startsWith('/features/')) dates.set('https://oathwallet.org'+path,featureCatalog.reviewed);
 else if(path==='/bug-bounty') dates.set('https://oathwallet.org'+path,'2026-10-31');
 else if(path==='/') dates.set('https://oathwallet.org'+path,'2026-11-06');
 else if(path.startsWith('/networks')) dates.set('https://oathwallet.org'+path,networkCatalog.reviewed);
 else if(!dates.has('https://oathwallet.org'+path)) dates.set('https://oathwallet.org'+path,'2026-10-27');
}
const xml=`<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${mainPaths.map(path=>{const url='https://oathwallet.org'+path;return `  <url><loc>${url}</loc>${dates.has(url)?`<lastmod>${esc(dates.get(url))}</lastmod>`:''}</url>`;}).join('\n')}\n</urlset>\n`;
await write('sitemap.xml',xml);
console.log('Built canonical sitemap, homepage answers, article breadcrumbs and site identity.');
