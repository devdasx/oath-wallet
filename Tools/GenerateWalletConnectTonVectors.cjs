const fs=require('fs');const {WalletContractV4}=require('@ton/ton');const {beginCell,internal,storeMessageRelaxed}=require('@ton/core');const {keyPairFromSeed,sign}=require('@ton/crypto');const {createHash}=require('crypto');
const key=keyPairFromSeed(Buffer.alloc(32,1)), wallet=WalletContractV4.create({workchain:0,publicKey:key.publicKey});const recipient=WalletContractV4.create({workchain:0,publicKey:keyPairFromSeed(Buffer.alloc(32,2)).publicKey}).address;
const sha=b=>createHash('sha256').update(b).digest();const u32=n=>{let b=Buffer.alloc(4);b.writeUInt32BE(n);return b},u64=n=>{let b=Buffer.alloc(8);b.writeBigUInt64BE(BigInt(n));return b};
const vectors=[];for(const deploy of [false,true])for(const count of [1,4]){
const messages=Array.from({length:count},(_,i)=>internal({to:recipient,value:BigInt(1000000+i),bounce:false,body:beginCell().storeUint(0,32).storeStringTail('WC test '+i).endCell()}));
const body=wallet.createTransfer({seqno:deploy?0:7,timeout:2000000300,secretKey:key.secretKey,sendMode:3,messages});
const normalized=beginCell().storeUint(2,2).storeUint(0,2).storeAddress(wallet.address).storeCoins(0).storeBit(0).storeBit(1).storeRef(body).endCell();
vectors.push({deploy,count,bodyHash:body.hash().toString('hex'),hash:normalized.hash().toString('hex'),signingHash:body.beginParse().skip(512).asCell().hash().toString('hex'),signature:body.beginParse().loadBuffer(64).toString('base64'),params:{valid_until:2000000300,messages:messages.map(m=>({address:recipient.toString({bounceable:false,testOnly:true}),amount:m.info.value.coins.toString(),payload:m.body.toBoc().toString('base64')}))}});
}
const domain='test.oathwallet.org',ts=2000000000;
const dataVectors=[];for(const payload of [{type:'text',text:'Hello\nTON 🌍'},{type:'binary',bytes:Buffer.from([0,255,3,4]).toString('base64')},{type:'cell',schema:'test#12345678 value:uint32 = Test;',cell:beginCell().storeUint(0x12345678,32).storeUint(42,32).endCell().toBoc().toString('base64')}]){
let digest;if(payload.type==='cell'){
let crc=0xffffffff;for(const b of Buffer.from(payload.schema)){crc^=b;for(let i=0;i<8;i++)crc=(crc>>>1)^((crc&1)?0xedb88320:0);}crc=(~crc)>>>0;
const {Cell}=require('@ton/core');digest=beginCell().storeUint(0x75569022,32).storeUint(crc,32).storeUint(ts,64).storeAddress(wallet.address).storeStringRefTail(domain.split('.').reverse().join('\0')+'\0').storeRef(Cell.fromBase64(payload.cell)).endCell().hash();
}else{const data=payload.type==='text'?Buffer.from(payload.text):Buffer.from(payload.bytes,'base64');digest=sha(Buffer.concat([Buffer.from([255,255]),Buffer.from('ton-connect/sign-data/'),u32(0),wallet.address.hash,u32(Buffer.byteLength(domain)),Buffer.from(domain),u64(ts),Buffer.from(payload.type==='text'?'txt':'bin'),u32(data.length),data]));}
dataVectors.push({payload,digest:digest.toString('hex'),signature:sign(digest,key.secretKey).toString('base64')});}
const payload='public-test-challenge',proofMessage=Buffer.concat([Buffer.from('ton-proof-item-v2/'),u32(0),wallet.address.hash,Buffer.from(u32(Buffer.byteLength(domain))).reverse(),Buffer.from(domain),Buffer.from(u64(ts)).reverse(),Buffer.from(payload)]);
const proof=sign(sha(Buffer.concat([Buffer.from([255,255]),Buffer.from('ton-connect'),sha(proofMessage)])),key.secretKey).toString('base64');
const output={sender:wallet.address.toRawString(),domain,timestamp:ts,publicKey:key.publicKey.toString('hex'),stateInit:beginCell().store(require('@ton/core').storeStateInit(wallet.init)).endCell().toBoc().toString('base64'),vectors,dataVectors,proof:{payload,digest:sha(Buffer.concat([Buffer.from([255,255]),Buffer.from('ton-connect'),sha(proofMessage)])).toString('hex'),signature:proof}};
fs.mkdirSync('Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/WalletConnectTon',{recursive:true});fs.writeFileSync('Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/WalletConnectTon/vectors.json',JSON.stringify(output,null,2));console.log('Reference vectors saved');
