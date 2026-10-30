// Independent ABI and transaction signature fixtures; public deterministic key.
const fs = require('fs');
const {Wallet, Interface, keccak256} = require('/tmp/oath-arc-reference/node_modules/ethers');
const wallet = new Wallet('0x'+'01'.repeat(32));
const contract = '0x2222222222222222222222222222222222222222';
const other = '0x3333333333333333333333333333333333333333';
const token = new Interface(['function approve(address,uint256)', 'function transfer(address,uint256)',
 'function transferFrom(address,address,uint256)', 'function setApprovalForAll(address,bool)', 'function safeTransferFrom(address,address,uint256)']);
const router = new Interface(['function exactInputSingle((address tokenIn,address tokenOut,uint24 fee,address recipient,uint256 deadline,uint256 amountIn,uint256 amountOutMinimum,uint160 sqrtPriceLimitX96)) payable returns (uint256)']);
(async()=>{
 const rows=[];
 async function add(name,kind,data,to=contract,value=0n){
  const unsigned={chainId:1,type:2,nonce:7,to,value,data,gasLimit:60000,maxFeePerGas:1000000000,maxPriorityFeePerGas:1};
  const signed=await wallet.signTransaction(unsigned);
  rows.push({name,kind,request:JSON.stringify([{from:wallet.address,to,value:'0x'+value.toString(16),data}]),signed,hash:keccak256(signed)});
 }
 await add('native','transfer','0x',other,123456789012345678n);
 await add('approval','approval',token.encodeFunctionData('approve',[other,(1n<<256n)-1n]));
 await add('transfer','transfer',token.encodeFunctionData('transfer',[other,123456789n]));
 await add('ambiguous-transfer-from','contract',token.encodeFunctionData('transferFrom',[wallet.address,other,7n]));
 await add('nft','nft',token.encodeFunctionData('safeTransferFrom',[wallet.address,other,7n]));
 await add('operator','operatorApproval',token.encodeFunctionData('setApprovalForAll',[other,true]));
 const swap=router.encodeFunctionData('exactInputSingle',[[contract,other,3000,wallet.address,2000000000,1000000,990000,0]]);
 await add('swap','swap',swap,'0xE592427A0AEce92De3Edee1F18E0157C05861564');
 await add('spoofed-router','contract',swap);
 await add('unknown','contract','0x1234567890');
 fs.writeFileSync('Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/WalletConnect/evm-data.json',JSON.stringify(rows,null,2)+'\n');
 console.log('Generated '+rows.length+' independent WalletConnect ABI/signature vectors.');
})().catch(()=>{console.error('Fixture generation failed');process.exit(1)});
