// Offline vectors from TronWeb 6.2.2. Only public, unfunded fixture keys.
const {TronWeb,utils}=require('tronweb');const fs=require('fs');
const key='07'.repeat(32),sender=TronWeb.address.fromPrivateKey(key),recipient=TronWeb.address.fromPrivateKey('08'.repeat(32));
const blockID='000000000447a0b3d5803edfbd5d08666d00b12161a4312777b38cb9a217d8d6',timestamp=1791940458000;
const vectors=[];
for(const reference of ['native','1005416','TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf']){
 const type=reference==='native'?'TransferContract':reference==='1005416'?'TransferAssetContract':'TriggerSmartContract';
 const value={owner_address:TronWeb.address.toHex(sender)};
 if(reference==='native'){value.to_address=TronWeb.address.toHex(recipient);value.amount=1234567;}
 else if(reference==='1005416'){value.asset_name=Buffer.from(reference).toString('hex');value.to_address=TronWeb.address.toHex(recipient);value.amount=1234567;}
 else {value.contract_address=TronWeb.address.toHex(reference);value.data='a9059cbb'+TronWeb.address.toHex(recipient).slice(2).padStart(64,'0')+BigInt(1234567).toString(16).padStart(64,'0');}
 const tx={visible:false,raw_data:{ref_block_bytes:blockID.slice(12,16),ref_block_hash:blockID.slice(16,32),expiration:timestamp+180000,contract:[{parameter:{value,type_url:'type.googleapis.com/protocol.'+type},type}],timestamp}};
 if(type==='TriggerSmartContract')tx.raw_data.fee_limit=10000000;
 const pb=utils.transaction.txJsonToPb(tx),raw=utils.transaction.txPbToRawDataHex(pb).toLowerCase(),hash=utils.transaction.txPbToTxID(pb).replace(/^0x/,'').toLowerCase();tx.txID=hash;
 const signed=utils.crypto.signTransaction(Buffer.from(key,'hex'),tx),signature=signed.signature[0];
 pb.addSignature(Buffer.from(signature,'hex'));
 vectors.push({reference,raw,hash,signature,bytes:Buffer.from(pb.serializeBinary()).toString('hex'),feeLimit:tx.raw_data.fee_limit||0});
}
fs.writeFileSync(process.argv[2],JSON.stringify({sdk:'tronweb@6.2.2',key,sender,recipient,blockID,timestamp,vectors},null,2)+'\n');console.log('Generated 3 independent TRON vectors');
