// Nile test funds only. Provider setup cannot use a mainnet endpoint.
const fs=require('fs'),{TronWeb}=require('/tmp/oath-tron-reference/node_modules/tronweb'),solc=require('/tmp/oath-tron-reference/node_modules/solc');
(async()=>{
 const path=process.env.OATH_TRON_TESTNET_FIXTURE;if(!path)throw Error();const f=JSON.parse(fs.readFileSync(path));if(f.network!=='nile')throw Error();
 const tron=new TronWeb({fullHost:'https://nile.trongrid.io',privateKey:f.key});const balance=await tron.trx.getBalance(f.sender);console.log('Nile test balance',balance);if(balance<100000000)throw Error();
 const source=`pragma solidity ^0.8.20;contract T {mapping(address=>mapping(address=>uint256)) public allowance;event Approval(address indexed owner,address indexed spender,uint256 value);function approve(address s,uint256 a)external returns(bool){allowance[msg.sender][s]=a;emit Approval(msg.sender,s,a);return true;}}`;
 const compiled=JSON.parse(solc.compile(JSON.stringify({language:'Solidity',sources:{'T.sol':{content:source}},settings:{evmVersion:'istanbul',outputSelection:{'*':{'*':['abi','evm.bytecode.object']}}}})));
 const a=compiled.contracts['T.sol'].T;
 if(!f.permissionContract){const tx=await tron.transactionBuilder.createSmartContract({abi:a.abi,bytecode:a.evm.bytecode.object,feeLimit:100000000,consumeUserResourcePercent:100,originEnergyLimit:10000000},f.sender);const sent=await tron.trx.sendRawTransaction(await tron.trx.sign(tx));if(!sent.result)throw Error();f.permissionContract=TronWeb.address.fromHex(tx.contract_address);fs.writeFileSync(path,JSON.stringify(f),{mode:0o600});console.log('Nile permission contract deployment',tx.txID);await new Promise(r=>setTimeout(r,6000));}
 const c=await tron.contract(a.abi,f.permissionContract);const hash=await c.approve(f.recipient,'123456').send({feeLimit:100000000});console.log('Nile test approval',hash);
})().catch(()=>{console.error('Nile approval setup failed');process.exitCode=1});
