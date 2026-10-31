import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {runInNewContext} from 'node:vm';
import data from '../src/help/content.json' with {type:'json'};
import {home,collection,article,searchResults,notFound} from '../src/help/render.js';

test('every redesigned help page retains valid internal guide and section destinations',()=>{
 const routes=new Set(['/', '/search', ...data.categories.map(c=>'/collections/'+c.id), ...data.articles.map(a=>'/articles/'+a.slug)]);
 const pages=[home(data),...data.categories.map(c=>collection(data,c)),...data.articles.map(a=>article(data,a)),searchResults(data,'wallet'),searchResults(data,'zzzzmissing'),notFound()];
 for(const html of pages){
  const ids=[...html.matchAll(/\bid="([^"]+)"/g)].map(m=>m[1]);
  assert.equal(ids.length,new Set(ids).size,'Duplicate page anchor');
  assert.equal((html.match(/<h1\b/g)||[]).length,1);
  assert.equal((html.match(/<main\b/g)||[]).length,1);
  assert.equal((html.match(/id="help-search"/g)||[]).length,1);
  for(const [,href] of html.matchAll(/\bhref="([^"]+)"/g)){
   if(href.startsWith('#'))assert.ok(ids.includes(href.slice(1)),`Missing section ${href}`);
   else if(/^\/(?:articles|collections)\//.test(href))assert.ok(routes.has(href),`Missing guide ${href}`);
  }
 }
});

test('repeated instruction text still produces distinct step anchors',()=>{
 const html=article(data,{...data.articles[0],steps:['Review the details.','Review the details.']});
 assert.match(html,/id="step-1"/);assert.match(html,/id="step-2"/);
});

test('search shortcut respects typing, browser shortcuts and the open navigation menu',async()=>{
 const source=await readFile(new URL('../public/help/help.js',import.meta.url),'utf8');
 let listener,focused=0,prevented=0,editing=false,menu=false;
 const document={activeElement:{matches:()=>editing},addEventListener:(_,handler)=>listener=handler,querySelector:selector=>selector==='[data-print]'?null:selector==='#help-search'?{focus:()=>focused++}:{hasAttribute:()=>menu}};
 runInNewContext(source,{document});
 const press=(extra={})=>listener({key:'/',preventDefault:()=>prevented++,...extra});
 press();assert.equal(focused,1);assert.equal(prevented,1);
 editing=true;press();editing=false;
 for(const key of ['ctrlKey','metaKey','altKey'])press({[key]:true});
 menu=true;press();menu=false;press({key:'x'});
 assert.equal(focused,1);assert.equal(prevented,1);
});
