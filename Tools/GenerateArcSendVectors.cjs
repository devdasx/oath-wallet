// Public, deterministic test keys only. No user credentials or wallet material.
const fs=require('fs');
const {Wallet,Transaction,Interface}=require(process.env.OATH_ETHERS_MODULE || '/tmp/oath-arc-reference/node_modules/ethers');
(async()=>{
 const wallet=new Wallet('0x'+'01'.repeat(32)),recipient=new Wallet('0x'+'02'.repeat(32)).address.toLowerCase();
 const out=[];
 for(const [network,chainId] of [['mainnet',5042],['testnet',5042002]])for(const token of [false,true]) {
  const reference=token?'0x89b50855aa3be2f677cd6303cec089b5f319d72a':'native';
  const amount=token?'1234567':'123456789012345678901';
  const data=token?new Interface(['function transfer(address,uint256)']).encodeFunctionData('transfer',[recipient,amount]):'0x';
  const raw=await wallet.signTransaction({type:2,chainId,nonce:7,gasLimit:token?70000:21000,maxFeePerGas:41000000000n,maxPriorityFeePerGas:1000000000n,to:token?reference:recipient,value:token?0n:BigInt(amount),data});
  const tx=Transaction.from(raw);
  out.push({network,sender:wallet.address.toLowerCase(),recipient,reference,decimals:token?6:18,amount,raw:raw.slice(2),hash:tx.hash});
 }
 fs.writeFileSync('Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/ArcSend/vectors.json',JSON.stringify(out,null,2)+'\n');
 console.log('Wrote four independent ethers EIP-1559 vectors');
})();
