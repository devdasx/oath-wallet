// Notify participating engines after the deployed pages have passed live checks.
import {readFile} from 'node:fs/promises';
import {notifyIndexNow} from './indexnow-notify.mjs';
import config from '../indexnow.json' with {type:'json'};
import {indexNowHashes,submissionBatches} from './indexnow-pages.mjs';
const stateDir=new URL('../.search-state/',import.meta.url);
const stateFile=new URL('indexnow-hashes.json',stateDir);
let previous={};
try{previous=JSON.parse(await readFile(stateFile,'utf8'));}catch(error){if(error.code!=='ENOENT')throw error;}
const hashes=await indexNowHashes();
const {changed,removed,batches}=submissionBatches(hashes,previous,config.hosts);
if(process.argv.includes('--dry-run')){
  console.log(JSON.stringify({changed,removed,batches:batches.map(b=>({host:b.host,urls:b.urlList.length}))},null,2));
}else if(!batches.length){
  console.log('IndexNow: no changed pages; no notification sent.');
}else{
  const results=await notifyIndexNow({config,hashes,changed,removed,batches,stateDir});
  console.log(`IndexNow accepted ${changed+removed} changed/deleted URLs across ${new Set(batches.map(b=>b.host)).size} hosts (HTTP ${results.map(r=>r.status).join(', ')}). This is a notification acknowledgement, not confirmation of indexing.`);
}
