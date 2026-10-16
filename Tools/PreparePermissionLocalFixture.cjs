// Isolated loopback execution oracle. The keys below are public test vectors.
const fs=require('fs'),ganache=require('/tmp/oath-arc-reference/node_modules/ganache');
const {Wallet,JsonRpcProvider,ContractFactory,Interface}=require('/tmp/oath-arc-reference/node_modules/ethers');
const solc=require('/tmp/oath-arc-reference/node_modules/solc');
(async()=>{
 const server=ganache.server({logging:{quiet:true},chain:{chainId:11155111,hardfork:'shanghai'},wallet:{accounts:[{secretKey:'0x'+'01'.repeat(32),balance:'0x3635c9adc5dea00000'}]}});await server.listen(18547,'127.0.0.1');
 const provider=new JsonRpcProvider('http://127.0.0.1:18547',11155111,{batchMaxCount:1}),wallet=new Wallet('0x'+'01'.repeat(32),provider),spender=new Wallet('0x'+'02'.repeat(32)).address;
 const source=`pragma solidity ^0.8.20;
 contract Token {mapping(address=>mapping(address=>uint256)) public allowance; function approve(address s,uint256 a) external returns(bool){allowance[msg.sender][s]=a;return true;}}
 contract FalseToken {function allowance(address,address) external pure returns(uint256){return 123;} function approve(address,uint256) external pure returns(bool){return false;}}
 contract NFT {mapping(uint256=>address) public ownerOf;mapping(uint256=>address) public getApproved;mapping(address=>mapping(address=>bool)) public isApprovedForAll;constructor(){ownerOf[7]=msg.sender;} function approve(address s,uint256 id) external {require(ownerOf[id]==msg.sender);getApproved[id]=s;}function setApprovalForAll(address s,bool v) external {isApprovedForAll[msg.sender][s]=v;}}
 contract Operator {mapping(address=>mapping(address=>bool)) public isApprovedForAll;function setApprovalForAll(address s,bool v) external {isApprovedForAll[msg.sender][s]=v;}}
 contract Permit {struct P{uint160 amount;uint48 expiration;uint48 nonce;}struct Pair{address token;address spender;}mapping(address=>mapping(address=>mapping(address=>P))) public allowance;function approve(address t,address s,uint160 a,uint48 e)external{allowance[msg.sender][t][s]=P(a,e,0);}function lockdown(Pair[] calldata pairs)external{for(uint i=0;i<pairs.length;i++){allowance[msg.sender][pairs[i].token][pairs[i].spender].amount=0;}}function invalidateNonces(address t,address s,uint48 n)external{require(n>allowance[msg.sender][t][s].nonce);allowance[msg.sender][t][s].nonce=n;}}`;
 const compiled=JSON.parse(solc.compile(JSON.stringify({language:'Solidity',sources:{'Test.sol':{content:source}},settings:{evmVersion:'shanghai',outputSelection:{'*':{'*':['abi','evm.bytecode','evm.deployedBytecode']}}}})));
 if(compiled.errors?.some(e=>e.severity==='error'))throw Error('Fixture compile failed');
 let nonce=0;const f={sender:wallet.address.toLowerCase(),spender:spender.toLowerCase()},contracts={};
 for(const name of ['Token','FalseToken','NFT','Operator']){const a=compiled.contracts['Test.sol'][name],c=await new ContractFactory(a.abi,a.evm.bytecode.object,wallet).deploy({nonce:nonce++});await c.waitForDeployment();f[name]=(await c.getAddress()).toLowerCase();contracts[name]=c;}
 await (await contracts.Token.approve(spender,123456n,{nonce:nonce++})).wait();
 await (await contracts.NFT.approve(spender,7,{nonce:nonce++})).wait();
 await (await contracts.NFT.setApprovalForAll(spender,true,{nonce:nonce++})).wait();
 await (await contracts.Operator.setApprovalForAll(spender,true,{nonce:nonce++})).wait();
 const permit='0x000000000022d473030f116ddee9f6b43ac78ba3',a=compiled.contracts['Test.sol'].Permit;
 await provider.send('evm_setAccountCode',[permit,'0x'+a.evm.deployedBytecode.object]);
 const iface=new Interface(a.abi);await(await wallet.sendTransaction({to:permit,data:iface.encodeFunctionData('approve',[f.Token,spender,1000,2000000000]),nonce:nonce++})).wait();
 f.vectors={token:new Interface(compiled.contracts['Test.sol'].Token.abi).encodeFunctionData('approve',[spender,0]),collectible:new Interface(compiled.contracts['Test.sol'].NFT.abi).encodeFunctionData('approve',['0x'+'0'.repeat(40),7]),collection:new Interface(compiled.contracts['Test.sol'].NFT.abi).encodeFunctionData('setApprovalForAll',[spender,false]),permit2:iface.encodeFunctionData('lockdown',[[[f.Token,spender]]]),permit2Nonce:iface.encodeFunctionData('invalidateNonces',[f.Token,spender,1])};
 fs.writeFileSync('/tmp/oath-permission-local.json',JSON.stringify(f));
 const timer=setInterval(()=>server.provider.request({method:'evm_mine',params:[]}).catch(()=>{}),1000);
 console.log('Permission execution fixture ready on loopback 18547');
 process.on('SIGTERM',async()=>{clearInterval(timer);provider.destroy();await server.close();process.exit(0)});
})().catch(()=>{console.error('Permission fixture setup failed');process.exitCode=1});
