// Creates an isolated, disposable THORNode test chain. Never uses an app wallet.
// Requires Docker and @cosmjs/proto-signing + WalletCore 4.8.4 in an external SDK directory.
// Env: OATH_THOR_SDK_ROOT, WALLET_CORE_NODE_MODULE. Stops if the container name exists.
const fs=require('fs'),os=require('os'),path=require('path'),crypto=require('crypto');
const {execFileSync}=require('child_process'),{createRequire}=require('module');
const requireSDK=createRequire(path.join(process.env.OATH_THOR_SDK_ROOT||process.cwd(),'package.json'));
const {DirectSecp256k1Wallet}=requireSDK('@cosmjs/proto-signing');
const {initWasm}=require(process.env.WALLET_CORE_NODE_MODULE||'@trustwallet/wallet-core');
const image='registry.gitlab.com/thorchain/thornode@sha256:bc5961057911c516ed365367369023a6077900c6ac93019dbf8b9abd4f80a0fb';
const name='oath-thorchain-send-test';
function docker(...args){return execFileSync('docker',args,{encoding:'utf8',maxBuffer:4*1024*1024});}
(async()=>{
 const existing=docker('ps','-a','--filter','name=^/'+name+'$','--format','{{.Names}}').trim();
 if(existing)throw Error('The isolated test container already exists; preserve it or remove it explicitly before creating another.');
 const folder=fs.mkdtempSync(path.join(os.tmpdir(),'oath-thorchain-test-'));fs.chmodSync(folder,0o700);
 const privateKey=crypto.randomBytes(32),other=crypto.randomBytes(32);
 const sender=(await (await DirectSecp256k1Wallet.fromKey(privateKey,'tthor')).getAccounts())[0];
 const recipient=(await (await DirectSecp256k1Wallet.fromKey(other,'tthor')).getAccounts())[0];
 fs.writeFileSync(path.join(folder,'fixture.json'),JSON.stringify({privateKey:privateKey.toString('hex'),publicKey:Buffer.from(sender.pubkey).toString('hex'),sender:sender.address,recipient:recipient.address}),{mode:0o600});
 const core=await initWasm(),validator=core.HDWallet.create(256,'');
 fs.writeFileSync(path.join(folder,'validator-seed'),validator.mnemonic(),{mode:0o600});validator.delete();
 let script=docker('run','--rm','--platform','linux/amd64','--entrypoint','cat',image,'/scripts/genesis.sh');
 const original='  echo "Genesis content"\n  cat ~/.thornode/config/genesis.json';
 if(!script.includes(original))throw Error('Unexpected pinned-image genesis format');
 const extra=`  add_account ${sender.address} rune 10000000000
  jq --arg ADDRESS '${sender.address}' '(.app_state.bank.balances[] | select(.address==$ADDRESS) | .coins) += [{"denom":"tcy","amount":"10000000000"},{"denom":"x/ruji","amount":"10000000000"},{"denom":"x/oath-test","amount":"100000000"}] | (.app_state.bank.balances[].coins) |= sort_by(.denom) | .app_state.bank.denom_metadata += [{"description":"Local test asset","denom_units":[{"denom":"x/oath-test","exponent":0,"aliases":[]},{"denom":"OATHTEST","exponent":6,"aliases":[]}],"base":"x/oath-test","display":"OATHTEST","name":"Oath test asset","symbol":"OATHTEST"}]' ~/.thornode/config/genesis.json >/tmp/oath-genesis.json
  mv /tmp/oath-genesis.json ~/.thornode/config/genesis.json`;
 script=script.replace(original,extra);fs.writeFileSync(path.join(folder,'genesis.sh'),script,{mode:0o700});
 docker('create','--name',name,'--platform','linux/amd64','-p','127.0.0.1:28657:26657','-p','127.0.0.1:28317:1317','-e','NET=mocknet','-e','CHAIN_ID=oath-thorchain-test-1','-e','SIGNER_NAME=thorchain','-e','SIGNER_PASSWD=oath-local-test-password','-e','SIGNER_SEED_PHRASE_FILE=/scripts/oath-validator-seed','-e','SKIP_EVM_DEPLOY=true','-e','THOR_BLOCK_TIME=1s','-e','HALT_CHURNING=1','--entrypoint','bash',image,'/scripts/oath-genesis.sh');
 docker('cp',path.join(folder,'genesis.sh'),name+':/scripts/oath-genesis.sh');
 docker('cp',path.join(folder,'validator-seed'),name+':/scripts/oath-validator-seed');docker('start',name);
 privateKey.fill(0);other.fill(0);
 console.log('Isolated THORNode starting. Test-only fixture path: '+path.join(folder,'fixture.json'));
 console.log('Wait for http://127.0.0.1:28657/status, then set OATH_THORCHAIN_SEND_FIXTURE to that file for ThorchainSendLiveTests.');
})().catch(error=>{console.error(error.message);process.exitCode=1});
