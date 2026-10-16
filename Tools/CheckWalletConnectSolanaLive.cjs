const fs=require('fs'),cp=require('child_process'),w=require('@solana/web3.js'),spl=require('@solana/spl-token'),crypto=require('crypto');
const keyFile=process.env.OATH_SOLANA_TESTNET_FIXTURE;
if(!keyFile || !process.env.OATH_WC_SOLANA_BRIDGE)throw Error('Explicit isolated fixture required');
const f=JSON.parse(fs.readFileSync(keyFile));if(!['devnet','testnet'].includes(f.network))throw Error('Test clusters only');
const owner=new w.PublicKey(f.sender),receiver=new w.PublicKey(f.recipient),report=[];
function bridge(network,method,params,extra={}) { return new Promise((resolve,reject)=>{
 const p=cp.spawn(process.env.OATH_WC_SOLANA_BRIDGE,[],{stdio:['pipe','pipe','pipe']});let out='',err='';
 p.stdout.on('data',b=>out+=b);p.stderr.on('data',b=>err+=b);
 p.on('close',code=>{if(code)reject(Error('Swift '+err.trim()));else{try{resolve(JSON.parse(out))}catch{reject(Error('Bridge response'));}}});
 p.stdin.end(JSON.stringify({keyFile,chain:chains[network],method,params,...extra}));
});}
const chains={devnet:'solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1',testnet:'solana:4uhcVJyU9pJkvQyS88uRDiswHXSCkY3z'};
const pub=crypto.createPublicKey({key:Buffer.concat([Buffer.from('302a300506032b6570032100','hex'),owner.toBuffer()]),format:'der',type:'spki'});
function verifyTransaction(text){const tx=w.VersionedTransaction.deserialize(Buffer.from(text,'base64'));const index=tx.message.staticAccountKeys.findIndex(x=>x.equals(owner));if(index<0||!crypto.verify(null,Buffer.from(tx.message.serialize()),pub,Buffer.from(tx.signatures[index])))throw Error('Signature verification');return tx;}
async function run(){
 const c=new w.Connection(`https://api.${f.network}.solana.com`,'confirmed');
 const b58=require('bs58');const base58=b58.default||b58;
 const message=Buffer.from('Oath Solana WalletConnect test-only challenge');
 const m=await bridge(f.network,'solana_signMessage',{pubkey:f.sender,message:base58.encode(message)});
 if(!crypto.verify(null,message,pub,Buffer.from(base58.decode(m.result.signature))))throw Error('Message signature');
 report.push({check:'message-signature',network:f.network,verified:true});
 // Provision an address lookup table using isolated test funds. The actual
 // transfer still goes through the Swift WalletConnect signer and RPC client.
 const payer=w.Keypair.fromSeed(Buffer.from(f.seed,'hex'));
 let table=f.walletConnectLookup?await c.getAddressLookupTable(new w.PublicKey(f.walletConnectLookup)):null;
 if(!table?.value){
  const [create,address]=w.AddressLookupTableProgram.createLookupTable({authority:owner,payer:owner,recentSlot:await c.getSlot('finalized')});
  const extend=w.AddressLookupTableProgram.extendLookupTable({lookupTable:address,authority:owner,payer:owner,addresses:[receiver]});
  await w.sendAndConfirmTransaction(c,new w.Transaction().add(create,extend),[payer],{commitment:'confirmed'});
  f.walletConnectLookup=address.toBase58();fs.writeFileSync(keyFile,JSON.stringify(f),{mode:0o600});
  await new Promise(r=>setTimeout(r,2000)); table=await c.getAddressLookupTable(address);
 }
 if(!table?.value)throw Error('Lookup table unavailable');
 async function transaction(instructions,version=0){const {blockhash}=await c.getLatestBlockhash();return version===0?new w.VersionedTransaction(new w.TransactionMessage({payerKey:owner,recentBlockhash:blockhash,instructions}).compileToV0Message([table.value])):new w.Transaction({feePayer:owner,recentBlockhash:blockhash}).add(...instructions);}
 function encoded(tx){return Buffer.from(tx.serialize({requireAllSignatures:false,verifySignatures:false})).toString('base64');}
 const transfer=()=>w.SystemProgram.transfer({fromPubkey:owner,toPubkey:receiver,lamports:1000000});
 const original=encoded(await transaction([transfer()]));
 const wrong=await bridge(f.network==='devnet'?'testnet':'devnet','solana_signTransaction',{transaction:original},{rejectWrongCluster:true});
 if(!wrong.rejectedWrongCluster)throw Error('Wrong cluster accepted');report.push({check:'foreign-cluster-blockhash-rejected',verified:true});
 const batch=[encoded(await transaction([transfer()],1)),encoded(await transaction([transfer()],0))];
 const signed=await bridge(f.network,'solana_signAllTransactions',{transactions:batch});
 signed.result.transactions.forEach((text,i)=>{const tx=verifyTransaction(text),original=w.VersionedTransaction.deserialize(Buffer.from(batch[i],'base64'));if(!Buffer.from(tx.message.serialize()).equals(Buffer.from(original.message.serialize())))throw Error('Changed batch message');});
 report.push({check:'batch-legacy-and-v0-signatures',network:f.network,verified:true});
 await new Promise(r=>setTimeout(r,12000));
 const single=await bridge(f.network,'solana_signTransaction',{transaction:encoded(await transaction([transfer()])),pubkey:f.sender});
 verifyTransaction(single.result.transaction);report.push({check:'single-v0-lookup-signature',network:f.network,verified:true});
 const testMessage=await bridge('testnet','solana_signMessage',{pubkey:f.sender,message:base58.encode(message)});
 if(!crypto.verify(null,message,pub,Buffer.from(base58.decode(testMessage.result.signature))))throw Error('Testnet message signature');
 report.push({check:'message-signature',network:'testnet',verified:true});
 await new Promise(r=>setTimeout(r,12000));
 async function send(name,ix,tokenAccount){
  const before=tokenAccount?BigInt((await c.getTokenAccountBalance(tokenAccount)).value.amount):BigInt(await c.getBalance(receiver));
  const tx=encoded(await transaction(ix));const result=await bridge(f.network,'solana_signAndSendTransaction',{transaction:tx,pubkey:f.sender});
  const after=tokenAccount?BigInt((await c.getTokenAccountBalance(tokenAccount)).value.amount):BigInt(await c.getBalance(receiver));
  if(after-before!==1000000n || !result.confirmed)throw Error('Wrong balance delta '+name);
  report.push({check:name,network:f.network,signature:result.signature,confirmed:true,receivedAtomic:String(after-before),reviewedChanges:result.changes});
  console.log('PASS',name,result.signature);
  await new Promise(r=>setTimeout(r,12000));
 }
 await send('native-v0',[transfer()]);
 for(const [name,mintString,program] of [['spl',f.splMint,spl.TOKEN_PROGRAM_ID],['token-2022',f.token2022Mint,spl.TOKEN_2022_PROGRAM_ID]]){
  if(!mintString)continue;
  const mint=new w.PublicKey(mintString),source=spl.getAssociatedTokenAddressSync(mint,owner,false,program),dest=spl.getAssociatedTokenAddressSync(mint,receiver,false,program);
  // Existing isolated fixture has funded receiver token accounts from native send tests.
  await send(name,[spl.createTransferCheckedInstruction(source,mint,dest,owner,1000000n,6,[],program)],dest);
 }
 fs.mkdirSync('output',{recursive:true});fs.writeFileSync('output/walletconnect-solana-live.json',JSON.stringify({testedAt:new Date().toISOString(),layer:'production Swift protocol/signing/RPC with independent JS verification; no relay/UI',checks:report},null,2)+'\n');
 console.log('PASS',report.length,'Solana WalletConnect core live checks');
}
run().catch(e=>{console.error('Live check failed:',e.message);process.exitCode=1});
