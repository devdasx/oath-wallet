// Independent CosmJS fixtures. A public, synthetic scalar is used only for tests.
// COSMJS_NODE_MODULE points at a node_modules directory with @cosmjs/amino,
// @cosmjs/proto-signing, @cosmjs/encoding and cosmjs-types installed.
const { createRequire } = require('node:module');
const fs = require('node:fs');
const load = createRequire(require('node:path').resolve(process.env.COSMJS_NODE_MODULE, '../package.json'));
const { Secp256k1Wallet, serializeSignDoc } = load('@cosmjs/amino');
const { DirectSecp256k1Wallet, makeAuthInfoBytes, makeSignDoc, makeSignBytes } = load('@cosmjs/proto-signing');
const { fromBech32 } = load('@cosmjs/encoding');
const { TxBody } = load('cosmjs-types/cosmos/tx/v1beta1/tx');
const { PubKey } = load('cosmjs-types/cosmos/crypto/secp256k1/keys');
const b64 = v => Buffer.from(v).toString('base64');
const varint = n => { n = BigInt(n); const b = []; do { let v = Number(n & 127n); n >>= 7n; b.push(v | (n ? 128 : 0)); } while(n); return Buffer.from(b); };
const field = (tag, v) => { const b = Buffer.from(v); return Buffer.concat([varint(tag*8+2),varint(b.length),b]); };
(async () => {
 const key = new Uint8Array(32).fill(1);
 const amino = await Secp256k1Wallet.fromKey(key, 'thor');
 const direct = await DirectSecp256k1Wallet.fromKey(key, 'thor');
 const [account] = await amino.getAccounts();
 const [recipient] = await (await Secp256k1Wallet.fromKey(new Uint8Array(32).fill(2),'thor')).getAccounts();
 const output=[];
 for (const kind of ['send','token','deposit','zero']) {
  const seq=kind==='zero'?0:7, acct=kind==='zero'?0:123;
  const amount=kind==='zero'?'0':'123456', denom=kind==='token'?'x/oath-test':'rune';
  const memo=kind==='deposit'?'=:ETH.ETH:0x1111111111111111111111111111111111111111:1':'Oath <&> / é اختبار';
  const isDeposit=['deposit','zero'].includes(kind);
  const aminoMsg=isDeposit?{type:'thorchain/MsgDeposit',value:{coins:[{asset:'THOR.RUNE',amount}],memo,signer:account.address}}:{type:'thorchain/MsgSend',value:{from_address:account.address,to_address:recipient.address,amount:[{denom,amount}]}};
  const commonAsset=Buffer.concat([field(1,'THOR'),field(2,'RUNE'),field(3,'RUNE')]);
  const message=isDeposit?Buffer.concat([field(1,Buffer.concat([field(1,commonAsset),field(2,amount)])),field(2,memo),field(3,fromBech32(account.address,96).data)]):Buffer.concat([field(1,fromBech32(account.address,96).data),field(2,fromBech32(recipient.address,96).data),field(3,Buffer.concat([field(1,denom),field(2,amount)]))]);
  const doc={chain_id:'thorchain-1',account_number:String(acct),sequence:String(seq),fee:{amount:[],gas:'500000000'},msgs:[aminoMsg],memo:isDeposit?'':memo};
  const signed=await amino.signAmino(account.address,doc);
  output.push({kind,method:'cosmos_signAmino',sender:account.address,recipient:isDeposit?null:recipient.address,publicKey:b64(account.pubkey),params:{signerAddress:account.address,signDoc:doc},signBytes:b64(serializeSignDoc(doc)),response:signed});
  const body=TxBody.encode(TxBody.fromPartial({messages:[{typeUrl:isDeposit?'/types.MsgDeposit':'/types.MsgSend',value:message}],memo:doc.memo})).finish();
  const auth=makeAuthInfoBytes([{pubkey:{typeUrl:'/cosmos.crypto.secp256k1.PubKey',value:PubKey.encode({key:account.pubkey}).finish()},sequence:seq}],[],500000000);
  const directDoc=makeSignDoc(body,auth,'thorchain-1',acct);
  const wireDoc={chainId:directDoc.chainId,accountNumber:String(directDoc.accountNumber),bodyBytes:b64(body),authInfoBytes:b64(auth)};
  const directSigned=await direct.signDirect(account.address,directDoc);
  output.push({kind,method:'cosmos_signDirect',sender:account.address,recipient:isDeposit?null:recipient.address,publicKey:b64(account.pubkey),params:{signerAddress:account.address,signDoc:wireDoc},signBytes:b64(makeSignBytes(directDoc)),response:{signed:wireDoc,signature:directSigned.signature}});
 }
 fs.mkdirSync('Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/ThorchainWalletConnect',{recursive:true});
 fs.writeFileSync('Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/ThorchainWalletConnect/vectors.json',JSON.stringify(output,null,2)+'\n');
 console.log(`Generated ${output.length} independent Cosmos signature fixtures; no private material written.`);
})();
