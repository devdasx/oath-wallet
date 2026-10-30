import {writeFile,readFile} from 'node:fs/promises';
import {readContent} from '../src/help/index.js';
import {esc} from '../src/help/render.js';
import expected from '../content/help/update-2026-10-16.json' with {type:'json'};
import walkthroughs from '../src/help/walkthroughs.json' with {type:'json'};
const dir='Reports/help-update-2026-10-16';
const data=await readContent();const failures=[];const checks=[];
const map=new Map(data.articles.map(a=>[a.slug,a]));
for(const wanted of expected.articles){const got=map.get(wanted.slug);if(!got){failures.push('Missing DB article '+wanted.slug);continue;}for(const k of ['category_id','title','summary','route','steps','body','note','screenshot','tags','related','app_version','status'])if(JSON.stringify(got[k])!==JSON.stringify(wanted[k]))failures.push('DB mismatch '+wanted.slug+' '+k);}
for(const wanted of expected.categories)if(JSON.stringify(data.categories.find(c=>c.id===wanted.id))!==JSON.stringify(wanted))failures.push('Category mismatch '+wanted.id);
await writeFile(dir+'/after.json',JSON.stringify(data,null,2));
const jobs=[
 ...data.articles.map(a=>({url:'https://help.oathwallet.org/articles/'+a.slug,kind:'article',article:a})),
 ...data.categories.map(c=>({url:'https://help.oathwallet.org/collections/'+c.id,kind:'collection',title:c.title})),
 ...[...new Set(Object.values(walkthroughs).flat().map(x=>x.image))].map(n=>({url:'https://help.oathwallet.org/help/assets/'+n+'.webp',kind:'image'})),
 ...['/','/sitemap.xml','/search?q=Solana%20Devnet','/search?q=revoke','/search?q=send'].map(path=>({url:'https://help.oathwallet.org'+path,kind:'index'})),
 ...['https://oathwallet.org/','https://articles.oathwallet.org/','https://articles.oathwallet.org/sitemap.xml'].map(url=>({url,kind:'existing-host'}))
];let next=0;
async function worker(){while(next<jobs.length){const job=jobs[next++];try{const res=await fetch(job.url,{signal:AbortSignal.timeout(20000)});if(!res.ok)throw Error('HTTP '+res.status);
 if(job.kind==='image'){const bytes=new Uint8Array(await res.arrayBuffer());if(String.fromCharCode(...bytes.slice(0,4))!=='RIFF'||String.fromCharCode(...bytes.slice(8,12))!=='WEBP')throw Error('Not WebP');checks.push({url:job.url,status:res.status,bytes:bytes.length});continue;}
 const html=await res.text();
 if(job.article){const a=job.article;for(const text of [a.title,a.summary,a.route,...a.steps,...a.body,a.note])if(!html.includes(esc(text)))throw Error('Published text missing');for(const image of walkthroughs[a.slug])if(!html.includes('/help/assets/'+image.image+'.webp')||!html.includes(esc(image.caption)))throw Error('Screenshot/caption missing');if(!res.headers.get('content-security-policy')?.includes("frame-ancestors 'none'"))throw Error('CSP absent');}
 if(job.title&&!html.includes(esc(job.title)))throw Error('Collection title missing');
 if(job.url.endsWith('/sitemap.xml')&&job.url.includes('help.'))for(const a of data.articles)if(!html.includes('/articles/'+a.slug))throw Error('Sitemap article missing');
 if(job.url.includes('Solana%20Devnet')&&!html.includes('/articles/walletconnect-solana'))throw Error('Solana search missing');
 checks.push({url:job.url,status:res.status,bytes:html.length,contentSource:res.headers.get('x-oath-content')});
 }catch(e){failures.push(job.url+' '+e.message);}}}
await Promise.all(Array.from({length:6},worker));
await writeFile(dir+'/live-checks.json',JSON.stringify({checkedAt:new Date().toISOString(),articles:data.articles.length,collections:data.categories.length,checks,failures,passed:!failures.length},null,2));
console.log(`${checks.length}/${jobs.length} live pages/images checked; ${failures.length} failures.`);for(const f of failures)console.log(f);if(failures.length)process.exitCode=1;
