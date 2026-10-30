import {writeFileSync} from 'node:fs';
import data from '../src/help/content.json' with {type:'json'};
import {articleRoutes} from '../src/article-routes.js';
import {articleURL} from '../src/article-host.js';
const jobs=[],results=[];
const add=(url,kind,expected=200,location)=>jobs.push({url,kind,expected,location});
add('https://help.oathwallet.org/','help-home');
for(const a of data.articles)add('https://help.oathwallet.org/articles/'+a.slug,'help-article');
for(const c of data.categories)add('https://help.oathwallet.org/collections/'+c.id,'collection');
for(const s of new Set(data.articles.map(a=>a.screenshot).filter(Boolean)))add('https://help.oathwallet.org/help/assets/'+s+'.webp','screenshot');
for(const [path,target] of Object.entries(articleRoutes)){
 add('https://oathwallet.org'+path,'archive-redirect',308,articleURL(path));
 if(typeof target==='string')add(articleURL(path),'archive-article');
}
for(const p of ['/','/feed.xml','/feed.json','/index.md','/sitemap.xml','/robots.txt','/Oath%20Header.dc.html','/Oath%20Footer.dc.html'])add('https://articles.oathwallet.org'+p,'archive-index');
for(const p of ['/help/help.css','/help/help.js','/favicon.svg','/search?q=solana','/sitemap.xml','/robots.txt'])add('https://help.oathwallet.org'+p,'help-resource');
add('https://help.oathwallet.org/articles/no-such-guide','404',404);
for(const p of ['/','/privacy','/terms','/sitemap.xml','/robots.txt'])add('https://oathwallet.org'+p,'main-site');
add('https://news.oathwallet.org/','newsletter');
await Promise.all(Array.from({length:6},async()=>{
 while(jobs.length){const job=jobs.shift();try{
 const res=await fetch(job.url,{redirect:'manual',signal:AbortSignal.timeout(20000)});const text=job.kind==='screenshot'?'':await res.text();
 const errors=[];if(res.status!==job.expected)errors.push('status '+res.status);if(job.location&&res.headers.get('location')!==job.location)errors.push('redirect mismatch');
 if(['help-article','archive-article'].includes(job.kind)&&!text.includes(`rel="canonical" href="${job.url}"`))errors.push('canonical mismatch');
 if(job.kind==='help-home'&&res.headers.get('x-oath-content')!=='supabase')errors.push('not database content');
 if(job.kind==='screenshot'&&!res.headers.get('content-type')?.startsWith('image/'))errors.push('not image');
 results.push({...job,status:res.status,source:res.headers.get('x-oath-content'),errors});
 }catch(e){results.push({...job,errors:[e.message]});}}
}));
writeFileSync(new URL('../Reports/help-center-2026-10-12/live-checks.json',import.meta.url),JSON.stringify({checkedAt:new Date().toISOString(),results},null,2));
const failures=results.filter(r=>r.errors.length);console.log(JSON.stringify({checked:results.length,passed:results.length-failures.length,failures},null,2));if(failures.length)process.exitCode=1;
