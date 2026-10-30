// Notify participating engines only after deployment and only for changed pages.
// IndexNow ownership tokens are intentionally served as public text files.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {articleRoutes} from '../src/article-routes.js';

const root=new URL('../',import.meta.url);
const config=JSON.parse(await readFile(new URL('indexnow.json',root),'utf8'));
const stateDir=new URL('.search-state/',root);
const stateFile=new URL('indexnow-hashes.json',stateDir);
let previous={};
try{previous=JSON.parse(await readFile(stateFile,'utf8'));}catch(error){if(error.code!=='ENOENT')throw error;}
const sitemap=await readFile(new URL('public/sitemap.xml',root),'utf8');
const urls=[...sitemap.matchAll(/<loc>(.*?)<\/loc>/g)].map(m=>m[1]);
const hashes={};
for(const url of urls){
  const parsed=new URL(url);
  if(parsed.origin!=='https://oathwallet.org')throw new Error('Unexpected sitemap origin');
  const path=parsed.pathname;
  const file=path==='/'?'/index.html':articleRoutes[path]||path+'.html';
  if(typeof file!=='string')throw new Error('Sitemap contains a redirect');
  hashes[url]=createHash('sha256').update(await readFile(new URL('public'+file,root))).digest('hex');
}
const changed=urls.filter(url=>previous[url]!==hashes[url]);
const removed=Object.keys(previous).filter(url=>!(url in hashes));
const urlList=[...changed,...removed];
if(process.argv.includes('--dry-run')){
  console.log(JSON.stringify({changed:changed.length,removed:removed.length,urls:urlList},null,2));
}else if(!urlList.length){
  console.log('IndexNow: no changed pages; no notification sent.');
}else{
  const keyLocation=`https://${config.host}/${config.key}.txt`;
  const verification=await fetch(keyLocation,{signal:AbortSignal.timeout(15000)});
  if(!verification.ok||(await verification.text()).trim()!==config.key)throw new Error('Deploy the ownership file before submitting IndexNow notifications.');
  const response=await fetch('https://api.indexnow.org/indexnow',{
    method:'POST',headers:{'Content-Type':'application/json; charset=utf-8'},signal:AbortSignal.timeout(30000),
    body:JSON.stringify({host:config.host,key:config.key,keyLocation,urlList})
  });
  const log={submittedAt:new Date().toISOString(),status:response.status,changed:changed.length,removed:removed.length,urlList,response:(await response.text()).slice(0,1000)};
  await mkdir(stateDir,{recursive:true});
  await writeFile(new URL('indexnow-last-submission.json',stateDir),JSON.stringify(log,null,2)+'\n');
  if(![200,202].includes(response.status))throw new Error(`IndexNow returned ${response.status}. Deployment remains live; inspect the submission log before retrying.`);
  await writeFile(stateFile,JSON.stringify(hashes,null,2)+'\n');
  console.log(`IndexNow accepted ${urlList.length} changed/deleted URLs (HTTP ${response.status}). This is a notification acknowledgement, not confirmation of indexing.`);
}
