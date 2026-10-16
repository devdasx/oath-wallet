// Public, deterministic test keys only. No user credentials or wallet material.
const fs=require('fs');
const {Wallet,Transaction,Interface}=require(process.env.OATH_ETHERS_MODULE || '/tmp/oath-arc-reference/node_modules/ethers');
(async()=>{
 const wallet=new Wallet('0x'+'01'.repeat(32)),recipient=new Wallet('0x'+'02'.repeat(32)).address.toLowerCase();
 const out=[];
 for(const [network,chainId] of [['arbitrum',42161],['ethereum',1],['base',8453],['telos',40],['hyperevm',999],['monad',143],['unichain',130]])for(const token of [false,true]) for(const legacy of [false,true]) {
  const reference=token?'0x89b50855aa3be2f677cd6303cec089b5f319d72a':'native';
  const amount=token?'1234567':'123456789012345678901';
  const data=token?new Interface(['function transfer(address,uint256)']).encodeFunctionData('transfer',[recipient,amount]):'0x';
  const raw=await wallet.signTransaction({type:legacy?0:2,chainId,nonce:7,gasLimit:token?70000:21000,...(legacy?{gasPrice:41000000000n}:{maxFeePerGas:41000000000n,maxPriorityFeePerGas:1000000000n}),to:token?reference:recipient,value:token?0n:BigInt(amount),data});
  const tx=Transaction.from(raw);
  out.push({network,legacy,sender:wallet.address.toLowerCase(),recipient,reference,decimals:token?6:18,amount,raw:raw.slice(2),hash:tx.hash});
 }
 fs.writeFileSync('Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/EVMSend/vectors.json',JSON.stringify(out,null,2)+'\n');
 console.log('Wrote independent ethers legacy and EIP-1559 vectors');
})();
