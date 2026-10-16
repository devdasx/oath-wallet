// Independent ethers EIP-712 vectors. Only the public, deterministic key 0x01…01.
const fs = require('fs');
const {Wallet, TypedDataEncoder} = require(process.env.OATH_ETHERS_MODULE || '/tmp/oath-arc-reference/node_modules/ethers');
const wallet = new Wallet('0x' + '01'.repeat(32));
const contract = '0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC';
const domain = {name:'Oath EIP712 Tests', version:'1', chainId:1, verifyingContract:contract};
const rows = [];
const field = (name,type) => ({name,type});
async function add(name,types,message,d=domain,rawNumber=false) {
 const primaryType = TypedDataEncoder.from(types).primaryType;
 const domainFields=Object.entries(d).map(([name])=>field(name,({name:'string',version:'string',chainId:'uint256',verifyingContract:'address',salt:'bytes32'})[name]));
 let json=JSON.stringify({types:{EIP712Domain:domainFields,...types},primaryType,domain:d,message});
 if(rawNumber) json=json.replace('"'+message.value+'"',message.value);
 rows.push({name,json,digest:TypedDataEncoder.hash(d,types,message),signature:await wallet.signTypedData(d,types,message),account:wallet.address,chainId:Number(d.chainId||1)});
}
(async()=>{
 await add('official-mail',{Person:[field('name','string'),field('wallet','address')],Mail:[field('from','Person'),field('to','Person'),field('contents','string')]},
 {from:{name:'Cow',wallet:'0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826'},to:{name:'Bob',wallet:'0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB'},contents:'Hello, Bob!'},
 {name:'Ether Mail',version:'1',chainId:1,verifyingContract:contract});
 for(const bits of [8,16,48,160,256]) {
  await add('uint'+bits,{Value:[field('value','uint'+bits)]},{value:((1n<<BigInt(bits))-1n).toString()});
  await add('int'+bits+'-min',{Value:[field('value','int'+bits)]},{value:(-(1n<<BigInt(bits-1))).toString()});
  await add('int'+bits+'-max',{Value:[field('value','int'+bits)]},{value:((1n<<BigInt(bits-1))-1n).toString()});
 }
 await add('uint256-json-literal',{Value:[field('value','uint256')]},{value:((1n<<256n)-1n).toString()},domain,true);
 await add('atomic',{Value:[field('binary','bytes'),field('empty','bytes'),field('fixed','bytes4'),field('flag','bool'),field('other','bool'),field('text','string')]},{binary:'0x1234ff',empty:'0x',fixed:'0x01020304',flag:true,other:false,text:'عربي 🌍\u202econtent'});
 await add('arrays',{Item:[field('value','uint256'),field('label','string')],Basket:[field('items','Item[]'),field('grid','int16[2][]'),field('labels','string[]'),field('empty','bytes32[]')]},{items:[{value:'123',label:'First'},{value:'456',label:'Second'}],grid:[[-32768,32767],[0,-1]],labels:['one','two'],empty:[]});
 await add('empty-domain',{Value:[field('value','uint256')]},{value:'5'},{});
 await add('salt',{Value:[field('value','address')]},{value:wallet.address},{chainId:1,salt:'0x'+'ab'.repeat(32)});
 await add('permit',{Permit:[field('owner','address'),field('spender','address'),field('value','uint256'),field('nonce','uint256'),field('deadline','uint256')]},{owner:wallet.address,spender:contract,value:'100000000',nonce:'7',deadline:'2000000000'});
 const permit2={name:'Permit2',chainId:1,verifyingContract:'0x000000000022D473030F116dDEE9F6B43aC78BA3'};
 await add('permit2-allowance',{PermitDetails:[field('token','address'),field('amount','uint160'),field('expiration','uint48'),field('nonce','uint48')],PermitSingle:[field('details','PermitDetails'),field('spender','address'),field('sigDeadline','uint256')]},{details:{token:contract,amount:'1000000',expiration:'2000000100',nonce:'4'},spender:contract,sigDeadline:'2000000000'},permit2);
 await add('permit2-transfer',{TokenPermissions:[field('token','address'),field('amount','uint256')],PermitTransferFrom:[field('permitted','TokenPermissions'),field('spender','address'),field('nonce','uint256'),field('deadline','uint256')]},{permitted:{token:contract,amount:'1000000'},spender:contract,nonce:'4',deadline:'2000000000'},permit2);
 const root='Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/WalletConnect';fs.mkdirSync(root,{recursive:true});
 fs.writeFileSync(root+'/typed-data.json',JSON.stringify(rows,null,2)+'\n');
 console.log('Created '+rows.length+' independent EIP-712 hash/signature vectors.');
})().catch(e=>{console.error(e.message);process.exit(1)});
