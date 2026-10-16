// Isolated public testing networks only. Seeds remain in the private fixture file.
// SDK is used solely to create/mint test assets; Swift performs tested sends.
const fs=require('fs'),w=require('@solana/web3.js'),s=require('@solana/spl-token');
(async()=>{
 const path=process.env.OATH_SOLANA_TESTNET_FIXTURE;
 if(!path)throw Error('Fixture path required');
 const f=JSON.parse(fs.readFileSync(path));
 if(!['devnet','testnet'].includes(f.network))throw Error('Testing networks only');
 const c=new w.Connection(`https://api.${f.network}.solana.com`,'finalized'),payer=w.Keypair.fromSeed(Buffer.from(f.seed,'hex'));
 console.log('Test balance:',await c.getBalance(payer.publicKey));
 for(const [field,program,fee] of [['splMint',s.TOKEN_PROGRAM_ID,false],['token2022Mint',s.TOKEN_2022_PROGRAM_ID,false],['feeMint',s.TOKEN_2022_PROGRAM_ID,true]]){
  let mint;
  if(f[field])mint=new w.PublicKey(f[field]);
  else {
   const mintKey=w.Keypair.generate();mint=mintKey.publicKey;
   if(fee){
    const size=s.getMintLen([s.ExtensionType.TransferFeeConfig]);
    const tx=new w.Transaction().add(w.SystemProgram.createAccount({fromPubkey:payer.publicKey,newAccountPubkey:mint,space:size,lamports:await c.getMinimumBalanceForRentExemption(size),programId:program}),s.createInitializeTransferFeeConfigInstruction(mint,payer.publicKey,payer.publicKey,100,1000000n,program),s.createInitializeMintInstruction(mint,6,payer.publicKey,null,program));
    await w.sendAndConfirmTransaction(c,tx,[payer,mintKey],{commitment:'finalized'});
   } else await s.createMint(c,payer,payer.publicKey,null,6,mintKey,{commitment:'finalized'},program);
   f[field]=mint.toBase58();fs.writeFileSync(path,JSON.stringify(f),{mode:0o600});
  }
  const a=await s.getOrCreateAssociatedTokenAccount(c,payer,mint,payer.publicKey,false,'finalized',{commitment:'finalized'},program);
  let accounts=[a.address];
  if(field==='splMint'){
   const existing=await c.getTokenAccountsByOwner(payer.publicKey,{mint},'finalized');
   const extra=existing.value.find(x=>!x.pubkey.equals(a.address))?.pubkey ?? await s.createAccount(c,payer,mint,payer.publicKey,w.Keypair.generate(),{commitment:'finalized'},program);
   accounts.push(extra);
  }
  // Top up existing test mints so Max and restart checks are repeatable.
  for(const address of accounts){
   const current=(await s.getAccount(c,address,'finalized',program)).amount;
   if(current<500000000n)await s.mintTo(c,payer,mint,address,payer,500000000n-current,[],{commitment:'finalized'},program);
  }
  console.log('Prepared',field,f[field]);
 }
})().catch(e=>{console.error('Test preparation failed:',e.message);process.exitCode=1});
