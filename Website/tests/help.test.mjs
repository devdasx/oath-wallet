import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import data from '../src/help/content.json' with {type:'json'};
import {validateContent, handleHelp} from '../src/help/index.js';
import {article,home,collection,searchResults} from '../src/help/render.js';
import {articleURL,handleArticleHost,migrateArticleLinks,migrateSupportLinks} from '../src/article-host.js';
import {articleRoutes} from '../src/article-routes.js';
const env={ASSETS:{async fetch(req){try{const path=decodeURIComponent(new URL(req.url).pathname);const type=path.endsWith('.json')?'application/json':path.endsWith('.xml')?'application/xml':path.endsWith('.md')?'text/markdown':'text/html';return new Response(await readFile(new URL('../public'+path,import.meta.url)),{headers:{'Content-Type':type}});}catch{return new Response('Not found',{status:404});}}}};
test('help coverage has unique guides, real source references and complete render data',async()=>{
 assert.equal(data.articles.length,131);assert.equal(data.categories.length,9);validateContent(data.categories,data.articles);
 const coverage=JSON.parse(await readFile(new URL('./fixtures/help-source-coverage.json',import.meta.url)));
 assert.equal(coverage.length,130);assert.ok(coverage.every(x=>x.sources.length>0&&x.source_paths_missing.length===0));
 for(const name of new Set(data.articles.map(a=>a.screenshot).filter(Boolean))) assert.ok((await readFile(new URL('../public/help/assets/'+name+'.webp',import.meta.url))).length>1000,name);
 for(const a of data.articles){assert.ok(a.steps.length>=3,a.slug);assert.ok(a.note,a.slug);assert.ok(a.summary.length>30,a.slug);for(const id of a.related)assert.ok(data.articles.some(x=>x.slug===id),id);assert.match(article(data,a),/<h1>/);}
 for(const c of data.categories)assert.ok(collection(data,c).includes(c.title.replaceAll('&','&amp;')));
 assert.match(home(data),/131 practical guides/);
});
test('search finds feature and network names, escapes untrusted queries and handles empty results',()=>{
 for(const q of ['bitcoin','passphrase','backup','solana','face id']) assert.doesNotMatch(searchResults(data,q),/No matching articles yet/);
 assert.match(searchResults(data,'zzzzzzzz'),/No matching articles yet/);
 const html=searchResults(data,'<script>alert(1)</script>');assert.ok(!html.includes('<script>alert(1)</script>'));assert.ok(html.includes('&lt;script&gt;'));
});
test('help rendering uses Git content without any remote database reads',async()=>{
 let requests=0;const original=globalThis.fetch;
 globalThis.fetch=async()=>{requests++;throw Error('No remote help content is allowed');};
 try {
  const response=await handleHelp(new Request('https://help.oathwallet.org/articles/'+data.articles[0].slug),env);
  assert.equal(response.status,200);assert.equal(response.headers.get('X-Oath-Content'),'git');
  assert.ok((await response.text()).includes(data.articles[0].title));assert.equal(requests,0);
  assert.throws(()=>validateContent(data.categories,[{...data.articles[0],screenshot:'../../secret'}]));
 } finally {globalThis.fetch=original;}
});
test('help routes render offline and preserve method boundaries',async()=>{
 const original=globalThis.fetch;globalThis.fetch=async()=>{throw Error('offline');};
 try{
 const res=await handleHelp(new Request('https://help.oathwallet.org/'),env);assert.equal(res.status,200);assert.equal(res.headers.get('X-Oath-Content'),'git');
 assert.match(res.headers.get('Content-Security-Policy'),/frame-ancestors 'none'/);
 assert.equal((await handleHelp(new Request('https://help.oathwallet.org/articles/nope'),env)).status,404);
 assert.equal((await handleHelp(new Request('https://help.oathwallet.org/',{method:'POST'}),env)).status,405);
 const head=await handleHelp(new Request('https://help.oathwallet.org/',{method:'HEAD'}),env);assert.equal(await head.text(),'');
 assert.equal(await handleHelp(new Request('https://oathwallet.org/'),env),null);
 }finally{globalThis.fetch=original;}
});
test('every archive edition migrates in one redirect and renders correct canonical',async()=>{
 for(const [path,entry] of Object.entries(articleRoutes)){
  const redirect=await handleArticleHost(new Request('https://oathwallet.org'+path+'?ref=old'),env);assert.equal(redirect.status,308);assert.equal(redirect.headers.get('location'),articleURL(path)+'?ref=old');
  if(typeof entry!=='string')continue;
  const response=await handleArticleHost(new Request(articleURL(path)),env);assert.equal(response.status,200,path);const html=await response.text();assert.ok(html.includes(`rel="canonical" href="${articleURL(path)}"`),path);assert.match(html,/help.oathwallet.org/);
  const md=await handleArticleHost(new Request(articleURL(path)+'.md'),env);assert.equal(md.status,200,path+' markdown');assert.equal(md.headers.get('Link'),`<${articleURL(path)}>; rel="canonical"`);
 }
 assert.equal(articleURL('/articles.md'),'https://articles.oathwallet.org/index.md');
 for(const p of ['/','/feed.json','/feed.xml','/index.md','/sitemap.xml','/Oath%20Header.dc.html','/Oath%20Footer.dc.html'])assert.equal((await handleArticleHost(new Request('https://articles.oathwallet.org'+p),env)).status,200,p);
 assert.equal((await handleArticleHost(new Request('https://articles.oathwallet.org/missing'),env)).status,404);
 assert.equal(migrateArticleLinks('<a href="/articles">Articles</a>'),'<a href="https://articles.oathwallet.org/">Articles</a>');
 for(const href of ['/support','https://oathwallet.org/support','https://www.oathwallet.org/support']) assert.equal(migrateSupportLinks(`<a href="${href}">Support</a>`),'<a href="https://help.oathwallet.org/">Help Center</a>');
});

test('new help guides explain current navigation, scoped history and safety limits',()=>{
 const get=slug=>{const a=data.articles.find(a=>a.slug===slug);assert.ok(a,slug);return a;};
 const text=slug=>{const a=get(slug);return [a.route,...a.steps,...a.body,a.note].join(' ');};
 const queries={
  'home-scanner':'viewfinder', 'wallet-settings-shortcut':'toolbar shortcut',
  'wallet-balances':'active-wallet badge', 'full-transaction-history':'full transaction history',
  'search-transactions':'transaction ID', 'filter-transactions':'filter transaction',
  'asset-transaction-history':'five', 'spam-history':'phishing',
  'zero-value-transactions':'zero', 'unverified-tokens':'unverified',
  'confirmation-checkmark':'checkmark', 'security-settings-access':'authentication',
  'help-center':'help center'
 };
 for(const [slug,query] of Object.entries(queries)) {
  const guide=get(slug);assert.ok(guide.steps.length>=4&&guide.body.length>=3,slug);
  assert.ok(searchResults(data,query).includes('href="/articles/'+slug+'"'),slug+' search');
 }
 assert.match(text('home-screen'),/select Wallet and then the separate/i);
 assert.match(text('asset-transaction-history'),/five or fewer.*no View All/);
 assert.match(text('asset-transaction-history'),/limited to the selected token or coin, its account and its network/);
 assert.match(text('filter-transactions'),/native units, not local currency/);
 assert.match(text('spam-history'),/No filter can recognize every scam/);
 assert.match(text('spam-history'),/Previously saved activity/);
 assert.match(text('confirmation-checkmark'),/VoiceOver/);
 assert.match(text('prices-chart'),/chart control/);
 assert.doesNotMatch(text('restore-icloud'),/wallet switcher/);
});
