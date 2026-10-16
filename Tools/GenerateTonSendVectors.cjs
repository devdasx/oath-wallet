// Reference only: @ton/ton 16.3.0, @ton/core 0.63.1, @ton/crypto.
// Uses fixed public test keys; never load a wallet or production secret.
const fs=require('fs');const {WalletContractV4}=require('@ton/ton');const {beginCell,internal,storeMessage,external,storeMessageRelaxed}=require('@ton/core');const {keyPairFromSeed}=require('@ton/crypto');
const key=keyPairFromSeed(Buffer.alloc(32,1));const wallet=WalletContractV4.create({workchain:0,publicKey:key.publicKey});const recipient=WalletContractV4.create({workchain:0,publicKey:keyPairFromSeed(Buffer.alloc(32,2)).publicKey}).address;
const out=[];
for(const token of [false,true])for(const deploy of [false,true])for(const amount of token?[123456n,1000000000000000000000n]:[123456n]) {
 const jw=WalletContractV4.create({workchain:0,publicKey:keyPairFromSeed(Buffer.alloc(32,3)).publicKey}).address;
 const body=token?beginCell().storeUint(0xf8a7ea5,32).storeUint(42,64).storeCoins(amount).storeAddress(recipient).storeAddress(wallet.address).storeBit(0).storeCoins(1).storeBit(1).storeRef(beginCell().endCell()).endCell():beginCell().endCell();
 const message=internal({to:token?jw:recipient,value:token?150000000n:123456n,bounce:token,body});
 const transfer=wallet.createTransfer({seqno:deploy?0:7,timeout:2000000300,secretKey:key.secretKey,sendMode:3,messages:[message]});
 const normalized=beginCell().storeUint(2,2).storeUint(0,2).storeAddress(wallet.address).storeCoins(0).storeBit(0).storeBit(1).storeRef(transfer).endCell();
 out.push({token,deploy,amount:amount.toString(),sender:wallet.address.toRawString(),recipient:recipient.toRawString(),jettonWallet:jw.toRawString(),publicKey:key.publicKey.toString('hex'),body:transfer.toBoc({idx:false,crc32:false}).toString('base64'),bodyHash:transfer.hash().toString('hex'),hash:normalized.hash().toString('hex'),signingHash:beginCell().storeUint(wallet.walletId,32).storeUint(2000000300,32).storeUint(deploy?0:7,32).storeUint(0,8).storeUint(3,8).storeRef(beginCell().store(storeMessageRelaxed(message)).endCell()).endCell().hash().toString('hex')});
}
fs.mkdirSync('Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/TonSend',{recursive:true});fs.writeFileSync('Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/TonSend/vectors.json',JSON.stringify(out,null,2));

const library=beginCell().storeUint(2,8).storeBuffer(Buffer.alloc(32,7)).endCell({exotic:true});
const containing=beginCell().storeUint(123,32).storeRef(library).endCell();
fs.writeFileSync('Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/TonSend/library.json',JSON.stringify([library,containing].map(c=>({boc:c.toBoc().toString('base64'),hash:c.hash().toString('hex')})),null,2));
