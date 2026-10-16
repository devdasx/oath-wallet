// @stellar/stellar-sdk 17.2.1. Only isolated public Testnet faucet accounts.
// Keys and signed fixture transactions stay in the private /tmp fixture.
const fs=require('fs'),s=require('@stellar/stellar-sdk');
const path=process.argv[2],wasmPath=process.argv[3];
if(!path?.startsWith('/tmp/'))throw new Error('Private /tmp fixture path required');
const H='https://horizon-testnet.stellar.org',R='https://soroban-testnet.stellar.org',N=s.Networks.TESTNET;
const f=fs.existsSync(path)?JSON.parse(fs.readFileSync(path)): {done:[]};let stage='network';
const save=()=>{fs.writeFileSync(path,JSON.stringify(f),{mode:0o600});fs.chmodSync(path,0o600);};
const key=role=>s.Keypair.fromRawEd25519Seed(Buffer.from(f[role].seed,'base64'));
async function get(path){const r=await fetch(H+path);if(r.status===404)return null;if(!r.ok)throw new Error('Horizon failed');return r.json();}
async function rpc(method,params){const r=await fetch(R,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:1,method,params})});const v=await r.json();if(v.error)throw new Error('RPC failure');return v.result;}
async function confirmed(hash){for(let i=0;i<35;i++){const tx=await get('/transactions/'+hash);if(tx){if(!tx.successful)throw new Error('Fixture execution failed');return tx;}await new Promise(r=>setTimeout(r,1000));}throw new Error('Fixture remains pending');}
async function perform(name,role,op,contract=false){
 stage=name;if(f.done.includes(name))return null;
 if(f.pending){if(f.pending.name!==name)throw new Error('Resolve previous fixture transaction');const tx=await confirmed(f.pending.hash);f.done.push(name);delete f.pending;save();return tx;}
 const account=await get('/accounts/'+f[role].address);
 let tx=new s.TransactionBuilder(new s.Account(f[role].address,account.sequence),{fee:'120',networkPassphrase:N}).setTimeout(120).addOperation(op).build();
 if(contract){stage=name+'_simulate';const result=await rpc('simulateTransaction',{transaction:tx.toXDR()});if(result.error)throw new Error('Fixture simulation failed');stage=name+'_assemble';tx=s.rpc.assembleTransaction(tx,result).build();}
 stage=name+'_sign';tx.sign(key(role));f.pending={name,hash:Buffer.from(tx.hash()).toString('hex')};save();
 stage=name+'_broadcast';const response=await fetch(H+'/transactions',{method:'POST',headers:{'content-type':'application/x-www-form-urlencoded'},body:new URLSearchParams({tx:tx.toXDR()})});await response.arrayBuffer();
 stage=name+'_confirm';const result=await confirmed(f.pending.hash);f.done.push(name);delete f.pending;save();return result;
}
(async()=>{
 if((await get('')).network_passphrase!==N||(await rpc('getNetwork',{})).passphrase!==N)throw new Error('Wrong network');
 for(const role of ['issuer','sender','recipient','spare']){
  stage='account_'+role;if(!f[role]){const k=s.Keypair.random();f[role]={seed:Buffer.from(k.rawSecretKey()).toString('base64'),address:k.publicKey()};save();}
  if(role==='spare')continue;
  if(!await get('/accounts/'+f[role].address)){const r=await fetch('https://friendbot.stellar.org/?addr='+encodeURIComponent(f[role].address));if(!r.ok)throw new Error('Faucet failure');await r.arrayBuffer();}
 }
 const asset=new s.Asset('OATHLONG',f.issuer.address);f.classicReference=asset.contractId(N);save();
 for(const role of ['sender','recipient'])await perform('trust_'+role,role,s.Operation.changeTrust({asset,limit:'100000'}));
 await perform('issue','issuer',s.Operation.payment({destination:f.sender.address,asset,amount:'1000'}));
 await perform('memo_required','recipient',s.Operation.manageData({name:'config.memo_required',value:'1'}));
 if(wasmPath){
  const wasm=fs.readFileSync(wasmPath),hash=s.hash(wasm);f.wasmHash=Buffer.from(hash).toString('hex');save();
  await perform('upload_wasm','issuer',s.Operation.uploadContractWasm({wasm}),true);
  if(!f.salt){f.salt=require('crypto').randomBytes(32).toString('base64');save();}
  stage='contract_id';const preimage=s.xdr.HashIdPreimage.envelopeTypeContractId(new s.xdr.HashIdPreimageContractId({networkId:s.hash(Buffer.from(N)),contractIdPreimage:s.xdr.ContractIdPreimage.contractIdPreimageFromAddress(new s.xdr.ContractIdPreimageFromAddress({address:new s.Address(f.issuer.address).toScAddress(),salt:Buffer.from(f.salt,'base64')}))}));
  f.contract=s.StrKey.encodeContract(s.hash(preimage.toXDR()));save();
  await perform('deploy_contract','issuer',s.Operation.createCustomContract({address:new s.Address(f.issuer.address),wasmHash:hash,salt:Buffer.from(f.salt,'base64'),constructorArgs:[new s.Address(f.issuer.address).toScVal(),s.nativeToScVal(6,{type:'u32'}),s.nativeToScVal('Oath Test Token',{type:'string'}),s.nativeToScVal('OAT',{type:'string'})]}),true);
  await perform('mint_contract','issuer',new s.Contract(f.contract).call('mint',new s.Address(f.sender.address).toScVal(),s.nativeToScVal(1000000000n,{type:'i128'})),true);
 }
 console.log('STELLAR_TESTNET_FIXTURE_READY classic=true contract='+Boolean(f.contract));
})().catch(()=>{console.error('Stellar Testnet fixture failed at '+stage+'; keys and responses not printed.');process.exitCode=1;});
