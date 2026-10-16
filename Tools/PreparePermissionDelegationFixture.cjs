// Public test vectors on an isolated Prague node. No user's wallet is loaded.
const fs=require('fs');
const {Wallet,JsonRpcProvider,Transaction,verifyAuthorization}=require('/tmp/oath-arc-reference/node_modules/ethers');
(async()=>{
 const p=new JsonRpcProvider('http://127.0.0.1:18548',11155111,{batchMaxCount:1}),w=new Wallet('0x'+'01'.repeat(32),p),delegate='0x'+'33'.repeat(20);
 await p.send('anvil_setBalance',[w.address,'0x3635c9adc5dea00000']);await p.send('anvil_setCode',[delegate,'0x00']);
 const nonce=await p.getTransactionCount(w.address,'pending');
 const auth=await w.authorize({address:delegate,chainId:11155111,nonce:nonce+1});
 const tx=await w.sendTransaction({type:4,to:'0x'+'00'.repeat(20),value:0,gasLimit:60000,nonce,authorizationList:[auth]});await tx.wait();
 if((await p.send('eth_getCode',[w.address,'latest'])).toLowerCase()!=='0xef0100'+delegate.slice(2))throw Error('Delegation setup did not take effect');
 fs.writeFileSync('/tmp/oath-permission-delegation.json',JSON.stringify({sender:w.address.toLowerCase(),delegate}));
 p.destroy();console.log('Isolated delegation fixture ready');
})().catch(()=>{console.error('Delegation fixture failed');process.exitCode=1});
