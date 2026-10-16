/* Explicit isolated Sepolia tests of official Uniswap/PancakeSwap routers.
 * Approvals, swaps and wrapping use the production Swift core. Creating a
 * test pool is separate ethers fixture setup (above the app gas cap). No real-value assets.
 * This does not exercise a browser, relay, app UI or physical device. */
const fs=require('node:fs'),{spawn}=require('node:child_process');
const {JsonRpcProvider,Contract,Interface,AbiCoder,solidityPacked,toQuantity,Wallet}=require('ethers');
const root='/tmp/oath-readable-dex',file=root+'/evidence.json';
fs.mkdirSync(root,{recursive:true,mode:0o700});
const state=fs.existsSync(file)?JSON.parse(fs.readFileSync(file)):{chainId:11155111,checks:[],pools:{}};
const save=()=>fs.writeFileSync(file,JSON.stringify(state,null,2),{mode:0o600});
const abi=AbiCoder.defaultAbiCoder(),sender='0x06b40f932ef96df1dd115040f1d2cdfd7f16d0ef';
const token='0x0c13395ff01d6ccf1eae8d3db91762b9d48c15cb'; // Previously deployed isolated OWCT token.
const self='0x0000000000000000000000000000000000000002';

const tokenABI=['function balanceOf(address) view returns(uint256)','function approve(address,uint256) returns(bool)','function deposit() payable','function withdraw(uint256)','function symbol() view returns(string)'];
const pmABI=['function WETH9() view returns(address)','function factory() view returns(address)','function createAndInitializePoolIfNecessary(address,address,uint24,uint160) payable returns(address)','function mint((address token0,address token1,uint24 fee,int24 tickLower,int24 tickUpper,uint256 amount0Desired,uint256 amount1Desired,uint256 amount0Min,uint256 amount1Min,address recipient,uint256 deadline)) payable returns(uint256,uint128,uint256,uint256)'];
const routerABI=['function V3_POSITION_MANAGER() view returns(address)','function execute(bytes,bytes[],uint256) payable'];
let stage='configuration';
const timer=setTimeout(()=>{console.log('FAIL DEX test timed out at '+stage);process.exit(1)},900000);
function bridge(transaction,name){return new Promise((resolve,reject)=>{let out='',err='';const p=spawn(process.env.OATH_WC_TX_BRIDGE,[],{stdio:['pipe','pipe','pipe']});p.stdout.on('data',d=>out+=d);p.stderr.on('data',d=>err+=d);p.on('error',()=>reject(Error('bridge-launch')));p.on('exit',c=>{try{if(c){if(/^Sepolia bridge failed: [A-Za-z0-9_(), -]+\n$/.test(err))process.stdout.write(err);throw Error('bridge-failed');}resolve(JSON.parse(out))}catch{reject(Error('bridge-failed'))}});p.stdin.end(JSON.stringify({keyFile:'/tmp/oath-evm-send-testnet-fixture.json',transaction,journal:root+'/'+name+'.journal.json'}));})}
(async()=>{
 if(!process.env.OATH_WC_TX_BRIDGE)throw Error('missing-bridge');
 const p=new JsonRpcProvider('https://ethereum-sepolia-rpc.publicnode.com',11155111,{staticNetwork:true,cacheTimeout:-1});p.pollingInterval=1500;
 if(BigInt(await p.send('eth_chainId',[]))!==11155111n)throw Error('wrong-chain');
 if(state.inFlight)throw Error('existing-inflight-requires-reconciliation');
 const startBalance=await p.getBalance(sender);if(startBalance<10000000000000000n)throw Error('needs-test-eth');
 const t=new Contract(token,tokenABI,p);
 if(await t.symbol()!=='OWCT')throw Error('wrong-test-token');
 async function send(name,to,data,value=0n,verify=null,decode=false){
  if(state.checks.some(c=>c.name===name))return;
  stage=name;
  if(BigInt(await p.send('eth_chainId',[]))!==11155111n)throw Error('wrong-chain');
  const gas=await p.estimateGas({from:sender,to,data,value});const fee=await p.getFeeData();
  if(!fee.maxFeePerGas||gas*fee.maxFeePerGas>2000000000000000n||startBalance-await p.getBalance(sender)>10000000000000000n||value>1000000000000000n)throw Error('budget');
  let result;
  if(name.endsWith('-initialize-pool')) {
   // Fixture provisioning only. Never relax production transaction gas limits.
   const f=JSON.parse(fs.readFileSync('/tmp/oath-evm-send-testnet-fixture.json'));
   const wallet=new Wallet(f.privateKey,p);
   if(wallet.address.toLowerCase()!==sender)throw Error('wrong-chain');
   const tx=await wallet.sendTransaction({to,data,value,gasLimit:gas*11n/10n,maxFeePerGas:fee.maxFeePerGas,maxPriorityFeePerGas:fee.maxPriorityFeePerGas});
   result={hash:tx.hash,fixtureSetup:true,productionSwift:false};
  } else result={...await bridge({from:sender,to,data,value:toQuantity(value)},name),productionSwift:true};
  state.inFlight={name,hash:result.hash};save();
  const r=await p.waitForTransaction(result.hash,1,120000);
  if(!r||r.status!==1)throw Error('failed-receipt');
  if(decode&&!result.fullyDecoded)throw Error('decode-incomplete');
  if(verify)await verify(r);
  state.checks.push({name,...result,receiptStatus:r.status,blockNumber:r.blockNumber,stateEffectVerified:verify!==null});delete state.inFlight;save();
  console.log('PASS '+name+' '+result.hash+(verify?' receipt and state effect verified':' receipt confirmed'));
 }
 for(const [name,address] of [['uniswap','0x3a9d48ab9751398bbfa63ad67599bb04e4bdf98b'],['pancakeswap','0x6a3d58cc25a92d90fa3a8f0f5d5e75ad01ccd7a6']]){
  if(state.checks.some(c=>c.name===name+'-token-to-native')&&state.checks.some(c=>c.name===name+'-native-to-token'))continue;
  stage=name+'-configuration';
  // PancakeSwap uses its own Permit2 deployment, including on Sepolia.
  const permit2=name==='pancakeswap'?'0x31c2f6fcff4f8759b3bd5bf0e1084a055615c768':'0x000000000022d473030f116ddee9f6b43ac78ba3';
  const router=new Contract(address,routerABI,p),manager=await router.V3_POSITION_MANAGER(),pm=new Contract(manager,pmABI,p),weth=await pm.WETH9();
  const w=new Contract(weth,tokenABI,p),factory=new Contract(await pm.factory(),['function getPool(address,address,uint24) view returns(address)','function feeAmountTickSpacing(uint24) view returns(int24)'],p);
  const feeTier=name==='uniswap'?3000:2500,spacing=Number(await factory.feeAmountTickSpacing(name==='uniswap'?3000:2500));
  if(spacing<=0)throw Error('unsupported-pool-fee');
  const bound=Math.floor(887272/spacing)*spacing;
  const [token0,token1]=[token,weth].sort((a,b)=>a.toLowerCase().localeCompare(b.toLowerCase()));
  const liquidity=100000000000000n,amount=1000000000000n,deadline=()=>Math.floor(Date.now()/1000)+1800;
  await send(name+'-wrap-for-pool',weth,w.interface.encodeFunctionData('deposit'),liquidity,async()=>{if(await w.balanceOf(sender)<liquidity)throw Error('wrap-balance')});
  await send(name+'-approve-test-token',token,t.interface.encodeFunctionData('approve',[manager,liquidity]));
  await send(name+'-approve-wrapped-token',weth,w.interface.encodeFunctionData('approve',[manager,liquidity]));
  await send(name+'-initialize-pool',manager,pm.interface.encodeFunctionData('createAndInitializePoolIfNecessary',[token0,token1,feeTier,1n<<96n]));
  const pool=await factory.getPool(token,weth,feeTier);if(pool==='0x0000000000000000000000000000000000000000')throw Error('missing-pool');
  state.pools[name]={router:address,manager,weth,pool,token};save();
  await send(name+'-seed-test-liquidity',manager,pm.interface.encodeFunctionData('mint',[[token0,token1,feeTier,-bound,bound,liquidity,liquidity,0,0,sender,deadline()]]),0n,async()=>{const v=await new Contract(pool,['function liquidity() view returns(uint128)'],p).liquidity();if(v===0n)throw Error('no-liquidity')});
  await send(name+'-approve-protocol-permit2',token,t.interface.encodeFunctionData('approve',[permit2,amount]));
  const pi=new Interface(['function approve(address,address,uint160,uint48)']);
  await send(name+'-protocol-permit2-router-limit',permit2,pi.encodeFunctionData('approve',[token,address,amount,deadline()]));
  const swapInput=abi.encode(['address','uint256','uint256','bytes','bool'],[self,amount,amount*9n/10n,solidityPacked(['address','uint24','address'],[token,feeTier,weth]),true]);
  const unwrap=abi.encode(['address','uint256'],[sender,amount*9n/10n]);
  const beforeToken=await t.balanceOf(sender),beforeNative=await p.getBalance(sender);
  // Nested swap+unwrap followed by sweep reproduces the screenshot's 0x2104 format.
  const nested=abi.encode(['bytes','bytes[]'],['0x000c',[swapInput,unwrap]]);
  const sweep=abi.encode(['address','address','uint256'],[token,sender,0]);
  await send(name+'-token-to-native',address,router.interface.encodeFunctionData('execute',['0x2104',[nested,sweep],deadline()]),0n,async r=>{
   if(beforeToken-await t.balanceOf(sender,{blockTag:r.blockNumber})!==amount)throw Error('input-delta');
   if(await p.getBalance(sender,r.blockNumber)+r.fee-beforeNative<amount*9n/10n)throw Error('native-output');
  },true);
  const beforeReturn=await t.balanceOf(sender);
  await send(name+'-native-to-token',address,router.interface.encodeFunctionData('execute',['0x0b00',[abi.encode(['address','uint256'],[self,amount]),abi.encode(['address','uint256','uint256','bytes','bool'],[sender,amount,amount*9n/10n,solidityPacked(['address','uint24','address'],[weth,feeTier,token]),false])],deadline()]),amount,async r=>{if(await t.balanceOf(sender,{blockTag:r.blockNumber})-beforeReturn<amount*9n/10n)throw Error('token-output')},true);
 }
 state.completedAt=new Date().toISOString();state.scope='Actual official Sepolia Uniswap and PancakeSwap V3 pools/Universal Routers, isolated test-token liquidity, production Swift parsing/quote/preflight/sign/broadcast/decode. Not browser/relay/UI.';save();clearTimeout(timer);p.destroy();
})().catch(e=>{clearTimeout(timer);console.log('FAIL DEX check at '+stage+'; category '+(['missing-bridge','existing-inflight-requires-reconciliation','needs-test-eth','budget','decode-incomplete','failed-receipt','bridge-failed','wrong-chain','no-liquidity','input-delta','native-output','token-output'].includes(e.message)?e.message:'unavailable')+'; no private error data emitted');process.exitCode=1;setTimeout(()=>process.exit(1),100)});
