// Test-only contract deployment, using TronWeb for setup. Production Swift tests
// independently construct, sign and broadcast transfers against this contract.
// npm dependencies: tronweb@6.2.2 and solc@0.8.23. Keys stay in a 0600 local file.
const fs=require('fs'),{TronWeb}=require('tronweb'),solc=require('solc');
const path=process.env.OATH_TRON_TESTNET_FIXTURE;
if(!path)throw Error('OATH_TRON_TESTNET_FIXTURE required');
const fixture=JSON.parse(fs.readFileSync(path));
const source=`pragma solidity ^0.8.23;
contract OathTestToken {
 string public constant name="Oath Test Token"; string public constant symbol="OAT"; uint8 public constant decimals=6;
 mapping(address=>uint256) public balanceOf; address public owner; bool public blocked;
 event Transfer(address indexed from,address indexed to,uint256 value);
 constructor(){owner=msg.sender;balanceOf[msg.sender]=1000000000;emit Transfer(address(0),msg.sender,1000000000);}
 function setBlocked(bool value) external {require(msg.sender==owner);blocked=value;}
 function transfer(address to,uint256 value) external returns(bool){require(!blocked,"blocked");require(balanceOf[msg.sender]>=value,"balance");balanceOf[msg.sender]-=value;balanceOf[to]+=value;emit Transfer(msg.sender,to,value);return true;}
}`;
(async()=>{
 const compiled=JSON.parse(solc.compile(JSON.stringify({language:'Solidity',sources:{'Token.sol':{content:source}},settings:{evmVersion:'istanbul',optimizer:{enabled:true,runs:200},outputSelection:{'*':{'*':['abi','evm.bytecode.object']}}}})));
 if(compiled.errors?.some(e=>e.severity==='error'))throw Error('Compilation failed');
 const contract=compiled.contracts['Token.sol'].OathTestToken;
 const tron=new TronWeb({fullHost:'https://nile.trongrid.io',privateKey:fixture.key});
 if(fixture.contract){console.log('Existing Nile test contract '+fixture.contract);return;}
 const tx=await tron.transactionBuilder.createSmartContract({abi:contract.abi,bytecode:contract.evm.bytecode.object,feeLimit:100000000,consumeUserResourcePercent:100,originEnergyLimit:10000000},fixture.sender);
 const signed=await tron.trx.sign(tx),sent=await tron.trx.sendRawTransaction(signed);
 if(!sent.result)throw Error('Deployment rejected');
 fixture.contract=TronWeb.address.fromHex(tx.contract_address);fixture.deployHash=tx.txID;
 fs.writeFileSync(path,JSON.stringify(fixture),{mode:0o600});fs.chmodSync(path,0o600);
 console.log('Nile test contract '+fixture.contract+' deployment '+tx.txID);
 for(let i=0;i<40;i++){
  await new Promise(r=>setTimeout(r,3000));const info=await tron.trx.getConfirmedTransaction(tx.txID).catch(()=>null);
  if(info){if(info.ret?.[0]?.contractRet!=='SUCCESS')throw Error('Deployment failed');console.log('Deployment confirmed');return;}
 }
 throw Error('Deployment confirmation pending');
})().catch(e=>{console.error('Test contract setup failed; no provider payload printed');process.exitCode=1;});
