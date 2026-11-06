// Offline public-fixture checks only. No wallet inputs, signing, RPC or live funds.
// Usage: node scripts/verify-migration-compatibility.mjs <released-checkout> <wallet-core-package-directory>
// Install @trustwallet/wallet-core@4.8.4 in a temporary directory, never in the website bundle.
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {createRequire} from 'node:module';
import {resolve,join} from 'node:path';
import catalog from '../content/wallet-migrations.json' with {type:'json'};
const [release,packageDir]=process.argv.slice(2).map(p=>resolve(p));
assert.ok(release&&packageDir,'Supply the released checkout and Wallet Core package directory');
assert.equal(execFileSync('git',['rev-parse','HEAD'],{cwd:release,encoding:'utf8'}).trim(),catalog.sourceCommit);
const pkg=JSON.parse(await readFile(join(packageDir,'package.json'),'utf8'));
assert.equal(pkg.name,'@trustwallet/wallet-core');assert.equal(pkg.version,'4.8.4');
const files=[
 'OathAtmosphere/Wallet/OathWalletEngine.swift',
 'OathAtmosphere/Wallet/OathPrivateKeyImport.swift',
 'OathAtmosphere/Wallet/OathSolanaWallet.swift',
 'OathAtmosphere/Wallet/OathBitcoinWallet.swift',
 'OathAtmosphere/Import/OathRecoveryPhraseScreen.swift',
 'OathAtmosphere/Home/OathWalletSheets.swift',
 'OathAtmosphere/Wallet/OathPassphraseWalletModel.swift',
 'Packages/OathDatabase/Sources/OathDatabase/SolanaReceive.swift',
 'Packages/WalletCore/registry-4.8.4.json',
 'Packages/OathBitcoin/Sources/OathBitcoin/ElectrumBitcoin.swift',
 'Packages/OathBitcoin/Sources/OathBitcoin/BitcoinKeys.swift',
 'Packages/OathBitcoin/Sources/OathBitcoin/ElectrumMnemonic.swift',
 'Packages/OathBitcoin/Tests/OathBitcoinTests/ElectrumMnemonicTests.swift',
 'Packages/OathBitcoin/Tests/OathBitcoinTests/Fixtures/electrum-reference.json',
 'LocalizationTests/OathWalletEngineTests.swift'
];
const sources=await Promise.all(files.map(async path=>({path,sha256:createHash('sha256').update(await readFile(join(release,path))).digest('hex')})));
const read=p=>readFile(join(release,p),'utf8');
const engine=await read(files[0]);
const fixtures=await read('LocalizationTests/OathWalletEngineTests.swift');
// Existing, explicitly public upstream fixtures. Never include recovery material in reports.
const phrase=fixtures.match(/private let fixture = "([^"]+)"/)[1];
const upstreamPhrase=fixtures.match(/let upstreamPhrase = "([^"]+)"/)[1];
const registry=JSON.parse(await read('Packages/WalletCore/registry-4.8.4.json'));
const require=createRequire(import.meta.url);
const {HDWallet,CoinType,CoinTypeExt,PrivateKey}=await require(packageDir).initWasm();
const base=HDWallet.createWithMnemonic(phrase,''), extended=HDWallet.createWithMnemonic(upstreamPhrase,'TREZOR');
const checks=[];
function check(label,operation){operation();checks.push(label);}
function address(wallet,coin,path){const key=wallet.getKey(coin,path);try{return CoinTypeExt.deriveAddress(coin,key);}finally{key.delete();}}
const paths={ethereum:"m/44'/60'/0'/0/0",bitcoin:"m/84'/0'/0'/0/0",tron:"m/44'/195'/0'/0/0"};
for(const [name,path] of Object.entries(paths)){
 check(name+': released default matches upstream registry',()=>{assert.ok(engine.includes('"'+path+'"'));assert.equal(registry.find(c=>c.id===name).derivation[0].path,path);});
 check(name+': explicit path reproduces default address',()=>assert.equal(address(base,CoinType[name],path),base.getAddressForCoin(CoinType[name])));
 const expected={ethereum:'0x27Ef5cDBe01777D62438AfFeb695e33fC2335979',bitcoin:'bc1qumwjg8danv2vm29lp5swdux4r60ezptzz7ce85',tron:'THJrqfbBhoB1vX97da6S6nXWkafCxpyCNB'}[name];
 check(name+': published passphrase vector',()=>{assert.ok(fixtures.includes(expected));assert.equal(address(extended,CoinType[name],path),expected);});
 check(name+': additional passphrase isolates the account',()=>{const different=HDWallet.createWithMnemonic(phrase,'TREZOR');try{assert.notEqual(address(different,CoinType[name],path),address(base,CoinType[name],path));}finally{different.delete();}});
}
const first=address(base,CoinType.ethereum,paths.ethereum);
check('MetaMask: first ordinary EVM address',()=>assert.equal(first,'0x9858EfFD232B4033E47d90003D41EC34EcaEda94'));
const secondPath="m/44'/60'/0'/0/1",second=address(base,CoinType.ethereum,secondPath);
check('MetaMask: second account is distinct',()=>{assert.equal(second,'0x6Fac4D18c912343BF86fa7049364Dd4E424Ab9C0');assert.notEqual(first,second);});
check('MetaMask: individual key reproduces second account',()=>{const key=base.getKey(CoinType.ethereum,secondPath);let bytes;try{bytes=key.data();const imported=PrivateKey.createWithData(bytes);try{assert.equal(CoinTypeExt.deriveAddress(CoinType.ethereum,imported),second);}finally{imported.delete();}}finally{bytes?.fill(0);key.delete();}});
const solana=await read('Packages/OathDatabase/Sources/OathDatabase/SolanaReceive.swift');
check('Solana: released app exposes both explicit account conventions',()=>{assert.ok(solana.includes('case phantom, trustWallet'));assert.ok(solana.includes('return self == .phantom ? account + "/0\'" : account'));assert.ok((engine).includes('"m/44\'/501\'/0\'/0\'"'));});
check('Solana: Trust Wallet path reproduces upstream default',()=>{assert.equal(registry.find(c=>c.id==='solana').derivation[0].path,"m/44'/501'/0'");assert.equal(address(base,CoinType.solana,"m/44'/501'/0'"),base.getAddressForCoin(CoinType.solana));});
check('Solana: Phantom and Trust Wallet paths are distinct',()=>{assert.equal(address(base,CoinType.solana,"m/44'/501'/0'/0'"),'HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk');assert.notEqual(address(base,CoinType.solana,"m/44'/501'/0'"),address(base,CoinType.solana,"m/44'/501'/0'/0'"));});
base.delete();extended.delete();
const electrum=JSON.parse(await read('Packages/OathBitcoin/Tests/OathBitcoinTests/Fixtures/electrum-reference.json'));
const report={checkedAt:new Date().toISOString(),version:catalog.version,build:catalog.build,sourceCommit:catalog.sourceCommit,walletCore:pkg.version,method:'Released-source path comparison plus upstream Wallet Core WASM public fixtures. This does not execute the iOS app importer.',checks,sources,electrumFixtureInventory:{fixtures:electrum.length,addresses:electrum.reduce((n,v)=>n+v.addresses.length,0),kinds:[...new Set(electrum.map(v=>v.kind))].sort()},notPerformed:['iOS runtime or simulator tests','physical device tests','live funded transfers','all source-wallet versions or configurations']};
const output=new URL('../Reports/wallet-migrations/',import.meta.url);await mkdir(output,{recursive:true});
await writeFile(new URL('compatibility.json',output),JSON.stringify(report,null,2)+'\n');
console.log(`${checks.length} offline derivation checks passed; source hashes and limits recorded.`);
