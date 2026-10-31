import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,access} from 'node:fs/promises';
import vm from 'node:vm';
import {articleCards,articleLanguages} from '../scripts/article-catalog.mjs';
import {articleRoutes} from '../src/article-routes.js';
import {articleURL} from '../src/article-host.js';
const root=new URL('../public/',import.meta.url);
const data=JSON.parse(await readFile(new URL('oath-data.json',root)));
const cards=articleCards(data.articles);
const html=await readFile(new URL('articles.html',root),'utf8');
function component(){
 const source=html.match(/<script type="text\/x-dc" data-dc-script>([\s\S]*?)<\/script>/)[1];
 return vm.runInNewContext(source+'; new Component()', {DCLogic:class {setState(value){this.state={...this.state,...value};}}, window:{}, setTimeout,clearTimeout,setInterval,clearInterval});
}
test('every archive edition has a real article route and an existing preview image',async()=>{
 const routes=new Set(Object.entries(articleRoutes).filter(([,v])=>typeof v==='string').map(([p])=>articleURL(p)));
 for(const a of cards){
  assert.ok(routes.has(a.href),a.href); assert.ok(a.alt);assert.ok(a.date);assert.match(a.read,/^\d+ min read$/);
  await access(new URL('.'+new URL(a.cover).pathname,root));
 }
 const ui=component();assert.equal(ui.ARTICLES.length,cards.length);
 for(let i=0;i<cards.length;i++){assert.equal(ui.ARTICLES[i].href,cards[i].href);assert.equal(ui.ARTICLES[i].cover,cards[i].cover);}
});
test('English is the default with one card per article, and language changes select the matching edition',()=>{
 const ui=component(), en=ui.renderVals();
 assert.equal(ui.state.locale,'en');assert.equal(en.resultCount,26);
 const initial=[en.featured,...en.list];assert.equal(new Set(initial.map(a=>a.id)).size,26);
 assert.ok(initial.every(a=>a.locale==='en'));
 assert.equal(en.languages.length,16);
 for(const lang of articleLanguages(cards))assert.ok(html.includes(`<option value="${lang.code}">${lang.label}</option>`));
 en.onQ({target:{value:'bitcoin'}});ui.renderVals().cats.find(c=>c.label==='Guides').go();
 ui.renderVals().onLanguage({target:{value:'ar'}});
 const ar=ui.renderVals();assert.equal(ui.state.q,'');assert.equal(ui.state.cat,'All');assert.equal(ar.resultCount,1);
 assert.equal(ar.featured.locale,'ar');assert.equal(ar.featured.dir,'rtl');assert.match(ar.featured.href,/\/ar\/coldcard/);
 ar.cats.find(c=>c.label==='Security').go();assert.equal(ui.renderVals().list.length,1);
 for(const lang of articleLanguages(cards)){ui.renderVals().onLanguage({target:{value:lang.code}});const view=ui.renderVals();assert.ok([view.featured,...view.list].filter(a=>a.href).every(a=>a.locale===lang.code));}
});
test('search and categories retain working card URLs, and empty results can be cleared',()=>{
 const ui=component();ui.renderVals().onQ({target:{value:'dice'}});
 let view=ui.renderVals();assert.equal(view.resultCount,1);assert.match(view.list[0].href,/build-wallet-with-dice/);assert.ok(view.list[0].cover);
 view.onQ({target:{value:'no-such-article-987654'}});view=ui.renderVals();assert.equal(view.isEmpty,true);
 view.onQ({target:{value:''}});assert.equal(ui.renderVals().resultCount,26);
});
test('server-rendered fallback includes all English links and images without translation duplicates',()=>{
 const fallback=html.match(/<!-- oath-server-content:start -->([\s\S]*?)<!-- oath-server-content:end -->/)[1];
 assert.equal((fallback.match(/<article>/g)||[]).length,26);
 for(const a of cards.filter(a=>a.locale==='en')){assert.ok(fallback.includes(`href="${a.href}"`));assert.ok(fallback.includes(`src="${a.cover}"`));}
 assert.doesNotMatch(fallback,/href="https:\/\/articles\.oathwallet\.org\/ar\//);
 assert.match(html,/aria-label="Article language"/);
});
