const fs=require('fs'),{TronWeb}=require('/tmp/oath-tron-reference/node_modules/tronweb');
(async()=>{
 const path=process.env.OATH_TRON_TESTNET_FIXTURE;if(!path)throw Error();const f=JSON.parse(fs.readFileSync(path));if(f.network!=='nile')throw Error();
 const tron=new TronWeb({fullHost:'https://nile.trongrid.io',privateKey:f.key});const a=await tron.trx.getAccount(f.sender);
 const active=a.active_permission.map((p,i)=>i===0?{...p,type:2,keys:[{address:TronWeb.address.toHex(f.sender),weight:1},{address:TronWeb.address.toHex(f.recipient),weight:1}],threshold:1}:{...p,type:2});
 const tx=await tron.transactionBuilder.updateAccountPermissions(f.sender,{...a.owner_permission,type:0},a.witness_permission,active);
 const reply=await tron.trx.sendRawTransaction(await tron.trx.sign(tx));if(!reply.result)throw Error();console.log('Nile extra active test key added',tx.txID);
})().catch(()=>{console.error('Nile control fixture failed');process.exitCode=1});
