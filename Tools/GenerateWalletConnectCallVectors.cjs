// Independent ethers ABI encoder, deterministic public addresses. No keys.
const fs = require('node:fs');
const { AbiCoder, Interface, solidityPacked } = require('ethers');
const abi=AbiCoder.defaultAbiCoder();
const router=new Interface(['function execute(bytes,bytes[],uint256)','function execute(bytes,bytes[])']);
const a='0x'+'11'.repeat(20), b='0x'+'22'.repeat(20), c='0x'+'33'.repeat(20);
const sender='0x'+'00'.repeat(19)+'01', self='0x'+'00'.repeat(19)+'02';
const path=solidityPacked(['address','uint24','address','uint24','address'],[a,500,b,3000,c]);
const reverse=solidityPacked(['address','uint24','address','uint24','address'],[c,3000,b,500,a]);
const swap=(path,first=123456789n,second=100000000n,payer=true)=>abi.encode(['address','uint256','uint256','bytes','bool'],[sender,first,second,path,payer]);
const sweep=abi.encode(['address','address','uint256'],[a,sender,1]);
const rows=[];
function add(name,commands,inputs,deadline=true){rows.push({name,data:router.encodeFunctionData(deadline?'execute(bytes,bytes[],uint256)':'execute(bytes,bytes[])',deadline?[commands,inputs,2000000000]:[commands,inputs])});}
add('v3-exact-in','0x00',[swap(path)]);
add('v3-exact-out','0x01',[swap(reverse,100000000n,123456789n)]);
add('v2-exact-in','0x08',[abi.encode(['address','uint256','uint256','address[]','bool'],[sender,123456789,100000000,[a,b,c],true])]);
add('v2-exact-out','0x09',[abi.encode(['address','uint256','uint256','address[]','bool'],[sender,100000000,123456789,[a,b,c],false])]);
add('nested-swap-sweep','0x2104',[abi.encode(['bytes','bytes[]'],['0x0e000c',[abi.encode(['address','address','uint256'],[sender,a,123456789]),swap(path),abi.encode(['address','uint256'],[sender,100000000])]]),sweep]);
add('optional-nested','0xa1',[abi.encode(['bytes','bytes[]'],['0x0004',[swap(path),sweep]])]);
add('unknown-and-sweep','0x3f04',['0x12345678',sweep]);
add('reserved-bit','0x44',[sweep]);
add('wrap-transfer','0x0b05',[abi.encode(['address','uint256'],[self,1n<<255n]),abi.encode(['address','address','uint256'],[a,sender,1n<<255n])],false);
add('native-transfer-literal','0x05',[abi.encode(['address','address','uint256'],['0x'+'00'.repeat(20),sender,1n<<255n])]);
add('permit-transfer','0x02',[abi.encode(['address','address','uint160'],[a,self,123456789])]);
add('contract-balance-swap','0x00',[swap(path,1n<<255n,1n,false)]);
add('noncanonical-bool','0x00',[abi.encode(['address','uint256','uint256','bytes','uint256'],[sender,1,1,path,2])]);
add('invalid-path','0x00',[swap('0x12345678')]);
add('unknown-extra-argument','0x00',[swap(path)+'00'.repeat(32)]);
let nested=abi.encode(['bytes','bytes[]'],['0x04',[sweep]]);
for(let i=0;i<5;i++)nested=abi.encode(['bytes','bytes[]'],['0x21',[nested]]);
add('too-deep','0x21',[nested]);
// Approval-summary regressions: actual native boundaries and deliberately
// misleading wrappers. All data is deterministic and contains no private keys.
const weth='0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2';
const pair=(x,y)=>solidityPacked(['address','uint24','address'],[x,3000,y]);
const leg=(x,y,to=sender,payer=true,amount=123456789n,min=100000000n)=>abi.encode(['address','uint256','uint256','bytes','bool'],[to,amount,min,pair(x,y),payer]);
const unwrap=abi.encode(['address','uint256'],[sender,90000000]);
const wrap=abi.encode(['address','uint256'],[self,123456789]);
add('token-native','0x000c',[leg(a,weth,self),unwrap]);
add('native-token','0x0b00',[wrap,leg(weth,c,sender,false)]);
add('wrapped-token','0x00',[leg(weth,c)]);
add('unrelated-unwrap','0x000c',[leg(a,c,self),unwrap]);
add('unwrap-wrong-order','0x0c00',[unwrap,leg(a,weth,self)]);
add('unwrap-wrong-recipient','0x000c',[leg(a,weth,sender),unwrap]);
add('optional-native','0x800c',[leg(a,weth,self),unwrap]);
add('partial-native','0x000c3f',[leg(a,weth,self),unwrap,'0x']);
add('split-routes','0x0000',[leg(a,b),leg(a,c)]);
const v2=new Interface([
 'function swapExactTokensForTokens(uint256,uint256,address[],address,uint256)',
 'function swapTokensForExactTokens(uint256,uint256,address[],address,uint256)',
 'function swapExactETHForTokens(uint256,address[],address,uint256)',
 'function swapETHForExactTokens(uint256,address[],address,uint256)',
 'function swapExactTokensForETH(uint256,uint256,address[],address,uint256)',
 'function swapTokensForExactETH(uint256,uint256,address[],address,uint256)',
 'function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)',
 'function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256,address[],address,uint256)',
 'function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)'
]);
for(const f of v2.fragments){
 const nativeIn=f.name.includes('ETHFor'),nativeOut=f.name.includes('ForETH')||f.name.includes('ForExactETH');
 const args=nativeIn?[100000000,[weth,c],sender,2000000000]:[123456789,100000000,[a,b,nativeOut?weth:c],sender,2000000000];
 rows.push({name:'direct-'+f.name,data:v2.encodeFunctionData(f,args)});
}
fs.writeFileSync('Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/WalletConnect/call-details.json',JSON.stringify(rows,null,2)+'\n');
console.log('Generated '+rows.length+' total router vectors.');
