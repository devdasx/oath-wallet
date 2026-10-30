/* Opt-in funded Sepolia fixtures. Local test key only; never logs errors that
 * could contain signed bytes, credentials or provider URLs. All asset values
 * are newly deployed test tokens, and all submitted calls use the Swift core. */
const fs = require('node:fs');
const { spawn } = require('node:child_process');
const { Wallet, JsonRpcProvider, ContractFactory, Contract, Interface, parseEther, toQuantity } = require('ethers');
const solc = require('solc');
const root = '/tmp/oath-walletconnect-sepolia';
fs.mkdirSync(root, { recursive: true, mode: 0o700 });
const statePath = root + '/public-evidence.json';
const state = fs.existsSync(statePath) ? JSON.parse(fs.readFileSync(statePath)) : { network: 'Sepolia', chainId: 11155111, deployments: {}, checks: [] };
const save = () => fs.writeFileSync(statePath, JSON.stringify(state, null, 2), { mode: 0o600 });
let stage = 'configuration';
const timer = setTimeout(() => { process.stdout.write('FAIL: Sepolia check timed out at ' + stage + '\n'); process.exit(1); }, 600000);
const source = `pragma solidity ^0.8.24;
contract TestToken {
 string public name = "Oath WalletConnect Test Token"; string public symbol = "OWCT"; uint8 public decimals = 18;
 mapping(address=>uint256) public balanceOf; mapping(address=>mapping(address=>uint256)) public allowance;
 event Transfer(address indexed from,address indexed to,uint256 value); event Approval(address indexed owner,address indexed spender,uint256 value);
 constructor(){balanceOf[msg.sender]=1000 ether;emit Transfer(address(0),msg.sender,1000 ether);}
 function mint(address to,uint256 amount) external {balanceOf[to]+=amount;emit Transfer(address(0),to,amount);}
 function approve(address to,uint256 amount) external returns(bool){allowance[msg.sender][to]=amount;emit Approval(msg.sender,to,amount);return true;}
 function transfer(address to,uint256 amount) external returns(bool){move(msg.sender,to,amount);return true;}
 function transferFrom(address from,address to,uint256 amount) external returns(bool){require(allowance[from][msg.sender]>=amount);allowance[from][msg.sender]-=amount;move(from,to,amount);return true;}
 function move(address from,address to,uint256 amount) internal {require(balanceOf[from]>=amount);balanceOf[from]-=amount;balanceOf[to]+=amount;emit Transfer(from,to,amount);}
}
contract TestNFT {
 mapping(uint256=>address) public ownerOf; event Transfer(address indexed from,address indexed to,uint256 indexed tokenId);
 constructor(){ownerOf[7]=msg.sender;emit Transfer(address(0),msg.sender,7);}
 function safeTransferFrom(address from,address to,uint256 id) external {require(msg.sender==from && ownerOf[id]==from && to!=address(0));ownerOf[id]=to;emit Transfer(from,to,id);}
}
contract TestSwap {
 TestToken public input; TestToken public output;
 constructor(address a,address b){input=TestToken(a);output=TestToken(b);output.mint(address(this),1000 ether);}
 function swap(uint256 amount,uint256 minimum,address recipient) external {require(amount>=minimum);require(input.transferFrom(msg.sender,address(this),amount));require(output.transfer(recipient,amount));}
}`;
async function bridge(transaction, name, editedApprovalAmount) {
  return new Promise((resolve, reject) => {
    const proc = spawn(process.env.OATH_WC_TX_BRIDGE, [], { stdio: ['pipe','pipe','pipe'] });
    let output = ''; let err = '';
    proc.stdout.on('data', d => { output += d; });
    proc.stderr.on('data', d => { err += d; });
    proc.on('error', () => reject(Error('bridge launch')));
    proc.on('exit', code => { if (code) { if (/^Sepolia bridge failed: [A-Za-z0-9_(), -]+\n$/.test(err)) process.stdout.write(err); reject(Error('bridge failed')); } else { try { resolve(JSON.parse(output)); } catch { reject(Error('bridge output')); } } });
    proc.stdin.end(JSON.stringify({keyFile: '/tmp/oath-evm-send-testnet-fixture.json', transaction, editedApprovalAmount, journal: root + '/' + name + '.journal.json'}));
  });
}
(async () => {
  if (!process.env.OATH_WC_TX_BRIDGE) throw Error('configuration');
  const provider = new JsonRpcProvider('https://ethereum-sepolia-rpc.publicnode.com', 11155111, {staticNetwork: true, cacheTimeout: -1});
  provider.pollingInterval = 1500;
  if (BigInt(await provider.send('eth_chainId', [])) !== 11155111n) throw Error('wrong network');
  const fixture = JSON.parse(fs.readFileSync('/tmp/oath-evm-send-testnet-fixture.json'));
  const wallet = new Wallet(fixture.privateKey, provider);
  if (wallet.address.toLowerCase() !== '0x06b40f932ef96df1dd115040f1d2cdfd7f16d0ef') throw Error('wrong test wallet');
  // Public cryptographic vector addresses can already have delegated contract
  // code on a shared testnet. A fresh, isolated recipient makes balance deltas
  // meaningful and avoids another user's/bot's existing account behavior.
  const recipient = state.recipient ?? Wallet.createRandom().address;
  state.recipient = recipient; save();
  if (await provider.getCode(recipient) !== '0x') throw Error('recipient has code');
  const compiled = JSON.parse(solc.compile(JSON.stringify({language:'Solidity',sources:{'Fixture.sol':{content:source}},settings:{optimizer:{enabled:true,runs:200},evmVersion:'paris',outputSelection:{'*':{'*':['abi','evm.bytecode.object']}}}})));
  if (compiled.errors?.some(e => e.severity === 'error')) throw Error('fixture compilation');
  async function deploy(name,args=[]) {
    if(state.deployments[name]) return state.deployments[name].address;
    stage = 'deploy ' + name;
    const type = name.startsWith('token') ? 'TestToken' : name === 'nft' ? 'TestNFT' : 'TestSwap';
    const spec=compiled.contracts['Fixture.sol'][type];
    const factory=new ContractFactory(spec.abi,spec.evm.bytecode.object,wallet);
    const data=await factory.getDeployTransaction(...args);
    const gas=await provider.estimateGas({...data,from:wallet.address});
    const fee=await provider.getFeeData();
    if (!fee.maxFeePerGas || gas*fee.maxFeePerGas > parseEther('0.005')) throw Error('test budget');
    const contract=await factory.deploy(...args,{nonce:await provider.getTransactionCount(wallet.address,'pending'),gasLimit:gas*12n/10n,maxFeePerGas:fee.maxFeePerGas,maxPriorityFeePerGas:fee.maxPriorityFeePerGas});
    const receipt=await contract.deploymentTransaction().wait(1,120000);
    if(receipt.status!==1) throw Error('deployment');
    state.deployments[name]={address:await contract.getAddress(),hash:receipt.hash};save();
    process.stdout.write('PASS fixture deployment: '+name+'\n');
    return state.deployments[name].address;
  }
  const a=await deploy('tokenA'), b=await deploy('tokenB'), nft=await deploy('nft'), swap=await deploy('swap',[a,b]);
  const tokenABI=compiled.contracts['Fixture.sol'].TestToken.abi;
  const tokenA=new Contract(a,tokenABI,provider),tokenB=new Contract(b,tokenABI,provider);
  const nftContract=new Contract(nft,compiled.contracts['Fixture.sol'].TestNFT.abi,provider);
  const swapInterface=new Interface(compiled.contracts['Fixture.sol'].TestSwap.abi);
  async function check(name,to,data,value,verify,editedApprovalAmount) {
    if(state.checks.some(c=>c.name===name)) return;
    stage=name;
    if(BigInt(await provider.send('eth_chainId',[]))!==11155111n)throw Error('network changed');
    const result=await bridge({from:wallet.address,to,data,value:toQuantity(value)},name,editedApprovalAmount);
    // Save the public hash before waiting so a timeout can be reconciled safely.
    state.inFlight={name,hash:result.hash};save();
    const receipt=await provider.waitForTransaction(result.hash,1,120000);
    if(!receipt || receipt.status!==1)throw Error('receipt rejected');
    await verify(receipt);
    state.checks.push({name,...result,receiptStatus:receipt.status,blockNumber:receipt.blockNumber,stateEffectVerified:true});
    delete state.inFlight;save();
    process.stdout.write('PASS '+name+': '+result.hash+'; broadcast '+result.submissionSeconds.toFixed(3)+'s; receipt and state effect verified\n');
  }
  // Never retry an unknown broadcast with a new nonce automatically.
  if(state.inFlight) throw Error('reconcile existing in-flight transaction before retry');
  if (process.env.OATH_WC_EDIT_APPROVAL === '1') {
    const edited = parseEther('1.25');
    await check('edited-token-approval',a,tokenA.interface.encodeFunctionData('approve',[swap,(1n<<256n)-1n]),0n,
      async receipt=>{if(await tokenA.allowance(wallet.address,swap,{blockTag:receipt.blockNumber})!==edited)throw Error('edited allowance');},String(edited));
    await check('edited-approval-removal',a,tokenA.interface.encodeFunctionData('approve',[swap,0]),0n,
      async receipt=>{if(await tokenA.allowance(wallet.address,swap,{blockTag:receipt.blockNumber})!==0n)throw Error('revocation');});
    clearTimeout(timer);provider.destroy();return;
  }
  const beforeNative=await provider.getBalance(recipient);
  await check('native-send',recipient,'0x',10000000000000n,async()=>{if(await provider.getBalance(recipient)!==beforeNative+10000000000000n)throw Error('native delta');});
  await check('token-approval',a,tokenA.interface.encodeFunctionData('approve',[swap,parseEther('100')]),0n,async()=>{if(await tokenA.allowance(wallet.address,swap)!==parseEther('100'))throw Error('allowance');});
  const beforeA=await tokenA.balanceOf(wallet.address),beforeB=await tokenB.balanceOf(recipient);
  await check('fixture-swap',swap,swapInterface.encodeFunctionData('swap',[parseEther('10'),parseEther('10'),recipient]),0n,async()=>{if(await tokenA.balanceOf(wallet.address)!==beforeA-parseEther('10') || await tokenB.balanceOf(recipient)!==beforeB+parseEther('10'))throw Error('swap balances');});
  const beforeToken=await tokenA.balanceOf(recipient);
  await check('token-send',a,tokenA.interface.encodeFunctionData('transfer',[recipient,parseEther('3')]),0n,async()=>{if(await tokenA.balanceOf(recipient)!==beforeToken+parseEther('3'))throw Error('token delta');});
  await check('nft-send',nft,nftContract.interface.encodeFunctionData('safeTransferFrom',[wallet.address,recipient,7]),0n,async()=>{if((await nftContract.ownerOf(7)).toLowerCase()!==recipient.toLowerCase())throw Error('NFT owner');});
  await check('approval-removal',a,tokenA.interface.encodeFunctionData('approve',[swap,0]),0n,async()=>{if(await tokenA.allowance(wallet.address,swap)!==0n)throw Error('revocation');});
  state.completedAt=new Date().toISOString();state.evidenceScope='Production Swift parser/quote/simulation/signature/broadcast, independently verified receipts and state. Fixture swap, not live DEX liquidity. Native relay and app authentication are separate tests.';save();
  clearTimeout(timer);provider.destroy();
  process.stdout.write('PASS: all six production-core Sepolia transaction checks. Public evidence: '+statePath+'\n');
})().catch(()=>{clearTimeout(timer);process.stdout.write('FAIL: isolated Sepolia check at '+stage+'; no private error data emitted.\n');process.exitCode=1;setTimeout(()=>process.exit(1),100);});
