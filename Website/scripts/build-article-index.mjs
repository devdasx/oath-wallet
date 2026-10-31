import {readFile,writeFile} from 'node:fs/promises';
import {articleCards,articleLanguages} from './article-catalog.mjs';
const root=new URL('../public/',import.meta.url);
const data=JSON.parse(await readFile(new URL('oath-data.json',root),'utf8'));
const cards=articleCards(data.articles);
const json=value=>JSON.stringify(value).replaceAll('<','\\u003c');
const file=new URL('articles.html',root);
let html=await readFile(file,'utf8');
html=html.replace(/  ARTICLES = \[[\s\S]*?\];/,`  ARTICLES = ${json(cards)};`)
 .replace(/  LANGUAGES = \[[\s\S]*?\];/,`  LANGUAGES = ${json(articleLanguages(cards))};`);
const escape=value=>value.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');
html=html.replace(/<!-- article-language-options:start -->[\s\S]*?<!-- article-language-options:end -->/, '<!-- article-language-options:start -->'+articleLanguages(cards).map(l=>`<option value="${escape(l.code)}">${escape(l.label)}</option>`).join('')+'<!-- article-language-options:end -->');
await writeFile(file,html);
console.log(`Built article cards: ${cards.filter(a=>a.locale==='en').length} articles, ${articleLanguages(cards).length} languages.`);
