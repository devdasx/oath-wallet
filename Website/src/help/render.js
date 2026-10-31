import walkthroughs from './walkthroughs.json' with { type: 'json' };
import {siteHeader, siteFooter} from './site-chrome.js';
export const HELP_ORIGIN = 'https://help.oathwallet.org';
// One versioned image for every Help Center route, including future guides.
// Keep it under /help/ so the Help Center's asset router serves it directly.
export const HELP_SOCIAL_IMAGE = HELP_ORIGIN + '/help/assets/oath-help-center-v1.png';
const HELP_SOCIAL_ALT = 'Oath Help Center. Clear answers. More confidence. Guides for every step of your wallet.';
export const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const icons = {
 sparkles:'M12 3l2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5Z',
 wallet:'M4 6h15v14H4V6Zm0 0V4h13v2m-2 6h6v4h-6z',
 cloud:'M6 18a5 5 0 0 1-1-10 7 7 0 0 1 13-1 5.5 5.5 0 0 1 0 11M12 11v10m-3-7 3-3 3 3',
 lock:'M6 10h12v11H6zM8 10V6a4 4 0 0 1 8 0v4m-4 5v2',
 layers:'m12 3 10 5-10 5L2 8 12 3Zm-10 9 10 5 10-5M2 16l10 5 10-5',
 qr:'M3 3h6v6H3zM15 3h6v6h-6zM3 15h6v6H3zM15 15h3v3h3v3h-6v-3m6-3v-3M12 3v3M3 12h3',
 arrows:'M4 7h15m-4-4 4 4-4 4M20 17H5m4-4-4 4 4 4',
 sliders:'M3 6h6m4 0h8M3 12h12m4 0h2M3 18h2m4 0h12M9 3v6m6 0v6M5 15v6',
 search:'m16 16 5 5M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0',
 arrow:'M5 12h14m-5-5 5 5-5 5'
};
export const icon=(name,cls='')=>`<svg class="${esc(cls)}" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${icons[name]||icons.layers}"/></svg>`;
const nav=`<a class="skip" href="#main">Skip to content</a>${siteHeader}`;
const footer=`<section class="support" aria-labelledby="support-title"><div><span class="eyebrow">A little more help</span><h2 id="support-title">A real question.<br><em>A real conversation.</em></h2><p>Tell us what happened. Keep recovery words, private keys and passwords private.</p></div><a class="button" href="mailto:care@oathwallet.org">Contact Oath ${icon('arrow')}</a></section>${siteFooter}`;
const search=(value='',compact=false)=>`<form class="search ${compact?'compact':''}" action="/search" role="search">${icon('search')}<label class="sr-only" for="help-search">Search the Help Center</label><input id="help-search" name="q" type="search" value="${esc(value)}" placeholder="Search guides, features or questions" autocomplete="off" maxlength="120"><button type="submit">Search</button></form>`;
const version=`<p class="version-note">Guidance updated for Oath 4.1.14 (98). This source release has no Apple upload or review submission; check the version installed on your device. Screenshots were captured for 4.0.3 and may differ from current controls. <a href="/articles/send-availability">Sending guide</a></p>`;
function socialMetadata(title, description) {
 return `<meta property="og:site_name" content="Oath Help Center">
<meta property="og:locale" content="en_US">
<meta property="og:image" content="${HELP_SOCIAL_IMAGE}">
<meta property="og:image:secure_url" content="${HELP_SOCIAL_IMAGE}">
<meta property="og:image:type" content="image/png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="${HELP_SOCIAL_ALT}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:site" content="@OathWallet">
<meta name="twitter:title" content="${esc(title)}">
<meta name="twitter:description" content="${esc(description)}">
<meta name="twitter:image" content="${HELP_SOCIAL_IMAGE}">
<meta name="twitter:image:alt" content="${HELP_SOCIAL_ALT}">`;
}
function breadcrumbs(items) {
 return {'@type':'BreadcrumbList',itemListElement:items.map(([name,item],i)=>({'@type':'ListItem',position:i+1,name,item}))};
}
const publisher={'@type':'Organization','@id':'https://oathwallet.org/#org',name:'Oath Wallet',url:'https://oathwallet.org/',logo:{'@type':'ImageObject',url:'https://oathwallet.org/apple-touch-icon.png'}};
function shell(title,description,path,body,schema){
 const canonical=HELP_ORIGIN+path;
 return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)} — Oath Help Center</title><meta name="description" content="${esc(description)}"><meta name="robots" content="max-image-preview:large"><link rel="canonical" href="${esc(canonical)}"><meta property="og:title" content="${esc(title)}"><meta property="og:description" content="${esc(description)}"><meta property="og:url" content="${esc(canonical)}"><meta property="og:type" content="website">${socialMetadata(title,description)}<meta name="theme-color" content="#0A0A0B"><link rel="icon" href="/favicon.svg?v=20261031-rounded"><link rel="stylesheet" href="/help/help.css?v=20261031-redesign1"><link rel="stylesheet" href="/help/site-chrome.css?v=20261031-redesign1"><script src="/site-chrome.js" defer></script><script src="/help/help.js?v=20261031-redesign1" defer></script>${schema?'<script type="application/ld+json">'+JSON.stringify(schema).replace(/</g,'\\u003c')+'</script>':''}${path.startsWith('/search')?'<meta name="robots" content="noindex,follow">':''}</head><body>${nav}${body}${footer}</body></html>`;
}
function row(a){return `<a class="article-row" href="/articles/${esc(a.slug)}"><div><h3>${esc(a.title)}</h3><p>${esc(a.summary)}</p></div>${icon('arrow')}<span class="sr-only">Read article</span></a>`;}
export function home(data){
 const picks=['create-wallet','send-availability','receive-crypto','connect-dapp','bulk-revoke-access','backup-all-wallets'];
 return shell('Wallet setup, backup & support','Step-by-step Oath guides with app screenshots. Learn wallets, backup, security, sending, receiving, dApps and permissions.','/',`
 <main id="main" class="help-home">
  <section class="hero" aria-labelledby="help-title">
   <div class="hero-copy"><span class="eyebrow"><span class="status-dot" aria-hidden="true"></span> The Oath Help Center</span><h1 id="help-title">Your wallet.<br><em>Understood.</em></h1><p>Clear answers for every step.<br>From your first wallet to the finer details.</p><a class="text-link" href="#browse">Explore the guides <span aria-hidden="true">↓</span></a></div>
   <div class="hero-search"><span class="eyebrow">What can we help you with?</span>${search()}<div class="search-caption"><span>Start with a question. Find your next step.</span><span class="keyboard-hint">Press <kbd>/</kbd> to search</span></div><nav class="quick-links" aria-label="Popular guides"><span class="eyebrow">Often asked</span><a href="/articles/restore-icloud"><span>How do I restore my wallet?</span>${icon('arrow')}</a><a href="/articles/receive-crypto"><span>How do I receive crypto?</span>${icon('arrow')}</a><a href="/articles/backup-all-wallets"><span>How do I back up my wallets?</span>${icon('arrow')}</a></nav></div>
  </section>
  <section class="browse" id="browse" aria-labelledby="browse-title"><div class="section-heading"><div><span class="eyebrow">The essentials & everything after</span><h2 id="browse-title">Make yourself <em>at home.</em></h2></div><span class="count">${data.articles.length} practical guides<br>${data.categories.length} collections</span></div><div class="category-grid">${data.categories.map((c,i)=>`<a class="category" href="/collections/${esc(c.id)}"><div class="category-top"><span class="category-number">${String(i+1).padStart(2,'0')}</span><span class="category-icon">${icon(c.icon)}</span></div><h3>${esc(c.title)}</h3><p>${esc(c.description)}</p><div class="category-bottom"><span>${data.articles.filter(a=>a.category_id===c.id).length} articles</span>${icon('arrow')}</div></a>`).join('')}</div></section>
  <section class="popular" aria-labelledby="essentials-title"><div class="essentials-intro"><span class="eyebrow">A good place to start</span><h2 id="essentials-title">Small steps.<br><em>More confidence.</em></h2><p>Set up your wallet, keep a recovery route, and get familiar with the everyday things.</p><a class="button" href="/collections/start">Getting started ${icon('arrow')}</a><span class="essentials-footnote">Your keys. Your choices. Your pace.</span></div><div class="essentials-guides"><span class="eyebrow">Everyday essentials</span>${picks.map(s=>data.articles.find(a=>a.slug===s)).filter(Boolean).map(row).join('')}</div></section>
  ${version}
 </main>`,{'@context':'https://schema.org','@type':'WebSite','@id':HELP_ORIGIN+'/#site',name:'Oath Help Center',alternateName:'Oath Wallet Help',url:HELP_ORIGIN+'/',publisher});
}
export function collection(data,cat){
 const articles=data.articles.filter(a=>a.category_id===cat.id);
 return shell(cat.title,cat.description,'/collections/'+cat.id,`<main id="main" class="collection-page"><div class="page-tools"><nav class="breadcrumbs" aria-label="Breadcrumb"><a href="/">Help Center</a><span aria-hidden="true">/</span><span aria-current="page">${esc(cat.title)}</span></nav>${search('',true)}</div><div class="collection-layout"><section class="collection-heading"><span class="category-icon">${icon(cat.icon)}</span><span class="eyebrow">Explore the collection</span><h1>${esc(cat.title)}</h1><p>${esc(cat.description)}</p><span class="count">${articles.length} articles to guide you</span><a class="text-link" href="/">All collections ${icon('arrow')}</a></section><div class="article-list">${articles.map(row).join('')}</div></div>${version}</main>`,{'@context':'https://schema.org','@graph':[{'@type':'CollectionPage',name:cat.title,description:cat.description,url:HELP_ORIGIN+'/collections/'+cat.id,isPartOf:{'@id':HELP_ORIGIN+'/#site'}},breadcrumbs([['Help Center',HELP_ORIGIN+'/'],[cat.title,HELP_ORIGIN+'/collections/'+cat.id]])]});
}
function screenshots(a) {
 const items=(walkthroughs[a.slug]||[]).filter(x=>/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(x.image));
 if (!items.length) return a.screenshot ? `<figure id="in-the-app" class="app-capture"><a href="/help/assets/${esc(a.screenshot)}.webp"><img src="/help/assets/${esc(a.screenshot)}.webp" width="402" height="874" alt="${esc(a.title)}" loading="lazy"></a><figcaption>App screenshot. Example data only.</figcaption></figure>` : '';
 return `<section id="in-the-app" class="walkthrough"><h2>Follow along in Oath</h2><p class="capture-note">Real app screens with illustrative demo data, captured for 4.0.3. The text above describes 4.1.14; newer options may not appear in these images. No live funds were sent, swapped or revoked for these examples. Never send funds to an example address. Tap an image to inspect it at full size.</p><div class="walkthrough-grid">${items.map((x,i)=>`<figure><a class="capture-link" href="/help/assets/${esc(x.image)}.webp" aria-label="Open full-size screenshot: ${esc(x.alt)}"><img src="/help/assets/${esc(x.image)}.webp" width="1320" height="2868" alt="${esc(x.alt)}" loading="lazy" decoding="async"></a><figcaption><span class="capture-number">${i+1}</span><span>${esc(x.caption)}${x.step?` <a href="#step-${x.step}">See step ${x.step}</a>.`:''}</span></figcaption></figure>`).join('')}</div></section>`;
}
// Help content remains plain text. Only explicit headings and full, approved
// primary-source URLs have formatting; arbitrary HTML/Markdown is always escaped.
function articleParagraph(text) {
 if (text.startsWith('## ')) return `<h3>${esc(text.slice(3))}</h3>`;
 const source=/^Source: (https:\/\/[^\s]+)$/.exec(text);
 if (source) {
  const official=/^https:\/\/(?:developers\.stellar\.org|xrpl\.org|solana\.com|developers\.tron\.network|docs\.near\.org|docs\.ton\.org|github\.com\/near\/nearcore)\//;
  if (official.test(source[1])) return `<p>Source: <a href="${esc(source[1])}" rel="noreferrer">${esc(source[1])}</a></p>`;
 }
 return `<p>${esc(text)}</p>`;
}
export function article(data,a){const cat=data.categories.find(c=>c.id===a.category_id);const related=(a.related||[]).map(s=>data.articles.find(x=>x.slug===s)).filter(Boolean);const minutes=Math.max(1,Math.ceil([a.summary,...a.steps,...a.body,a.note].join(' ').split(/\s+/).length/200));
 return shell(a.title,a.summary,'/articles/'+a.slug,`<main id="main" class="article-page"><div class="page-tools"><nav class="breadcrumbs" aria-label="Breadcrumb"><a href="/">Help Center</a><span>/</span><a href="/collections/${cat.id}">${esc(cat.title)}</a><span>/</span><span>${esc(a.title)}</span></nav>${search('',true)}</div><div class="reading-layout"><aside class="toc" aria-label="On this page"><span class="eyebrow">In this article</span><a href="#overview">Overview</a><a href="#steps">How to do it</a>${a.screenshot || walkthroughs[a.slug]?.length?'<a href="#in-the-app">In the app</a>':''}<a href="#good-to-know">Good to know</a><a href="#related">Related articles</a></aside><article><header id="overview" class="article-heading"><a class="category-label" href="/collections/${cat.id}">${esc(cat.title)}</a><h1>${esc(a.title)}</h1><p class="dek">${esc(a.summary)}</p><div class="meta"><a href="https://oathwallet.org/about#editorial" rel="author">Oath team</a><span>${minutes} min read</span><span>Updated ${new Date(a.updated_at).toLocaleDateString('en-US',{year:'numeric',month:'short',day:'numeric',timeZone:'UTC'})}</span></div><p class="app-version">${esc(a.app_version)}</p></header><div class="route"><span>Where to find it</span><p>${esc(a.route)}</p></div><section id="steps"><h2>How to do it</h2><ol class="steps">${a.steps.map((s,i)=>`<li id="step-${i+1}">${esc(s)}</li>`).join('')}</ol>${a.body.map(articleParagraph).join('')}</section>${screenshots(a)}<aside class="callout" id="good-to-know"><span>${icon('layers')} Good to know</span><p>${esc(a.note)}</p></aside><div class="article-feedback"><h2>Still need a hand?</h2><p><a href="mailto:care@oathwallet.org?subject=${encodeURIComponent('Help with: '+a.title)}">Contact support about this article ${icon('arrow')}</a></p><button class="print" type="button" data-print>Print article</button></div><section id="related" class="related"><h2>Related articles</h2>${related.map(row).join('')}</section></article></div></main>`,{'@context':'https://schema.org','@graph':[
  {'@type':['Article','TechArticle'],'@id':HELP_ORIGIN+'/articles/'+a.slug+'#article',headline:a.title,description:a.summary,dateModified:a.updated_at,datePublished:a.published_at,inLanguage:'en',author:{'@type':'Organization',name:'Oath team',url:'https://oathwallet.org/about#editorial'},publisher,mainEntityOfPage:HELP_ORIGIN+'/articles/'+a.slug,isPartOf:{'@id':HELP_ORIGIN+'/#site'},image:a.screenshot ? HELP_ORIGIN+'/help/assets/'+a.screenshot+'.webp' : HELP_SOCIAL_IMAGE},
  breadcrumbs([['Help Center',HELP_ORIGIN+'/'],[cat.title,HELP_ORIGIN+'/collections/'+cat.id],[a.title,HELP_ORIGIN+'/articles/'+a.slug]])
 ]});
}
export function searchResults(data,query){const words=query.toLocaleLowerCase().split(/\s+/).filter(Boolean);const matches=words.length?data.articles.map(a=>({a,score:words.reduce((n,w)=>n+(a.title.toLowerCase().includes(w)?8:0)+(a.summary.toLowerCase().includes(w)?3:0),0)})).filter(({a})=>words.every(w=>[a.title,a.summary,a.route,...a.tags,...a.steps,...a.body,a.note].join(' ').toLowerCase().includes(w))).sort((a,b)=>b.score-a.score).map(x=>x.a):[];
 return shell('Search','Search Oath help articles.','/search',`<main id="main" class="search-page"><nav class="breadcrumbs" aria-label="Breadcrumb"><a href="/">Help Center</a><span>/</span><span aria-current="page">Search</span></nav><span class="eyebrow">A little clarity goes a long way</span><h1>Find your <em>answer.</em></h1>${search(query)}<p class="result-count" role="status">${!query?'Try a feature, a setting or a question.':`${matches.length} ${matches.length===1?'answer':'answers'} for “${esc(query)}”`}</p>${matches.length?`<div class="article-list">${matches.map(row).join('')}</div>`:query?'<div class="empty"><h2>No matching articles yet.</h2><p>Try fewer words, a network name, or “backup”. You can also browse a collection or contact us.</p><a class="button" href="/">Browse all guides</a></div>':''}</main>`);}
export function notFound(){return shell('Page not found','Find your way back to the Oath Help Center.','/404',`<main id="main" class="empty not-found"><span class="eyebrow">404 · A small detour</span><h1>Let’s get you<br>back on track.</h1><p>This article may have moved or isn’t published yet.</p>${search()}<a class="text-link" href="/">Explore the Help Center ${icon('arrow')}</a></main>`);}
