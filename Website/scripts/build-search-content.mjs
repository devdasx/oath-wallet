import {articleCards,articleFallback} from './article-catalog.mjs';
import {buildSiteChrome} from './build-help-chrome.mjs';
import {readFile, writeFile} from 'node:fs/promises';

const publicDir = new URL('../public/', import.meta.url);
const pages = ['index','features','articles','support','press','security','terms','privacy'];
const runtime = await readFile(new URL('support.js',publicDir),'utf8');
// Start the two required local dependencies with the document instead of
// discovering them only after support.js executes. Match its CORS/SRI settings.
const runtimePreloads = ['REACT','REACT_DOM'].map(name => {
  const url=runtime.match(new RegExp(`var ${name}_URL = "([^"]+)"`))?.[1];
  const integrity=runtime.match(new RegExp(`var ${name}_SRI = "([^"]+)"`))?.[1];
  if(!url?.startsWith('/assets/vendor/') || !integrity?.startsWith('sha384-'))throw new Error('Missing local runtime dependency: '+name);
  return `<link rel="preload" as="script" href="${url}" crossorigin="anonymous" integrity="${integrity}">`;
}).join('');
const escape = value => value.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
function inline(value) {
  // Only authored HTTP(S), mailto and same-site destinations become links.
  return value.split(/(\[[^\]]+\]\([^)]+\))/g).map(part => {
    const match = part.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
    if (match && /^(https?:\/\/|mailto:|\/(?!\/)|#)/.test(match[2])) return `<a href="${escape(match[2])}">${escape(match[1])}</a>`;
    return escape(part).replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>').replace(/`([^`]+)`/g,'<code>$1</code>').replace(/(?<!\w)_([^_]+)_(?!\w)/g,'<em>$1</em>');
  }).join('');
}
function renderMarkdown(markdown) {
  return markdown.replace(/<!--[\s\S]*?-->/g,'').trim().split(/\n\s*\n/).map(block => {
    const heading = block.match(/^(#{1,4}) ([^\n]+)$/);
    if (heading) return `<h${heading[1].length}>${inline(heading[2])}</h${heading[1].length}>`;
    if (/^[-*] /.test(block)) return '<ul>'+block.split('\n').map(row=>'<li>'+inline(row.replace(/^[-*] /,''))+'</li>').join('')+'</ul>';
    if (/^\d+\. /.test(block)) return '<ol>'+block.split('\n').map(row=>'<li>'+inline(row.replace(/^\d+\. /,''))+'</li>').join('')+'</ol>';
    if (block.startsWith('|')) {
      const rows=block.split('\n').filter(row=>!/^\|[\s:|-]+\|$/.test(row));
      return '<div class="oath-readable-table"><table>'+rows.map((row,i)=>'<tr>'+row.replace(/^\||\|$/g,'').split('|').map(cell=>`<${i?'td':'th'}>${inline(cell.trim())}</${i?'td':'th'}>`).join('')+'</tr>').join('')+'</table></div>';
    }
    return '<p>'+inline(block.replace(/\n/g,' '))+'</p>';
  }).join('\n');
}
const articles=articleCards(JSON.parse(await readFile(new URL('oath-data.json',publicDir),'utf8')).articles);
const chrome=await buildSiteChrome();
const nav=chrome.header;
const style=`<style id="oath-readable-style">#oath-server-content{box-sizing:border-box;min-height:100vh;margin:0;background:#0A0A0B;color:#F2F0EA;font:17px/1.65 system-ui,sans-serif;padding:0}#oath-server-content main a{color:inherit;text-decoration:underline;text-underline-offset:4px}#oath-server-content > nav{display:flex;gap:22px;flex-wrap:wrap;padding:8px 0 40px;border-bottom:1px solid #333}#oath-server-content > nav a{text-decoration:none}#oath-server-content main{max-width:984px;margin:0 auto;padding:128px 32px 64px}#oath-server-content main h1{font:400 clamp(42px,7vw,86px)/1.05 Georgia,serif;letter-spacing:-.03em}#oath-server-content main h2{font:400 clamp(28px,4vw,40px)/1.2 Georgia,serif;margin-top:48px}#oath-server-content main h3{font-size:21px;margin-top:32px}#oath-server-content main p,#oath-server-content main li{max-width:78ch}#oath-server-content > footer{max-width:920px;margin:auto;border-top:1px solid #333;padding-top:24px}#oath-server-content .oath-readable-table{overflow-x:auto}#oath-server-content th,#oath-server-content td{border-bottom:1px solid #333;padding:12px;text-align:left}#oath-server-content main code{overflow-wrap:anywhere}</style>`;
const articleStyle=`<style>#oath-server-content .article-readable-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,280px),1fr));gap:32px}#oath-server-content .article-readable-grid img{width:100%;height:auto;aspect-ratio:1200/630;object-fit:contain;border-radius:24px}#oath-server-content .article-readable-grid h2{font-size:28px;margin:20px 0}#oath-server-content .article-readable-grid a{text-decoration:none}</style>`;
for (const page of pages) {
  const file = new URL(page+'.html',publicDir);
  let html = await readFile(file,'utf8');
  const markdown = await readFile(new URL(page+'.md',publicDir),'utf8');
  const content=`<!-- oath-server-content:start -->${style}${page==='articles'?articleStyle:''}<div id="oath-server-content">${nav}<main>${page==='articles'?articleFallback(articles):renderMarkdown(markdown)}</main>${chrome.footer}</div><!-- oath-server-content:end -->`;
  html=html.replace(/<!-- oath-server-content:start -->[\s\S]*?<!-- oath-server-content:end -->\s*/,'').replace(/<noscript>[\s\S]*?<\/noscript>\s*/g,'');
  // Keep one literal H1 in the response, including parsers that inspect inert templates.
  // The runtime restores this placeholder to H1 when it replaces the readable content.
  html=html.replace(/<template data-oath-template>([\s\S]*?)<\/template>/g, (_, template) =>
    '<template data-oath-template>'+template.replace(/<h1\b([^>]*)>([\s\S]*?)<\/h1>/g,'<div data-oath-page-title$1>$2</div>')+'</template>');
  // The readable HTML must paint before the optional React enhancement loads.
  // support.js already handles both loading and fully parsed documents.
  html=html.replace(/<script src="\.\/support\.js"(?: defer)?><\/script>/g,'<script src="./support.js" defer></script>');
  html=html.replace(/<!-- oath-runtime-preloads:start -->[\s\S]*?<!-- oath-runtime-preloads:end -->/g,'')
    .replace('</head>',`<!-- oath-runtime-preloads:start -->${runtimePreloads}<!-- oath-runtime-preloads:end --></head>`);
  html=html.replace('<body>','<body>\n'+content+'\n');
  await writeFile(file,html);
}
console.log(`Built server-delivered content and navigation for ${pages.length} core pages.`);
const fullTextPages=['index','features','about','networks','articles','support','press','security','terms','privacy'];
const fullText=await Promise.all(fullTextPages.map(page=>readFile(new URL(page+'.md',publicDir),'utf8')));
await writeFile(new URL('llms-full.txt',publicDir),fullText.map(text=>text.trim()).join('\n\n---\n\n')+'\n');

// The interactive privacy page and readable policy must describe the same data
// practices. Keep the authored Markdown as their single content source.
const privacyMarkdown=await readFile(new URL('privacy.md',publicDir),'utf8');
const privacyBlocks=privacyMarkdown.trim().split(/\n\s*\n/);
const privacy={title:'Privacy',titleEm:'Policy',updated:'',summary:[],sections:[]};
const plain=value=>value.replace(/\*\*([^*]+)\*\*/g,'$1').replace(/\[([^\]]+)\]\(([^)]+)\)/g,'$1 ($2)');
let currentSection;
for (const block of privacyBlocks) {
  if (block.startsWith('Last updated: ')) privacy.updated=block.slice('Last updated: '.length);
  else if (block.startsWith('**In short:**')) privacy.summary=[plain(block).replace(/^In short:\s*/, '')];
  else if (block.startsWith('## ')) {
    currentSection=[block.slice(3).replace(/^\d+\.\s*/,''),[],[]];
    privacy.sections.push(currentSection);
  } else if (currentSection && /^- /.test(block)) currentSection[2].push(...block.split('\n').map(row=>plain(row.replace(/^- /,''))));
  else if (currentSection && !block.startsWith('Questions:')) currentSection[1].push(plain(block));
}
if (!privacy.updated || privacy.sections.length<18) throw new Error('Privacy source is incomplete');
const legalFile=new URL('Oath Legal Doc.dc.html',publicDir);
const legal=await readFile(legalFile,'utf8');
const privacyDefinition=/    const PRIVACY = \{[\s\S]*?\n    \};/;
if (!privacyDefinition.test(legal)) throw new Error('Privacy component definition not found');
await writeFile(legalFile,legal.replace(privacyDefinition,'    const PRIVACY = '+JSON.stringify(privacy,null,2).replaceAll('\n','\n    ')+';'));
