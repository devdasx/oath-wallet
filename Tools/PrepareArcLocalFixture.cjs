// Local execution oracle only. No user wallets or public network spending.
const fs=require('fs');
const ganache=require('/tmp/oath-arc-reference/node_modules/ganache');
const {Wallet,JsonRpcProvider,ContractFactory}=require('/tmp/oath-arc-reference/node_modules/ethers');
const solc=require('/tmp/oath-arc-reference/node_modules/solc');
(async()=>{
 const key='0x'+'01'.repeat(32),other='0x'+'02'.repeat(32);
 const server=ganache.server({logging:{quiet:true},chain:{chainId:5042002,hardfork:'shanghai'},miner:{defaultGasPrice:20000000000},wallet:{accounts:[{secretKey:key,balance:'0x3635c9adc5dea00000'}]}});
 await server.listen(18542,'127.0.0.1');
 const provider=new JsonRpcProvider('http://127.0.0.1:18542',5042002,{batchMaxCount:1}),wallet=new Wallet(key,provider);
 const source=`pragma solidity ^0.8.20;
 contract Token { uint8 public immutable decimals; mapping(address=>uint256) public balanceOf; event Transfer(address indexed from,address indexed to,uint256 value); constructor(uint8 d){decimals=d;balanceOf[msg.sender]=100000000;} function transfer(address to,uint256 n) external returns(bool){require(balanceOf[msg.sender]>=n);balanceOf[msg.sender]-=n;balanceOf[to]+=n;emit Transfer(msg.sender,to,n);return true;} }
 contract FalseToken { uint8 public constant decimals=6; function balanceOf(address) external pure returns(uint256){return 100000000;} function transfer(address,uint256) external pure returns(bool){return false;} }
 contract Reject { fallback() external payable { revert(); } }`;
 const compiled=JSON.parse(solc.compile(JSON.stringify({language:'Solidity',sources:{'Test.sol':{content:source}},settings:{evmVersion:'shanghai',outputSelection:{'*':{'*':['abi','evm.bytecode']}}}})));
 const f={sender:wallet.address.toLowerCase(),recipient:new Wallet(other).address.toLowerCase()};
 let nonce=0;
 for(const name of ['Token','FalseToken','Reject']) {
  const artifact=compiled.contracts['Test.sol'][name],factory=new ContractFactory(artifact.abi,artifact.evm.bytecode.object,wallet);
  const contract=await factory.deploy(...(name==='Token'?[6]:[]),{nonce:nonce++});await contract.waitForDeployment();f[name]=await contract.getAddress();
 }
 fs.writeFileSync('/tmp/oath-arc-local-fixture.json',JSON.stringify(f));
 // Arc produces blocks while idle. Keep that property without delaying Ganache's
 // instant transaction mining, so quote freshness is exercised accurately.
 const heartbeat=setInterval(()=>server.provider.request({method:'evm_mine',params:[]}).catch(()=>{}),1000);
 console.log('Local Arc-compatible EVM fixture ready on loopback port 18542');
 process.on('SIGTERM',async()=>{clearInterval(heartbeat);provider.destroy();await server.close();process.exit(0)});
 process.on('SIGINT',async()=>{clearInterval(heartbeat);provider.destroy();await server.close();process.exit(0)});
})().catch(e=>{console.error(e.code||e.name);process.exit(1)});
