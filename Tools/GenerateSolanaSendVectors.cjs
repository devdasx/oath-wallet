// Run with NODE_PATH pointing to an isolated @solana/web3.js + @solana/spl-token
// install. Only fixed, public fixture seeds are used. No network or real wallet.
const fs=require('fs'),w=require('@solana/web3.js'),spl=require('@solana/spl-token');
const out=process.argv[2];if(!out)throw Error('Output directory required');fs.mkdirSync(out,{recursive:true});
const sender=w.Keypair.fromSeed(Buffer.alloc(32,1)),recipient=w.Keypair.fromSeed(Buffer.alloc(32,2)).publicKey,mint=w.Keypair.fromSeed(Buffer.alloc(32,3)).publicKey;
const hash=w.Keypair.fromSeed(Buffer.alloc(32,4)).publicKey.toBase58();const vectors=[];
for(const kind of ['native','spl','token2022','transferFee']){
 const program=kind==='spl'?spl.TOKEN_PROGRAM_ID:spl.TOKEN_2022_PROGRAM_ID;
 const from=spl.getAssociatedTokenAddressSync(mint,sender.publicKey,false,program),to=spl.getAssociatedTokenAddressSync(mint,recipient,false,program);
 const ixs=[w.ComputeBudgetProgram.setComputeUnitLimit({units:200000}),w.ComputeBudgetProgram.setComputeUnitPrice({microLamports:1234n})];
 if(kind==='native')ixs.push(w.SystemProgram.transfer({fromPubkey:sender.publicKey,toPubkey:recipient,lamports:1234567n}));
 else{ixs.push(spl.createAssociatedTokenAccountIdempotentInstruction(sender.publicKey,to,recipient,mint,program));ixs.push(kind==='transferFee'?spl.createTransferCheckedWithFeeInstruction(from,mint,to,sender.publicKey,1234567n,6,12346n,[],program):spl.createTransferCheckedInstruction(from,mint,to,sender.publicKey,1234567n,6,[],program))}
 const msg=new w.TransactionMessage({payerKey:sender.publicKey,recentBlockhash:hash,instructions:ixs}).compileToLegacyMessage();
 const tx=new w.VersionedTransaction(msg);tx.sign([sender]);
 vectors.push({kind,sender:sender.publicKey.toBase58(),recipient:recipient.toBase58(),mint:mint.toBase58(),program:program.toBase58(),source:from.toBase58(),destination:to.toBase58(),hash,message:Buffer.from(msg.serialize()).toString('base64'),bytes:Buffer.from(tx.serialize()).toString('base64')});
}
const pdas=[];for(let i=0;i<64;i++){const o=w.Keypair.fromSeed(Buffer.alloc(32,i+10)).publicKey;for(const p of [spl.TOKEN_PROGRAM_ID,spl.TOKEN_2022_PROGRAM_ID])pdas.push({owner:o.toBase58(),mint:mint.toBase58(),program:p.toBase58(),address:spl.getAssociatedTokenAddressSync(mint,o,false,p).toBase58()})}
fs.writeFileSync(out+'/vectors.json',JSON.stringify({vectors,pdas},null,2));console.log('Wrote public SDK fixtures');
