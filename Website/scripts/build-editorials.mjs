// Publish each reviewed Markdown folder alongside the existing multilingual archive.
import {readFile, writeFile, readdir, mkdir, rm, copyFile, lstat} from 'node:fs/promises';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {archiveRoutes} from '../src/article-routes.js';
import retired from '../content/retired-articles.json' with {type:'json'};
import {escape, renderMarkdown} from './markdown.mjs';

const web = fileURLToPath(new URL('../', import.meta.url));
const publicDir = join(web, 'public');
const source = join(web, 'content/articles');
const origin = 'https://articles.oathwallet.org';
const read = path => readFile(path, 'utf8');
const json = value => JSON.stringify(value, null, 2) + '\n';
const slugPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const reserved = new Set(['articles','assets','feed','help','index','support','privacy','press','security','features','about','terms','networks', ...retired.articles.flatMap(a => [a.slug, ...a.aliases])]);
const datePattern = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
function date(value) {
  if (!datePattern.test(value) || new Date(value).toISOString().replace('.000Z','Z') !== value) throw Error('Use a real UTC date with seconds: ' + value);
  return value;
}

async function compile(slug) {
  if (!slugPattern.test(slug) || reserved.has(slug) || Object.hasOwn(archiveRoutes, '/articles/'+slug)) throw Error('Invalid or existing article slug: ' + slug);
  const folder = join(source, slug);
  for (const name of ['metadata.json', 'article.md']) {
    if (!(await lstat(join(folder,name))).isFile()) throw Error(slug + ': expected a regular ' + name);
  }
  const meta = JSON.parse(await read(join(folder,'metadata.json')));
  for (const key of ['title','excerpt','category','cover','cover_alt']) {
    if (typeof meta[key] !== 'string' || !meta[key].trim() || /[\r\n]/.test(meta[key])) throw Error(slug + ': invalid ' + key);
  }
  const published = date(meta.published_at), updated = date(meta.updated_at ?? published);
  if (updated < published) throw Error(slug + ': updated before publication');
  if (meta.original_url && new URL(meta.original_url).protocol !== 'https:') throw Error(slug + ': original_url must use HTTPS');
  const url = origin + '/' + slug;
  const mediaPath = '/assets/articles/editorials/' + slug + '/';
  const images = new Set();
  function asset(name) {
    if (!/^[a-z0-9][a-z0-9-]*\.(png|jpe?g|webp|avif)$/.test(name)) throw Error(slug + ': invalid image filename ' + name);
    images.add(name);
    return origin + mediaPath + name;
  }
  const cover = asset(meta.cover);
  const markdown = (await read(join(folder,'article.md'))).trim();
  if (!markdown || /^# /m.test(markdown)) throw Error(slug + ': supply a body with section headings (##), and the title in metadata');
  const sections = [];
  const body = renderMarkdown(markdown, (alt, name) => '<p><img loading="lazy" alt="'+escape(alt)+'" src="'+asset(name)+'"></p>')
    .replace(/<h2>(.*?)<\/h2>/g, (_, label) => {
      const id = 'section-' + (sections.length + 1);
      sections.push('<li><a href="#'+id+'">'+label.replace(/<[^>]*>/g,'')+'</a></li>');
      return '<h2 id="'+id+'">'+label+'</h2>';
    });
  // Only the named public images are copied. A typo fails the build before deployment.
  await mkdir(join(publicDir,mediaPath),{recursive:true});
  for (const name of images) {
    const file = join(folder,name);
    if (!(await lstat(file)).isFile()) throw Error(slug + ': expected a regular image file ' + name);
    await copyFile(file,join(publicDir,mediaPath,name));
  }
  const minutes = Math.max(1, Math.ceil(body.replace(/<[^>]+>/g,' ').trim().split(/\s+/).length/220));
  const row = {title:meta.title,excerpt:meta.excerpt,category:meta.category,author_name:'Oath Wallet',published_at:published,updated_at:updated,locale:'en',language_name:'English',reading_minutes:minutes,url,cover_image_url:cover,markdown_url:url+'.md',github_editorial:true};
  const schema = {'@context':'https://schema.org','@type':'BlogPosting',headline:row.title,description:row.excerpt,
    datePublished:published,dateModified:updated,inLanguage:'en',mainEntityOfPage:url,image:cover,
    author:{'@type':'Organization',name:row.author_name,url:'https://oathwallet.org/about'},
    publisher:{'@type':'Organization',name:'Oath Wallet',url:'https://oathwallet.org/'}};
  if (meta.original_url) schema.sameAs = meta.original_url;
  const h = escape, title = h(row.title), description = h(row.excerpt);
  const original = meta.original_url ? '<a href="'+h(meta.original_url)+'">Original publication</a>' : '';
  const page = `<!doctype html><html lang="en" dir="ltr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title} — Oath Wallet</title><meta name="description" content="${description}"><link rel="canonical" href="${url}"><link rel="alternate" hreflang="en" href="${url}"><link rel="alternate" hreflang="x-default" href="${url}"><link rel="alternate" type="text/markdown" href="${url}.md">
<link rel="icon" href="/favicon.svg"><link rel="apple-touch-icon" href="/apple-touch-icon.png"><link rel="stylesheet" href="/article.css">
<meta property="og:type" content="article"><meta property="og:site_name" content="Oath Wallet"><meta property="og:title" content="${title}"><meta property="og:description" content="${description}"><meta property="og:url" content="${url}"><meta property="og:image" content="${cover}"><meta property="og:image:alt" content="${h(meta.cover_alt)}"><meta property="article:published_time" content="${published}"><meta name="twitter:card" content="summary_large_image"><meta name="twitter:site" content="@OathWallet">
<script type="application/ld+json">${JSON.stringify(schema).replaceAll('<','\\u003c')}</script></head><body>
<a class="skip" href="#content">Skip to article</a><!-- oath-shared-header:start --><!-- oath-shared-header:end -->
<main id="content"><article><div class="article-hero"><div class="eyebrow">${h(row.category)} · <time datetime="${published}">${published.slice(0,10)}</time></div><h1>${title}</h1><p class="dek">${description}</p><div class="byline"><span>Oath Wallet · ${minutes} min read</span>${original}</div></div>
<div class="cover"><img src="${cover}" alt="${h(meta.cover_alt)}" fetchpriority="high"></div>
<div class="reading-layout"><aside>${sections.length ? '<details class="toc"><summary>In this article</summary><ol>'+sections.join('')+'</ol></details>' : ''}</aside><div class="article-body">${body}<div class="article-end"><a href="${origin}/">Explore all articles</a></div></div></div></article></main>
<!-- oath-shared-footer:start --><!-- oath-shared-footer:end --></body></html>\n`;
  const mirror = markdown.replace(/^!\[([^\]]+)\]\(([^)]+)\)$/gm,(_,alt,name)=>'!['+alt+']('+asset(name)+')');
  await writeFile(join(publicDir,'articles',slug+'.md'), '# '+row.title+'\n\n'+row.excerpt+'\n\n'+mirror+'\n'+(original?'\n[Original publication]('+meta.original_url+')\n':''));
  await writeFile(join(publicDir,'articles',slug+'.html'),page);
  return {row, item:{id:url,url,title:row.title,summary:row.excerpt,content_html:body,date_published:published,date_modified:updated,image:cover}};
}

const entries = await readdir(source,{withFileTypes:true});
const articles = [];
for (const entry of entries.filter(e=>e.isDirectory()).sort((a,b)=>a.name.localeCompare(b.name))) {
  try { articles.push(await compile(entry.name)); } catch (error) { throw new Error(entry.name+': '+error.message,{cause:error}); }
}
articles.sort((a,b)=>b.row.published_at.localeCompare(a.row.published_at));
const catalogFile = join(publicDir,'oath-data.json'), catalog = JSON.parse(await read(catalogFile));
const previous = new Set(catalog.articles.filter(a=>a.github_editorial).map(a=>a.url));
const urls = new Set(articles.map(a=>a.row.url));
for (const old of previous) {
  const slug = new URL(old).pathname.slice(1);
  if (urls.has(old) || !slugPattern.test(slug) || old !== origin+'/'+slug || Object.hasOwn(archiveRoutes,'/articles/'+slug)) continue;
  for (const ext of ['html','md']) await rm(join(publicDir,'articles',slug+'.'+ext),{force:true});
  await rm(join(publicDir,'assets/articles/editorials',slug),{recursive:true,force:true});
}
catalog.articles = [...articles.map(a=>a.row), ...catalog.articles.filter(a=>!a.github_editorial)].sort((a,b)=>Date.parse(b.published_at)-Date.parse(a.published_at));
await writeFile(catalogFile,json(catalog));
const feedFile = join(publicDir,'articles/feed.json'), feed = JSON.parse(await read(feedFile));
feed.items = [...articles.map(a=>a.item), ...feed.items.filter(i=>!previous.has(i.url) && !urls.has(i.url))].sort((a,b)=>Date.parse(b.date_published)-Date.parse(a.date_published));
await writeFile(feedFile,json(feed));

const rssItems = feed.items.map(i=>`<item><title>${escape(i.title)}</title><link>${escape(i.url)}</link><guid>${escape(i.url)}</guid><description>${escape(i.summary)}</description><pubDate>${new Date(i.date_published).toUTCString()}</pubDate></item>`);
const rssFile = join(publicDir,'articles/feed.xml');
const rss = (await read(rssFile)).replace(/<item>[\s\S]*?<\/item>/g,'');
await writeFile(rssFile,rss.replace('</channel>',()=>rssItems.join('')+'</channel>'));
const index = catalog.articles.map(a=>`## [${a.title}](${a.url})\n\n${a.excerpt}\n\n${a.language_name} · Published ${a.published_at.slice(0,10)} · Updated ${(a.updated_at??a.published_at).slice(0,10)}`);
await writeFile(join(publicDir,'articles.md'),'# Oath articles\n\nCurrent product guidance and dated editorial archives.\n\n'+index.join('\n\n')+'\n');
console.log('Built '+articles.length+' GitHub-authored editorial articles.');
