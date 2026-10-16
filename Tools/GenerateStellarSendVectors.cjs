// Independent signing vectors using @stellar/stellar-sdk 17.2.1.
// Public, deterministic, unfunded test keys only. Never fund these addresses.
const fs=require('fs'),s=require('@stellar/stellar-sdk');
const seed=Buffer.alloc(32,11),sender=s.Keypair.fromRawEd25519Seed(seed),recipient=s.Keypair.fromRawEd25519Seed(Buffer.alloc(32,12)),issuer=s.Keypair.fromRawEd25519Seed(Buffer.alloc(32,13));
const net=s.Networks.TESTNET,asset=new s.Asset('OATHLONG',issuer.publicKey());
const contract=s.StrKey.encodeContract(Buffer.alloc(32,42));
const memo=s.Memo.id('18446744073709551615');
function builder(contract){return new s.TransactionBuilder(new s.Account(sender.publicKey(),'41'),{fee:'120',networkPassphrase:net,memo:contract ? s.Memo.none():memo}).setTimebounds(0,1700000120).setLedgerbounds(1000,1025);}
const args=[new s.Address(sender.publicKey()).toScVal(),new s.Address(recipient.publicKey()).toScVal(),s.nativeToScVal(12345n,{type:'i128'})];
const auth=new s.xdr.SorobanAuthorizationEntry({credentials:s.xdr.SorobanCredentials.sorobanCredentialsSourceAccount(),rootInvocation:new s.xdr.SorobanAuthorizedInvocation({function:s.xdr.SorobanAuthorizedFunction.sorobanAuthorizedFunctionTypeContractFn(new s.xdr.InvokeContractArgs({contractAddress:new s.Address(contract).toScAddress(),functionName:'transfer',args})),subInvocations:[]})});
const resources=new s.SorobanDataBuilder().setResources(100000,100,100).setResourceFee('1000').build();
const vectors=[];
for(const [kind,op] of [['native',s.Operation.payment({destination:recipient.publicKey(),asset:s.Asset.native(),amount:'1.25'})],['classic',s.Operation.payment({destination:recipient.publicKey(),asset,amount:'1.25'})],['createAccount',s.Operation.createAccount({destination:recipient.publicKey(),startingBalance:'1.25'})],['contract',s.Operation.invokeContractFunction({contract,function:'transfer',args,auth:[auth]})]]) {
 const b=builder(kind==='contract');if(kind==='contract')b.setSorobanData(resources);
 const tx=b.addOperation(op).build();
 tx.sign(sender);vectors.push({kind,hash:Buffer.from(tx.hash()).toString('hex'),envelope:tx.toXDR(),signature:Buffer.from(tx.signatures[0].signature.toString(), 'hex').toString('base64')});
}
// Independent short-code and memo encodings, including UTF-8 and 32-byte hashes.
const memoVectors=[];
for (const [type,value,memoValue] of [['text','اختبار',s.Memo.text('اختبار')],['hash','ab'.repeat(32),s.Memo.hash('ab'.repeat(32))],['returnHash','cd'.repeat(32),s.Memo.return('cd'.repeat(32))]]) {
 const tx=new s.TransactionBuilder(new s.Account(sender.publicKey(),'41'),{fee:'120',networkPassphrase:net,memo:memoValue}).setTimebounds(0,1700000120).setLedgerbounds(1000,1025).addOperation(s.Operation.payment({destination:recipient.publicKey(),asset:new s.Asset('OAT',issuer.publicKey()),amount:'1.25'})).build();
 tx.sign(sender);memoVectors.push({type,value,hash:Buffer.from(tx.hash()).toString('hex'),envelope:tx.toXDR()});
}
fs.writeFileSync(process.argv[2],JSON.stringify({sdk:'17.2.1',testOnlySeed:seed.toString('base64'),sender:sender.publicKey(),recipient:recipient.publicKey(),issuer:issuer.publicKey(),classicReference:asset.contractId(net),contract,resources:resources.toXDR('base64'),auth:auth.toXDR('base64'),vectors,memoVectors},null,2)+'\n');
