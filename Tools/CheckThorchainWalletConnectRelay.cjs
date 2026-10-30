// Isolated JS relay peers route signing through the production Swift codec.
// This checks live WC transport + signature compatibility, not native iOS UI.
process.env.DISABLE_GLOBAL_CORE='true';
const {randomUUID}=require('node:crypto');
const {spawnSync}=require('node:child_process');
const {SignClient}=require('@walletconnect/sign-client');
const assert=require('node:assert/strict');
const fixtures=require('../Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/ThorchainWalletConnect/vectors.json');
for(const name of ['log','info','warn','error','debug']) console[name]=()=>{};
let stage='initialization';
const timer=setTimeout(()=>{process.stdout.write('FAIL: THORChain relay timeout at '+stage+'; native iOS pairing remains unverified.\n');process.exit(1);},55000);
function memory(){const v=new Map();return {getKeys:async()=>[...v.keys()],getEntries:async()=>[...v.entries()],getItem:async k=>v.get(k),setItem:async(k,x)=>{v.set(k,x)},removeItem:async k=>{v.delete(k)}};}
function bridge(request){const p=spawnSync(process.env.OATH_THORCHAIN_WC_BRIDGE,[],{input:JSON.stringify(request),encoding:'utf8',timeout:10000});if(p.status!==0)throw Error('Swift bridge');return JSON.parse(p.stdout);}
(async()=>{
 const projectId=process.env.OATH_WC_PROJECT_ID;
 if(!/^[a-f0-9]{32}$/i.test(projectId||''))throw Error('configuration');
 const meta=name=>({name,description:'Isolated THORChain compatibility test',url:'https://oathwallet.org',icons:['https://oathwallet.org/wallet-logo.png']});
 const peer=await SignClient.init({projectId,metadata:meta('Oath THORChain test'),logger:'silent',storage:memory(),customStoragePrefix:randomUUID()});
 const wallet=await SignClient.init({projectId,metadata:meta('Oath test signer'),logger:'silent',storage:memory(),customStoragePrefix:randomUUID()});
 const methods=['cosmos_getAccounts','cosmos_signAmino','cosmos_signDirect'];
 const proposal=new Promise(r=>wallet.once('session_proposal',r));
 stage='pairing';
 const {uri,approval}=await peer.connect({requiredNamespaces:{cosmos:{chains:['cosmos:thorchain'],methods,events:[]}}});
 await wallet.pair({uri});
 const p=await proposal;
 const a=await wallet.approve({id:p.id,namespaces:{cosmos:{chains:['cosmos:thorchain'],accounts:['cosmos:thorchain:'+fixtures[0].sender],methods,events:[]}}});
 await a.acknowledged();const session=await approval();
 const requests=[{method:'cosmos_getAccounts',params:{},expected:[{address:fixtures[0].sender,algo:'secp256k1',pubkey:fixtures[0].publicKey}]},...fixtures.map(v=>({method:v.method,params:v.params,expected:v.response}))];
 for(const request of requests){
  stage=request.method;
  const incoming=new Promise(r=>wallet.once('session_request',r));
  const pending=peer.request({topic:session.topic,chainId:'cosmos:thorchain',request:{method:request.method,params:request.params}});
  const delivered=await incoming;
  assert.equal(delivered.params.chainId,'cosmos:thorchain');
  const result=bridge(delivered.params.request);
  await wallet.respond({topic:delivered.topic,response:{id:delivered.id,jsonrpc:'2.0',result}});
  assert.deepEqual(await pending,request.expected);
 }
 stage='disconnect';const deleted=new Promise(r=>peer.once('session_delete',r));
 await wallet.disconnect({topic:session.topic,reason:{code:6000,message:'Test complete'}});await deleted;
 assert.equal(wallet.session.getAll().length,0);assert.equal(peer.session.getAll().length,0);
 clearTimeout(timer);process.stdout.write('PASS: live THORChain namespace pairing, account discovery, eight Amino/Direct requests signed by production Swift code and independently matched to CosmJS, and peer disconnect. Isolated JS peers; native iOS pairing not exercised.\n');process.exit(0);
})().catch(()=>{clearTimeout(timer);process.stdout.write('FAIL: THORChain relay check at '+stage+'; native iOS pairing remains unverified.\n');process.exit(1);});
