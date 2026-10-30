// Requires xrpl@5.3.0 in NODE_PATH. Explicit public TESTNET fixture only.
// Never import application wallets. The output is a private local file, not a repo artifact.
const fs = require('fs');
const xrpl = require('xrpl');
const path = process.argv[2];
if (!path || !path.startsWith('/tmp/')) throw new Error('Provide a /tmp/ fixture path');
const endpoint = 'https://s.altnet.rippletest.net:51234';
const fixture = fs.existsSync(path) ? JSON.parse(fs.readFileSync(path)) : {};
function save() { fs.writeFileSync(path, JSON.stringify(fixture), {mode: 0o600}); fs.chmodSync(path, 0o600); }
async function rpc(method, params = {}) {
  const response = await fetch(endpoint, {method:'POST',headers:{'content-type':'application/json'},
    body:JSON.stringify({method,params:[{...params,api_version:2}]})});
  if (!response.ok) throw new Error('Testnet HTTP failure');
  return (await response.json()).result;
}
async function send(wallet, transaction) {
  const [account,ledger] = await Promise.all([
    rpc('account_info',{account:wallet.address,ledger_index:'validated'}),rpc('ledger',{ledger_index:'validated'})]);
  const signed = new xrpl.Wallet(wallet.publicKey,wallet.privateKey).sign({...transaction,Account:wallet.address,
    Sequence:account.account_data.Sequence,Fee:'12',LastLedgerSequence:ledger.ledger_index+20});
  await rpc('submit',{tx_blob:signed.tx_blob});
  for(let attempt=0;attempt<30;attempt++) {
    await new Promise(resolve=>setTimeout(resolve,1000));
    const result=await rpc('tx',{transaction:signed.hash});
    if(result.validated) {
      if(result.meta.TransactionResult!=='tesSUCCESS') throw new Error('Testnet fixture transaction rejected');
      return result;
    }
  }
  throw new Error('Testnet fixture transaction remains uncertain; inspect before rerunning');
}
(async()=>{
  if((await rpc('server_info')).info.network_id!==1) throw new Error('Wrong network');
  for(const role of ['issuer','sender','recipient']) {
    if(!fixture[role]) {
      const wallet=xrpl.Wallet.generate(xrpl.ECDSA.secp256k1);
      fixture[role]={address:wallet.address,publicKey:wallet.publicKey,privateKey:wallet.privateKey};save();
    }
    const account=await rpc('account_info',{account:fixture[role].address,ledger_index:'validated'});
    if(account.error==='actNotFound') {
      const response=await fetch('https://faucet.altnet.rippletest.net/accounts',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({destination:fixture[role].address})});
      if(!response.ok) throw new Error('Faucet unavailable');
      await response.arrayBuffer(); // Never print the faucet response or its keys.
    } else if(account.error) throw new Error('Testnet account lookup failed');
  }
  if(!fixture.issued) {
    await send(fixture.issuer,{TransactionType:'AccountSet',SetFlag:8,TransferRate:1010000000});
    for(const role of ['sender','recipient']) await send(fixture[role],{TransactionType:'TrustSet',LimitAmount:{currency:'OAT',issuer:fixture.issuer.address,value:'100000'}});
    await send(fixture.issuer,{TransactionType:'Payment',Destination:fixture.sender.address,Amount:{currency:'OAT',issuer:fixture.issuer.address,value:'1000'}});
    fixture.issued='OAT.'+fixture.issuer.address;save();
  }
  if(!fixture.mpt) {
    const result=await send(fixture.issuer,{TransactionType:'MPTokenIssuanceCreate',AssetScale:2,MaximumAmount:'100000000',Flags:50,TransferFee:1000});
    const objects=await rpc('account_objects',{account:fixture.issuer.address,ledger_index:'validated',type:'mpt_issuance'});
    const object=objects.account_objects.find(value=>value.PreviousTxnID===result.hash);
    if(!object?.mpt_issuance_id) throw new Error('MPT fixture identity missing');
    fixture.mpt=object.mpt_issuance_id;save();
  }
  if(!fixture.mptFunded) {
    for(const role of ['sender','recipient']) await send(fixture[role],{TransactionType:'MPTokenAuthorize',MPTokenIssuanceID:fixture.mpt});
    await send(fixture.issuer,{TransactionType:'Payment',Destination:fixture.sender.address,Amount:{mpt_issuance_id:fixture.mpt,value:'100000'}});
    fixture.mptFunded=true;save();
  }
  await send(fixture.recipient,{TransactionType:'AccountSet',SetFlag:1});
  console.log('XRPL Testnet fixture ready. Keys remain only in the private local fixture file.');
})().catch(()=>{console.error('XRPL Testnet fixture setup failed; no secrets printed.');process.exitCode=1;});
