// Public deterministic fixtures encoded independently with ethers.
const fs = require('node:fs');
const { Interface } = require('ethers');
const router = new Interface(['function depositWithExpiry(address vault,address asset,uint256 amount,string memo,uint256 expiry) payable']);
const vault = '0x'+'11'.repeat(20), token = '0x55d398326f99059ff775485246999027b3197955';
const memo = '=:r:thor172egzpvhpe4pgd69ql4fjr6sjrlrftkgat79m2:3199660000/1/1';
const tokens = {
 1: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
 56: token,
 43114: '0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e',
 8453: '0x833589fcd6edb6e08f4c7c32d4f71b54bda02913',
 137: '0x3c499c542cef5e3811e1192ce70d8cc03d5c3359'
};
const rows = [
 {name:'bsc-usdt-rune', chain:56, token, amount:'20000000000000000000', value:'0', memo},
 {name:'bsc-live-rune', chain:56, token, amount:'20000000000000000000', value:'0', memo:memo.replace('3199660000','0')},
 {name:'eth-native-rune', chain:1, token:'0x'+'00'.repeat(20), amount:'0', value:'10000000000000000', memo},
 {name:'avax-usdc-rune', chain:43114, token:'0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e', amount:'20000000', value:'0', memo},
 {name:'base-native-rune', chain:8453, token:'0x'+'00'.repeat(20), amount:'10000000000000000', value:'10000000000000000', memo},
 {name:'bsc-usdt-eth-usdc', chain:56, token, amount:'20000000000000000000', value:'0', memo:'=:ETH.USDC-0XA0B86991C6218B36C1D19D4A2E9EB0CE3606EB48:0x'+'22'.repeat(20)+':1900000000/1/1'}
]
.concat([1,56,43114,8453,137].flatMap(chain => [
 {name:`${chain}-native-short-usdt`, chain, token:'0x'+'00'.repeat(20), amount:'0', value:'10000000000000000', memo:'=:BSC.USDT:0x'+'22'.repeat(20)+':100/1/1'},
 {name:`${chain}-token-short-usdt`, chain, token:tokens[chain], amount:chain === 56 ? '20000000000000000000' : '20000000', value:'0', memo:'=:BSC.USDT-7955:0x'+'22'.repeat(20)+':100/1/1'}
]))
.map(r=>({...r,data:router.encodeFunctionData('depositWithExpiry',[vault,r.token,r.amount,r.memo,2000000000])}));
fs.writeFileSync('Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/ThorchainDeposits.json',JSON.stringify(rows,null,2)+'\n');
