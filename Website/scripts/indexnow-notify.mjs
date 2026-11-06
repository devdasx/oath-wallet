import {writeFile,mkdir,rename} from 'node:fs/promises';

export async function notifyIndexNow({config,hashes,changed,removed,batches,stateDir,fetchImpl=fetch}) {
  const stateFile=new URL('indexnow-hashes.json',stateDir);
  // Verify every host before sending any notifications.
  for(const host of new Set(batches.map(b=>b.host))){
    const response=await fetchImpl(`https://${host}/${config.key}.txt`,{redirect:'error',signal:AbortSignal.timeout(15000)});
    if(!response.ok||(await response.text()).trim()!==config.key)throw Error(`Deploy the ownership file on ${host} before submitting IndexNow notifications.`);
  }
  const results=[];
  for(const {host,urlList} of batches){
    const response=await fetchImpl('https://api.indexnow.org/indexnow',{
      method:'POST',headers:{'Content-Type':'application/json; charset=utf-8'},signal:AbortSignal.timeout(30000),
      body:JSON.stringify({host,key:config.key,keyLocation:`https://${host}/${config.key}.txt`,urlList})
    });
    const status=response.status;await response.arrayBuffer();
    results.push({host,status,urls:urlList.length});
    await mkdir(stateDir,{recursive:true});
    await writeFile(new URL('indexnow-last-submission.json',stateDir),JSON.stringify({submittedAt:new Date().toISOString(),changed,removed,batches:results},null,2)+'\n');
    if(![200,202].includes(status))throw Error(`IndexNow returned ${status} for ${host}. Deployment remains live; submission state was not advanced.`);
  }
  // A rejected/partial submission must never mark unsubmitted URLs as notified.
  const next=new URL('indexnow-hashes.next.json',stateDir);
  await writeFile(next,JSON.stringify(hashes,null,2)+'\n');await rename(next,stateFile);
  return results;
}
