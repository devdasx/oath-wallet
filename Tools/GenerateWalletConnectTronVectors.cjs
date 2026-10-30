// Public, unfunded keys for independent encoding and signature regression tests.
const {TronWeb,utils}=require('tronweb'), fs=require('node:fs');
(async()=>{
const key='07'.repeat(32), account=TronWeb.address.fromPrivateKey(key), recipient=TronWeb.address.fromPrivateKey('08'.repeat(32)), token='TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf';
const timestamp=1793380000000, vectors=[];
for(const kind of ['TRX','TRC10','TRC20','approve','revoke','contract','visible']) {
 const type=['TRX','visible'].includes(kind)?'TransferContract':kind==='TRC10'?'TransferAssetContract':'TriggerSmartContract';
 const visible=kind==='visible', addr=a=>visible?a:TronWeb.address.toHex(a), value={owner_address:addr(account)};
 if(type==='TransferContract'){value.to_address=addr(recipient);value.amount=1234567;}
 else if(type==='TransferAssetContract'){value.asset_name=Buffer.from('1005416').toString('hex');value.to_address=addr(recipient);value.amount=1234567;}
 else {value.contract_address=addr(token);const selector=kind==='approve'||kind==='revoke'?'095ea7b3':kind==='contract'?'12345678':'a9059cbb';value.data=selector+TronWeb.address.toHex(recipient).slice(2).padStart(64,'0')+(kind==='approve'?'f'.repeat(64):BigInt(kind==='revoke'?0:1234567).toString(16).padStart(64,'0'));if(kind==='contract')value.call_value=12;}
 const tx={visible,raw_data:{ref_block_bytes:'a0b3',ref_block_hash:'d5803edfbd5d0866',expiration:timestamp+180000,contract:[{parameter:{value,type_url:'type.googleapis.com/protocol.'+type},type}],timestamp,data:Buffer.from('Memo 🌍').toString('hex')}};
 if(type==='TriggerSmartContract')tx.raw_data.fee_limit=100000000;
 const pb=utils.transaction.txJsonToPb(tx);tx.raw_data_hex=utils.transaction.txPbToRawDataHex(pb).toLowerCase();tx.txID=utils.transaction.txPbToTxID(pb).replace(/^0x/,'').toLowerCase();
 const signed=utils.crypto.signTransaction(Buffer.from(key,'hex'),JSON.parse(JSON.stringify(tx)));
 vectors.push({kind,tx,signature:signed.signature[0]});
}
const tron=new TronWeb({fullHost:'https://nile.trongrid.io'}),messages=[];for(const message of ['Oath TRON WalletConnect test 🌍','0x1234','مرحبا\nTRON'])messages.push({message,signature:await tron.trx.signMessageV2(message,key)});
fs.writeFileSync(process.argv[2],JSON.stringify({sdk:TronWeb.version,key,account,recipient,token,timestamp,vectors,messages},null,2)+'\n');
process.stdout.write('Generated TRON WalletConnect vectors\n');
})().catch(()=>{process.stderr.write('Vector generation failed\n');process.exit(1);});
