// Independent vectors from @aptos-labs/ts-sdk 7.5.0. Public fixture key 01 x 32; NEVER fund.
import {createRequire} from 'node:module';
const require=createRequire(process.env.OATH_APTOS_SDK_ROOT ? process.env.OATH_APTOS_SDK_ROOT+'/package.json' : import.meta.url);
const {Account,Ed25519PrivateKey,AccountAddress,RawTransaction,TransactionPayloadEntryFunction,EntryFunction,ChainId,Serializer,parseTypeTag,TransactionAuthenticatorEd25519,SignedTransaction}=require('@aptos-labs/ts-sdk');
import {createHash} from 'node:crypto';import fs from 'node:fs';
const key=new Ed25519PrivateKey(new Uint8Array(32).fill(1)),a=Account.fromPrivateKey({privateKey:key,legacy:true});
const b=Account.fromPrivateKey({privateKey:new Ed25519PrivateKey(new Uint8Array(32).fill(2)),legacy:true});
const u64=(n)=>{const s=new Serializer();s.serializeU64(n);return s.toUint8Array()};
const hash=x=>createHash('sha3-256').update(x).digest();
const rows=[];
for(const ref of ['native','0x123::example::Token','0x123::example::Generic<0x1::aptos_coin::AptosCoin>','0x456']){
 const coin=ref.includes('::'),isNative=ref==='native';
 const entry=EntryFunction.build(isNative||coin?'0x1::aptos_account':'0x1::primary_fungible_store',isNative?'transfer':coin?'transfer_coins':'transfer_assert_minimum_deposit',coin?[parseTypeTag(ref.replace('0x123','0x'+'123'.padStart(64,'0')))]:isNative?[]:[parseTypeTag('0x1::fungible_asset::Metadata')],(isNative||coin?[]:[AccountAddress.from("0x"+ref.slice(2).padStart(64,"0")).bcsToBytes()]).concat([b.accountAddress.bcsToBytes(),u64(123456)]).concat(isNative||coin?[]:[u64(123456)]).map(bytes=>({serializeForEntryFunction:s=>s.serializeBytes(bytes)})));
 // EntryFunction expects EntryFunctionArgument; serialize must write its vector.
 const raw=new RawTransaction(a.accountAddress,7n,new TransactionPayloadEntryFunction(entry),2000n,100n,2000000300n,new ChainId(2));
 const message=Buffer.concat([hash(Buffer.from('APTOS::RawTransaction')),raw.bcsToBytes()]);
 const signature=a.sign(message);const signed=new SignedTransaction(raw,new TransactionAuthenticatorEd25519(a.publicKey,signature));
 const bytes=signed.bcsToBytes();const digest='0x'+hash(Buffer.concat([hash(Buffer.from('APTOS::Transaction')),Buffer.from([0]),bytes])).toString('hex');
 rows.push({reference:ref,sender:a.accountAddress.toStringLong(),recipient:b.accountAddress.toStringLong(),publicKey:a.publicKey.toString(),raw:Buffer.from(raw.bcsToBytes()).toString('hex'),signature:signature.toString(),signed:Buffer.from(bytes).toString('hex'),hash:digest});
}
fs.mkdirSync('Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/AptosSend',{recursive:true});fs.writeFileSync('Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/AptosSend/vectors.json',JSON.stringify(rows,null,2));console.log('Generated',rows.length,'official SDK vectors');
