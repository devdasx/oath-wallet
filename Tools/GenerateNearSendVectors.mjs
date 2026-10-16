// Independent Borsh/Ed25519 vectors from near-api-js 7.3.1.
// This public 00..1f key is deliberately deterministic. NEVER fund it.
import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';
const sdkRoot=process.env.OATH_NEAR_SDK_ROOT;
const {KeyPair,createTransaction,actions,baseEncode,encodeTransaction,Signature,SignedTransaction}=
    await import(sdkRoot ? pathToFileURL(path.join(sdkRoot,'lib/index.js')).href : 'near-api-js');
const seed=Buffer.from(Array.from({length:32},(_,i)=>i));
const key=KeyPair.fromString('ed25519:'+baseEncode(seed)),publicKey=key.getPublicKey();
const block=Buffer.alloc(32,3),recipient='recipient.testnet',vectors=[];
for(const token of [false,true]) {
    const list=token ? [
        actions.functionCall('storage_deposit',Buffer.from(JSON.stringify({account_id:recipient,registration_only:true})),30000000000000n,1250000000000000000000n),
        actions.functionCall('ft_transfer',Buffer.from(JSON.stringify({amount:'100000000000000000000000',receiver_id:recipient})),50000000000000n,1n)
    ] : [actions.transfer(100000000000000000000000n)];
    const transaction=createTransaction('sender.testnet',publicKey,token?'wrap.testnet':recipient,123456789000001n,list,block);
    const raw=encodeTransaction(transaction),digest=createHash('sha256').update(raw).digest();
    const signature=key.sign(digest).signature;
    const signed=new SignedTransaction({transaction,signature:new Signature({keyType:0,data:signature})});
    vectors.push({token,publicKey:Buffer.from(publicKey.data).toString('base64'),raw:Buffer.from(raw).toString('base64'),
        signed:Buffer.from(signed.encode()).toString('base64'),signature:Buffer.from(signature).toString('base64'),hash:baseEncode(digest),block:baseEncode(block)});
}
fs.writeFileSync(path.resolve(import.meta.dirname,'../Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/NearSend/vectors.json'),JSON.stringify(vectors,null,2));
console.log('Wrote two public NEAR SDK vectors.');
