// Independent reference fixtures from the official @sqds/multisig 2.1.4 SDK.
// All seeds are deterministic, public, unfunded test fixtures.
const fs=require('fs'),w=require('@solana/web3.js'),s=require('@sqds/multisig'),spl=require('@solana/spl-token');
const pairs=Array.from({length:5},(_,i)=>w.Keypair.fromSeed(Buffer.alloc(32,20+i))),create=w.Keypair.fromSeed(Buffer.alloc(32,100)),recipient=w.Keypair.fromSeed(Buffer.alloc(32,101)).publicKey,mint=w.Keypair.fromSeed(Buffer.alloc(32,102)).publicKey,treasury=w.Keypair.fromSeed(Buffer.alloc(32,103)).publicKey;
const vectors=[];
for(const [required,count] of [[1,2],[2,3],[3,5],[5,5]]){
 const keys=pairs.slice(0,count).sort((a,b)=>a.publicKey.toBase58()<b.publicKey.toBase58()?-1:1);
 for(const payerIndex of [-1,...keys.keys()]){
 const payer=keys[payerIndex < 0 ? 0 : payerIndex].publicKey,approvers=[...keys.filter(k=>k.publicKey.equals(payer)),...keys.filter(k=>!k.publicKey.equals(payer))].slice(0,required);
 const [multisig,bump]=s.getMultisigPda({createKey:create.publicKey}),[vault]=s.getVaultPda({multisigPda:multisig,index:0}),[transaction]=s.getTransactionPda({multisigPda:multisig,index:1n}),[proposal]=s.getProposalPda({multisigPda:multisig,transactionIndex:1n});
 const account=s.accounts.Multisig.fromArgs({createKey:create.publicKey,configAuthority:w.PublicKey.default,threshold:required,timeLock:0,transactionIndex:0n,staleTransactionIndex:0n,rentCollector:null,bump,members:keys.map(k=>({key:k.publicKey,permissions:s.types.Permissions.all()}))}).serialize()[0];
 for(const kind of ['setup','native','spl','token2022']){
  let stages=[];let tokenProgram=kind==='token2022'?spl.TOKEN_2022_PROGRAM_ID:spl.TOKEN_PROGRAM_ID;let source=spl.getAssociatedTokenAddressSync(mint,vault,true,tokenProgram),dest=spl.getAssociatedTokenAddressSync(mint,recipient,false,tokenProgram);
  if(kind==='setup')stages=[[s.instructions.multisigCreateV2({multisigPda:multisig,createKey:create.publicKey,creator:payer,treasury,configAuthority:null,threshold:required,members:keys.map(k=>({key:k.publicKey,permissions:s.types.Permissions.all()})),timeLock:0,rentCollector:null})]];
  else{
   const inner=new w.TransactionMessage({payerKey:vault,recentBlockhash:create.publicKey.toBase58(),instructions:kind==='native'?[w.SystemProgram.transfer({fromPubkey:vault,toPubkey:recipient,lamports:1234567})]:[spl.createAssociatedTokenAccountIdempotentInstruction(vault,dest,recipient,mint,tokenProgram),spl.createTransferCheckedInstruction(source,mint,dest,vault,1234567,6,[],tokenProgram)]});
   const compiled=inner.compileToV0Message();
   stages=[[s.instructions.vaultTransactionCreate({multisigPda:multisig,transactionIndex:1n,creator:payer,vaultIndex:0,ephemeralSigners:0,transactionMessage:inner}),s.instructions.proposalCreate({multisigPda:multisig,transactionIndex:1n,creator:payer})],[...approvers.map(k=>s.instructions.proposalApprove({multisigPda:multisig,transactionIndex:1n,member:k.publicKey})),s.generated.createVaultTransactionExecuteInstruction({multisig,proposal,transaction,member:payer,anchorRemainingAccounts:compiled.staticAccountKeys.map((key,i)=>({pubkey:key,isSigner:false,isWritable:compiled.isAccountWritable(i)}))})]];
  }
  const messages=stages.map(ix=>new w.TransactionMessage({payerKey:payer,recentBlockhash:create.publicKey.toBase58(),instructions:ix}).compileToLegacyMessage());
  const txs=messages.map(m=>{const tx=new w.VersionedTransaction(m);tx.sign([...keys,create].filter(k=>m.accountKeys.slice(0,m.header.numRequiredSignatures).some(p=>p.equals(k.publicKey))));return Buffer.from(tx.serialize()).toString('base64')});
  vectors.push({...(payerIndex < 0 ? {} : {feePayer:payer.toBase58()}),required,count,kind,createKey:create.publicKey.toBase58(),multisig:multisig.toBase58(),vault:vault.toBase58(),treasury:treasury.toBase58(),recipient:recipient.toBase58(),mint:mint.toBase58(),source:source.toBase58(),program:tokenProgram.toBase58(),members:keys.map(k=>k.publicKey.toBase58()),seeds:keys.map(k=>Buffer.from(k.secretKey.slice(0,32)).toString('base64')),account:account.toString('base64'),messages:messages.map(m=>Buffer.from(m.serialize()).toString('base64')),transactions:txs});
 }
}
}
fs.mkdirSync('Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/SolanaMultisig',{recursive:true});fs.writeFileSync('Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/SolanaMultisig/sdk-vectors.json',JSON.stringify({sdk:'@sqds/multisig 2.1.4',createSeed:Buffer.alloc(32,100).toString('base64'),vectors},null,2));console.log(`Generated ${vectors.length} public deterministic Squads vectors.`);
