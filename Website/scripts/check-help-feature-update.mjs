import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import data from '../src/help/content.json' with {type:'json'};
import patch from '../content/help/updates-2026-10-12.json' with {type:'json'};
import {readContent} from '../src/help/index.js';
import {esc} from '../src/help/render.js';
const report=new URL('../Reports/help-update-2026-10-12/',import.meta.url);
const before=JSON.parse(readFileSync(new URL('before.json',report)));
const fields=['category_id','title','summary','route','steps','body','note','screenshot','tags','related','status','app_version','sort_order'];
const live=await readContent();
const rows=new Map(live.articles.map(a=>[a.slug,a]));
const changed=new Set(patch.articles.map(a=>a.slug));
for(const expected of patch.articles){
 const actual=rows.get(expected.slug);assert.ok(actual,expected.slug+' published');
 for(const field of fields)assert.deepEqual(actual[field],expected[field],expected.slug+' '+field);
 assert.equal(Date.parse(actual.published_at),Date.parse(expected.published_at),expected.slug+' publication date');
}
const untouched=before.articles.filter(a=>!changed.has(a.slug));
for(const expected of untouched){
 const actual=rows.get(expected.slug);assert.ok(actual,expected.slug+' retained');
 for(const field of fields)assert.deepEqual(actual[field],expected[field],expected.slug+' unchanged '+field);
 assert.equal(Date.parse(actual.updated_at),Date.parse(expected.updated_at),expected.slug+' untouched timestamp');
}
assert.equal(live.articles.length,102);
const database={checkedAt:new Date().toISOString(),published:rows.size,reviewedChangesMatched:changed.size,untouchedGuidesPreserved:untouched.length};
writeFileSync(new URL('database-checks.json',report),JSON.stringify(database,null,2)+'\n');
console.log(JSON.stringify(database));
if(process.argv.includes('--database-only'))process.exit(0);
// The deployed outage snapshot must agree with live editorial content too.
for(const a of data.articles)for(const field of fields)assert.deepEqual(a[field],rows.get(a.slug)[field],a.slug+' snapshot '+field);
const origin='https://help.oathwallet.org';
const jobs=[],results=[];
const add=(path,kind,extra={})=>jobs.push({url:origin+path,kind,...extra});
add('/','home');
for(const a of data.articles)add('/articles/'+a.slug,'article',{slug:a.slug});
for(const c of data.categories)add('/collections/'+c.id,'collection',{id:c.id});
const queries={
 'home-scanner':'viewfinder','wallet-settings-shortcut':'toolbar shortcut',
 'wallet-balances':'active-wallet badge','full-transaction-history':'full transaction history',
 'search-transactions':'transaction ID','filter-transactions':'filter transaction',
 'asset-transaction-history':'five','spam-history':'phishing','zero-value-transactions':'zero',
 'unverified-tokens':'unverified','confirmation-checkmark':'checkmark',
 'security-settings-access':'authentication','help-center':'help center'
};
for(const [slug,q] of Object.entries(queries))add('/search?q='+encodeURIComponent(q),'search',{slug});
for(const name of new Set(data.articles.map(a=>a.screenshot).filter(Boolean)))add('/help/assets/'+name+'.webp','screenshot');
for(const path of ['/sitemap.xml','/robots.txt','/help/help.css','/help/site-chrome.css','/help/help.js'])add(path,path==='/sitemap.xml'?'sitemap':'resource');
add('/articles/no-such-guide','missing',{status:404});
await Promise.all(Array.from({length:5},async()=>{
 while(jobs.length){
  const job=jobs.shift(),errors=[];let response;
  try{
   response=await fetch(job.url,{headers:{'User-Agent':'Mozilla/5.0 (compatible; OathHelpContentAudit/1.0)'},redirect:'manual',signal:AbortSignal.timeout(20000)});
   if(response.status!==(job.status??200))errors.push('status '+response.status);
   if(job.kind==='screenshot'){
    if(!response.headers.get('content-type')?.startsWith('image/'))errors.push('not an image');
    await response.arrayBuffer();
   }else{
    const html=await response.text();
    if(['home','article','collection','search'].includes(job.kind)&&response.headers.get('x-oath-content')!=='supabase')errors.push('not current database content');
    if(job.kind==='home'&&!html.includes('102 practical guides'))errors.push('guide count');
    if(job.kind==='article'){
     const a=rows.get(job.slug);
     if(!html.includes(`rel="canonical" href="${job.url}"`))errors.push('canonical');
     for(const text of [a.title,a.summary,a.route,...a.steps,...a.body,a.note])if(!html.includes(esc(text)))errors.push('missing reviewed text');
     for(const related of a.related)if(!html.includes('href="/articles/'+related+'"'))errors.push('missing related link '+related);
    }
    if(job.kind==='collection')for(const a of data.articles.filter(a=>a.category_id===job.id))if(!html.includes('href="/articles/'+a.slug+'"'))errors.push('missing guide '+a.slug);
    if(job.kind==='search'&&!html.includes('href="/articles/'+job.slug+'"'))errors.push('search result missing');
    if(job.kind==='sitemap')for(const a of data.articles)if(!html.includes('<loc>'+origin+'/articles/'+a.slug+'</loc>'))errors.push('sitemap guide missing '+a.slug);
   }
  }catch(error){errors.push(error.message);}
  results.push({...job,actualStatus:response?.status,source:response?.headers.get('x-oath-content'),errors});
 }
}));
const failures=results.filter(r=>r.errors.length);
writeFileSync(new URL('live-checks.json',report),JSON.stringify({checkedAt:new Date().toISOString(),results},null,2)+'\n');
console.log(JSON.stringify({checked:results.length,passed:results.length-failures.length,failures},null,2));
if(failures.length)process.exitCode=1;
