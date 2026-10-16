// Only isolated devnet/testnet fixture keys. SDK creates approvals; Swift removes them.
const fs=require('fs'),w=require('/tmp/oath-solana-reference/node_modules/@solana/web3.js'),s=require('/tmp/oath-solana-reference/node_modules/@solana/spl-token');
(async()=>{
 const path=process.env.OATH_SOLANA_TESTNET_FIXTURE;if(!path)throw Error('Fixture required');
 const f=JSON.parse(fs.readFileSync(path));if(!['devnet','testnet'].includes(f.network))throw Error('Wrong network');
 const c=new w.Connection(`https://api.${f.network}.solana.com`,'confirmed'),payer=w.Keypair.fromSeed(Buffer.from(f.seed,'hex')),delegate=new w.PublicKey(f.recipient);
 const balance=await c.getBalance(payer.publicKey);console.log('Isolated test payer funded:',balance>20000000);if(balance<20000000)throw Error('Test funding needed');
 f.permissions=[];
 for(const program of [s.TOKEN_PROGRAM_ID,s.TOKEN_2022_PROGRAM_ID]){
  const mint=await s.createMint(c,payer,payer.publicKey,null,6,undefined,{commitment:'confirmed'},program);
  const token=await s.getOrCreateAssociatedTokenAccount(c,payer,mint,payer.publicKey,false,'confirmed',{commitment:'confirmed'},program);
  await s.mintTo(c,payer,mint,token.address,payer,1000000,[],{commitment:'confirmed'},program);
  const hash=await s.approve(c,payer,token.address,delegate,payer,123456,[],{commitment:'confirmed'},program);
  f.permissions.push({account:token.address.toBase58(),mint:mint.toBase58(),program:program.toBase58(),delegate:delegate.toBase58(),amount:123456});
  console.log('Test delegate approved',hash);
 }
 fs.writeFileSync(path,JSON.stringify(f),{mode:0o600});
})().catch(()=>{console.error('Permission Solana fixture preparation failed');process.exitCode=1});
