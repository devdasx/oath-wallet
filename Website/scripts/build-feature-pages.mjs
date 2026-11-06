import {priorityHTML,priorityMarkdown} from '../src/seo-guidance.js';
// Product pages use pinned release scope and unchanged, version-labelled app captures.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import catalog from '../content/features.json' with {type:'json'};
import migrations from '../content/wallet-migrations.json' with {type:'json'};
import networks from '../content/networks.json' with {type:'json'};
import help from '../src/help/content.json' with {type:'json'};
import {buildSiteChrome} from './build-help-chrome.mjs';
const root=new URL('../public/',import.meta.url);
const read=p=>readFile(new URL(p,root),'utf8');
const write=(p,v)=>writeFile(new URL(p,root),v);
const esc=v=>String(v).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
const json=v=>JSON.stringify(v).replaceAll('<','\\u003c');
const app='https://apps.apple.com/app/id6780187283';
const origin='https://oathwallet.org';
const guide=slug=>'https://help.oathwallet.org/articles/'+slug;
const source=path=>`https://github.com/OathWallet/oath-wallet/blob/${catalog.sourceCommit}/${path}`;
const chrome=await buildSiteChrome();
const header=`<!-- oath-shared-header:start -->${chrome.header}<!-- oath-shared-header:end -->`;
const footer=`<!-- oath-shared-footer:start -->${chrome.footer}<!-- oath-shared-footer:end -->`;
const network=slug=>networks.networks.find(n=>n.slug===slug);
const networkLinks=slugs=>slugs.map(slug=>`<a href="/networks/${slug}">${esc(network(slug).name)}</a>`).join('');
await mkdir(new URL('features/',root),{recursive:true});
for(const f of catalog.features){
 if(!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(f.slug)||f.path!=='/features/'+f.slug)throw new Error('Invalid feature path');
 for(const slug of [f.guide,f.detailGuide,...f.guides.map(g=>g.slug)])if(!help.articles.some(a=>a.slug===slug))throw new Error('Missing feature guide: '+slug);
 for(const s of f.scope)for(const slug of s.links)if(!network(slug))throw new Error('Missing network: '+slug);
 const bytes=await readFile(new URL('.'+f.image.path,root));
 if(createHash('sha256').update(bytes).digest('hex')!==f.image.sha256)throw new Error('Feature screenshot changed: '+f.image.path);
 const url=origin+f.path;
 const version=`Feature scope reviewed for Oath ${catalog.version} (${catalog.build}) on ${catalog.reviewed}. Screens show ${f.image.version}; appearance can differ in newer versions.`;
 const schema={'@context':'https://schema.org','@graph':[
  {'@type':'WebPage','@id':url,url,name:f.title,description:f.description,dateModified:catalog.reviewed,isPartOf:{'@id':origin+'/#site'},primaryImageOfPage:{'@type':'ImageObject',url:origin+f.image.path,caption:f.image.caption+' '+f.image.version,width:f.image.width,height:f.image.height}},
  {'@type':'BreadcrumbList',itemListElement:[{name:'Home',item:origin+'/'},{name:'Features',item:origin+'/features'},{name:f.name,item:url}].map((x,i)=>({'@type':'ListItem',position:i+1,...x}))}
 ]};
 const related=catalog.features.filter(x=>x!==f);
 const body=`<nav class="feature-crumbs" aria-label="Breadcrumb"><a href="/">Home</a><span>/</span><a href="/features">Features</a><span>/</span><span aria-current="page">${esc(f.label)}</span></nav>
<section class="feature-hero" aria-labelledby="feature-title"><div class="feature-hero-copy"><p class="feature-kicker">${esc(f.label)} / Oath for iPhone</p><h1 id="feature-title">${esc(f.heading)}</h1><p class="feature-dek">${esc(f.intro)}</p><div class="feature-actions"><a class="feature-download" href="${app}">Get Oath for iOS</a><a href="${guide(f.guide)}">Read the detailed guide <span aria-hidden="true">→</span></a></div><a class="feature-jump" href="#scope">Explore supported scope <span aria-hidden="true">↓</span></a></div>
<figure class="feature-capture"><a href="${f.image.path}" aria-label="Open full-size ${esc(f.label)} screenshot"><img src="${f.image.path}" alt="${esc(f.image.alt)}" width="${f.image.width}" height="${f.image.height}" fetchpriority="high"></a><figcaption><strong>${esc(f.image.version)} · App screenshot</strong>${esc(f.image.caption)}</figcaption></figure></section>
<div class="feature-highlights">${f.highlights.map((h,i)=>`<div><span class="feature-kicker">0${i+1}</span><h2>${esc(h.title)}</h2><p>${esc(h.text)}</p></div>`).join('')}</div>
<section class="feature-section" id="scope" aria-labelledby="scope-title"><div><p class="feature-kicker">Supported scope</p><h2 id="scope-title">${esc(f.scopeTitle)}</h2><p>${esc(f.scopeIntro)}</p></div><div class="feature-scope">${f.scope.map(s=>`<div><h3>${esc(s.label)}</h3><p>${esc(s.detail)}</p>${s.links.length?`<nav class="feature-network-links" aria-label="${esc(s.label)} guides">${networkLinks(s.links)}</nav>`:''}</div>`).join('')}</div></section>
<section class="feature-section" aria-labelledby="steps-title"><div><p class="feature-kicker">How it works</p><h2 id="steps-title">${esc(f.stepsTitle)}</h2><a href="${guide(f.guide)}">Open the step-by-step guide →</a></div><ol class="feature-steps">${f.steps.map(s=>`<li><h3>${esc(s.title)}</h3><p>${esc(s.text)}</p></li>`).join('')}</ol></section>
<section class="feature-detail"><p class="feature-kicker">The next step</p><h2>${esc(f.detailTitle)}</h2><p>${esc(f.detail)}</p><a href="${guide(f.detailGuide)}">${esc(f.detailLink)} →</a></section>
<section class="feature-section" aria-labelledby="questions-title"><div><p class="feature-kicker">A few useful answers</p><h2 id="questions-title">Before you begin.</h2></div><div class="feature-questions">${f.questions.map(q=>`<details><summary>${esc(q.q)}</summary><p>${esc(q.a)}</p></details>`).join('')}</div></section>
<section class="feature-guides" aria-labelledby="guides-title"><h2 id="guides-title">Go a little deeper.</h2><div>${f.guides.map(g=>`<a href="${guide(g.slug)}">${esc(g.label)} <span aria-hidden="true">→</span></a>`).join('')}${(f.externalLinks||[]).map(l=>`<a href="${esc(l.url)}">${esc(l.label)} <span aria-hidden="true">→</span></a>`).join('')}</div></section>
${priorityHTML(f.path)}
<aside class="feature-source"><p>${esc(version)}</p><details><summary>Release and source details</summary><p><a href="https://github.com/OathWallet/oath-wallet/blob/main/releases/${catalog.version}-distribution.json">Release availability record</a></p><ul>${f.sources.map(s=>`<li><a href="${source(s.path)}">${esc(s.path.split('/').pop())}</a></li>`).join('')}</ul><p>These references document the reviewed release. Source review and sample screens do not establish a completed live transaction or backup.</p></details></aside>
<section class="feature-related" aria-labelledby="related-title"><p class="feature-kicker">More from Oath</p><h2 id="related-title">Keep exploring.</h2><div>${related.map(r=>`<a href="${r.path}"><span>${esc(r.name)}</span><span aria-hidden="true">→</span></a>`).join('')}</div><a href="/features">All Oath features</a> · <a href="https://articles.oathwallet.org/oath-wallet-release-history">Release history</a></section>`;
 await write(f.path.slice(1)+'.html',`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${esc(f.title)}</title><meta name="description" content="${esc(f.description)}"><link rel="canonical" href="${url}"><meta name="robots" content="index,follow,max-image-preview:large"><meta property="og:type" content="website"><meta property="og:site_name" content="Oath Wallet"><meta property="og:title" content="${esc(f.title)}"><meta property="og:description" content="${esc(f.description)}"><meta property="og:url" content="${url}"><meta property="og:image" content="${origin}/og/features.png"><meta name="twitter:card" content="summary_large_image"><meta name="twitter:title" content="${esc(f.title)}"><meta name="twitter:description" content="${esc(f.description)}"><meta name="twitter:image" content="${origin}/og/features.png"><link rel="icon" href="/favicon.ico"><link rel="alternate" type="text/markdown" href="${url}.md"><link rel="stylesheet" href="/feature-pages.css"><link rel="stylesheet" href="/seo-guidance.css"><link rel="stylesheet" href="/site-chrome.css"><link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&amp;family=Instrument+Sans:wght@400;500;600&amp;family=IBM+Plex+Mono:wght@400;500&amp;display=swap"><script type="application/ld+json">${json(schema)}</script></head><body class="feature-page"><a class="feature-skip" href="#content">Skip to content</a>${header}<main id="content" class="feature-main" tabindex="-1">${body}</main>${footer}<script src="/site-chrome.js" defer></script></body></html>\n`);
 const markdown=`# ${f.name}\n\n${f.intro}\n\n[Get Oath for iOS](${app}) · [Read the detailed guide](${guide(f.guide)})\n\n![${f.image.alt}](${origin+f.image.path})\n\n${f.image.version} · ${f.image.caption}\n\n${f.highlights.map(h=>`## ${h.title}\n\n${h.text}`).join('\n\n')}\n\n## ${f.scopeTitle}\n\n${f.scopeIntro}\n\n${f.scope.map(s=>`### ${s.label}\n\n${s.detail}${s.links.length?'\n\n'+s.links.map(slug=>`[${network(slug).name}](${origin}/networks/${slug})`).join(' · '):''}`).join('\n\n')}\n\n## ${f.stepsTitle}\n\n${f.steps.map((s,i)=>`${i+1}. **${s.title}.** ${s.text}`).join('\n')}\n\n## ${f.detailTitle}\n\n${f.detail}\n\n[${f.detailLink}](${guide(f.detailGuide)})\n\n## Questions\n\n${f.questions.map(q=>`### ${q.q}\n\n${q.a}`).join('\n\n')}\n\n## Detailed guides\n\n${f.guides.map(g=>`- [${g.label}](${guide(g.slug)})`).join('\n')}\n${(f.externalLinks||[]).map(l=>`- [${l.label}](${l.url})`).join('\n')}\n\n${priorityMarkdown(f.path)}\n\n## Release and source details\n\n${version}\n\n[Release availability record](https://github.com/OathWallet/oath-wallet/blob/main/releases/${catalog.version}-distribution.json)\n\n${f.sources.map(s=>`- [${s.path.split('/').pop()}](${source(s.path)})`).join('\n')}\n\nSource review and sample screens do not establish a completed live transaction or backup.\n\n## More Oath features\n\n${related.map(r=>`- [${r.name}](${origin+r.path})`).join('\n')}\n\n[All features](${origin}/features)\n`;
 await write(f.path.slice(1)+'.md',markdown);
}
// Put product discovery in both the initial HTML and the enhanced Features hub.
const start='<!-- oath-feature-pages:start -->',end='<!-- oath-feature-pages:end -->';
const block=new RegExp(start+'[\\s\\S]*?'+end+'\\s*','g');
let hub=await read('features.html');
hub=hub.replace(block,'');
const cards=`${start}<section class="feature-hub" aria-labelledby="feature-hub-title"><p class="feature-kicker">Find the feature you need</p><h2 id="feature-hub-title">More control. Clear next steps.</h2><div class="feature-hub-grid">${catalog.features.map((f,i)=>`<a href="${f.path}"><span class="feature-kicker">0${i+1} / ${esc(f.label)}</span><h3>${esc(f.name)}</h3><p>${esc(f.intro)}</p><span class="feature-card-link">Explore the feature <span aria-hidden="true">→</span></span></a>`).join('')}</div></section>${end}`;
const migrationCards=`<section class="feature-hub" aria-labelledby="migration-hub-title"><p class="feature-kicker">Already have a wallet?</p><h2 id="migration-hub-title">Start with the wallet you use.</h2><div class="feature-hub-grid">${migrations.guides.map(g=>`<a href="https://articles.oathwallet.org/${g.slug}"><span class="feature-kicker">${esc(g.label)}</span><h3>${esc(g.title)}</h3><p>${esc(g.summary)}</p><span class="feature-card-link">Check compatibility <span aria-hidden="true">→</span></span></a>`).join('')}</div></section>`;
if(!hub.includes('<section id="f1"'))throw new Error('Features hub anchor missing');
hub=hub.replace('<section id="f1"',cards.replace(end,migrationCards+end)+'\n<section id="f1"');
if(!hub.includes('href="/feature-pages.css"'))hub=hub.replace('</head>','<link rel="stylesheet" href="/feature-pages.css"><link rel="stylesheet" href="/seo-guidance.css"></head>');
await write('features.html',hub);
let md=(await read('features.md')).replace(block,'');
md=md.replace('## 01.',`${start}\n## Explore a feature\n\n${catalog.features.map(f=>`- [${f.name}](${f.path}): ${f.intro}`).join('\n')}\n\n## Wallet migration and compatibility\n\n${migrations.guides.map(g=>`- [${g.title}](https://articles.oathwallet.org/${g.slug}): ${g.summary}`).join('\n')}\n\n${end}\n\n## 01.`);
await write('features.md',md);
console.log(`Built ${catalog.features.length} feature product pages with version-labelled app captures and hub discovery.`);
