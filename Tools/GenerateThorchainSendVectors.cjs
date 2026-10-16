// Public key 01 x 32; never fund. WalletCore is independent of app signing code.
const {initWasm,TW}=require(process.env.WALLET_CORE_NODE_MODULE||'@trustwallet/wallet-core');
const fs=require('fs'),crypto=require('crypto');
(async()=>{
 const core=await initWasm(),key=core.PrivateKey.createWithData(Buffer.alloc(32,1)),other=core.PrivateKey.createWithData(Buffer.alloc(32,2));
 const a=core.AnyAddress.createWithPublicKey(key.getPublicKeySecp256k1(true),core.CoinType.thorchain),b=core.AnyAddress.createWithPublicKey(other.getPublicKeySecp256k1(true),core.CoinType.thorchain);
 const rows=[];
 for(const reference of ['native','tcy','x/ruji','x/oath-test']) for(const sequence of [0,7]) {
  const input=TW.Cosmos.Proto.SigningInput.fromObject({signingMode:1,accountNumber:'123',chainId:'thorchain-1',fee:{gas:'6000000',amounts:[]},memo:'Oath test',sequence:String(sequence),privateKey:Buffer.alloc(32,1),timeoutHeight:'130',messages:[{thorchainSendMessage:{fromAddress:a.data(),toAddress:b.data(),amounts:[{denom:reference==='native'?'rune':reference,amount:'123456'}]}}]});
  const output=TW.Cosmos.Proto.SigningOutput.decode(core.AnySigner.sign(TW.Cosmos.Proto.SigningInput.encode(input).finish(),core.CoinType.thorchain));
  if(output.error)throw Error('WalletCore signing failed');
  const raw=JSON.parse(output.serialized),bytes=Buffer.from(raw.tx_bytes,'base64');
  rows.push({reference,sequence,sender:a.description(),recipient:b.description(),publicKey:Buffer.from(key.getPublicKeySecp256k1(true).data()).toString('hex'),bytes:bytes.toString('hex'),hash:crypto.createHash('sha256').update(bytes).digest('hex').toUpperCase()});
 }
 const target='Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/ThorchainSend';fs.mkdirSync(target,{recursive:true});fs.writeFileSync(target+'/vectors.json',JSON.stringify(rows,null,2)+'\n');console.log(rows.length+' independent WalletCore vectors generated');
 [a,b,key,other].forEach(x=>x.delete());
})();
