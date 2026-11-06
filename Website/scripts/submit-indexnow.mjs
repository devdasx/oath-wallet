// Notify participating engines only after deployment and only for changed pages.
// IndexNow ownership tokens are intentionally served as public text files.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {sitemapURLs} from './sitemaps.mjs';
import manifest from '../src/tokens-manifest.json' with {type:'json'};
import {articleRoutes} from '../src/article-routes.js';

const root=new URL('../',import.meta.url);
const config=JSON.parse(await readFile(new URL('indexnow.json',root),'utf8'));
const stateDir=new URL('.search-state/',root);
const stateFile=new URL('indexnow-hashes.json',stateDir);
let previous={};
try{previous=JSON.parse(await readFile(stateFile,'utf8'));}catch(error){if(error.code!=='ENOENT')throw error;}
const urls=await sitemapURLs();
const hashes={};
for(const url of urls){
  const parsed=new URL(url);
  if(parsed.origin!=='https://oathwallet.org')throw new Error('Unexpected sitemap origin');
  const path=parsed.pathname;
  if(path.startsWith('/tokens')||path.endsWith('/tokens')){hashes[url]=manifest.version;continue;}
  const file=path==='/'?'/index.html':articleRoutes[path]||path+'.html';
  if(typeof file!=='string')throw new Error('Sitemap contains a redirect');
  hashes[url]=createHash('sha256').update(await readFile(new URL('public'+file,root))).digest('hex');
}
const changed=urls.filter(url=>previous[url]!==hashes[url]);
const removed=Object.keys(previous).filter(url=>!(url in hashes));
const urlList=[...changed,...removed];
if(process.argv.includes('--dry-run')){
  console.log(JSON.stringify({changed:changed.length,removed:removed.length,batch_count:Math.ceil(urlList.length/10000)},null,2));
}else if(!urlList.length){
  console.log('IndexNow: no changed pages; no notification sent.');
}else{
  const keyLocation=`https://${config.host}/${config.key}.txt`;
  const verification=await fetch(keyLocation,{signal:AbortSignal.timeout(15000)});
  if(!verification.ok||(await verification.text()).trim()!==config.key)throw new Error('Deploy the ownership file before submitting IndexNow notifications.');
  const results=[];
  for(let offset=0;offset<urlList.length;offset+=10000){
  const response=await fetch('https://api.indexnow.org/indexnow',{
    method:'POST',headers:{'Content-Type':'application/json; charset=utf-8'},signal:AbortSignal.timeout(30000),
    body:JSON.stringify({host:config.host,key:config.key,keyLocation,urlList:urlList.slice(offset,offset+10000)})
  });
  const status=response.status;await response.arrayBuffer();
  results.push({status,urls:Math.min(10000,urlList.length-offset)});
  await mkdir(stateDir,{recursive:true});
  await writeFile(new URL('indexnow-last-submission.json',stateDir),JSON.stringify({submittedAt:new Date().toISOString(),changed:changed.length,removed:removed.length,batches:results},null,2)+'\n');
  if(![200,202].includes(status))throw new Error(`IndexNow returned ${status}. Deployment remains live; inspect the submission log before retrying.`);
  }
  await writeFile(stateFile,JSON.stringify(hashes,null,2)+'\n');
  console.log(`IndexNow accepted ${urlList.length} changed/deleted URLs (HTTP ${results.map(r=>r.status).join(", ")}). This is a notification acknowledgement, not confirmation of indexing.`);
}
