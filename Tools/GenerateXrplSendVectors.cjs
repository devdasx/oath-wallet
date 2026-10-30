const fs=require('fs'),xrpl=require('xrpl');
const w=xrpl.Wallet.fromEntropy(new Uint8Array(16).fill(7),{algorithm:xrpl.ECDSA.secp256k1});
const recipient='rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh';
const vectors=[];
for(const ref of ['native','OAT.'+recipient,'000000010000000000000000000000000000000000000000']){
const amount=ref==='native'?'1234567':ref.includes('.')?{currency:'OAT',issuer:recipient,value:'1.23456789'}:{mpt_issuance_id:ref,value:'12345'};
const tx={TransactionType:'Payment',Flags:2147483648,Account:w.address,Destination:recipient,DestinationTag:0,Amount:amount,Fee:'12',Sequence:42,LastLedgerSequence:120};if(ref!=='native')tx.SendMax=amount;
const s=w.sign(tx);vectors.push({reference:ref,amount:ref==='native'?'1234567':ref.includes('.')?'123456789'+'0'.repeat(88):'12345',bytes:s.tx_blob,hash:s.hash});}
fs.writeFileSync(process.argv[2],JSON.stringify({testOnlyKey:w.privateKey.slice(2),address:w.address,publicKey:w.publicKey,vectors},null,2));
