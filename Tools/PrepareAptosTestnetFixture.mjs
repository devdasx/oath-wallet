// @aptos-labs/ts-sdk 7.5.0; Aptos CLI 9.6+. Isolated TESTNET keys only.
import fs from 'node:fs';import path from 'node:path';import os from 'node:os';
import {createRequire} from 'node:module';import {execFileSync} from 'node:child_process';
const require=createRequire(process.env.OATH_APTOS_SDK_ROOT ? process.env.OATH_APTOS_SDK_ROOT+'/package.json' : import.meta.url);
const {Account,Ed25519PrivateKey}=require('@aptos-labs/ts-sdk');
const fixture='/tmp/oath-aptos-testnet-fixture.json',base='https://api.testnet.aptoslabs.com/v1';
let stage='fixture';
try {
 let f;
 if(fs.existsSync(fixture)) f=JSON.parse(fs.readFileSync(fixture));
 else {
  const a=Account.fromPrivateKey({privateKey:Ed25519PrivateKey.generate(),legacy:true});
  const b=Account.fromPrivateKey({privateKey:Ed25519PrivateKey.generate(),legacy:true});
  f={sender:a.accountAddress.toStringLong(),privateKey:a.privateKey.toString(),recipient:b.accountAddress.toStringLong(),recipientKey:b.privateKey.toString()};
 }
 const save=()=>{fs.writeFileSync(fixture,JSON.stringify(f),{mode:0o600});fs.chmodSync(fixture,0o600)};save();
 if(!process.argv.includes('--publish')) {
  console.log('Fund this isolated address with free TESTNET APT at https://aptos.dev/network/faucet:',f.sender);
  console.log('Then rerun with --publish. Private fixture saved with mode 0600.');
 } else {
  stage='network';const root=await (await fetch(base)).json();if(root.chain_id!==2)throw Error('Wrong network');
  const view=async fn=>{const r=await fetch(base+'/view',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({function:fn,type_arguments:[],arguments:[]})});return r.ok ? r.json():null};
  let metadata=await view(f.sender+'::test_tokens::metadata');
  if(!metadata) {
   stage='compile_publish';const work=fs.mkdtempSync(path.join(os.tmpdir(),'oath-aptos-fixture-'));
   try {
    const source=path.join(import.meta.dirname,'AptosTestTokens');fs.cpSync(source,work,{recursive:true,filter:p=>!path.basename(p).startsWith('._')});
    let manifest=fs.readFileSync(path.join(work,'Move.toml'),'utf8').replace('oath_test = "_"','oath_test = "'+f.sender+'"');
    if(process.env.OATH_APTOS_FRAMEWORK_ROOT) manifest=manifest.slice(0,manifest.indexOf('[dependencies.AptosFramework]'))+'[dependencies.AptosFramework]\nlocal = '+JSON.stringify(path.join(process.env.OATH_APTOS_FRAMEWORK_ROOT,'aptos-framework'))+'\n';
    fs.writeFileSync(path.join(work,'Move.toml'),manifest);
    const keyFile=path.join(work,'key');fs.writeFileSync(keyFile,f.privateKey.replace('ed25519-priv-',''),{mode:0o600});
    execFileSync(process.env.OATH_APTOS_CLI ?? 'aptos',['move','publish','--package-dir',work,'--private-key-file',keyFile,'--url',base,'--assume-yes'],{stdio:'pipe',timeout:180000});
   } finally { fs.rmSync(work,{recursive:true,force:true}) }
   stage='metadata';metadata=await view(f.sender+'::test_tokens::metadata');
  }
  if(!metadata?.[0])throw Error('Missing metadata');
  f.coin=f.sender+'::test_tokens::TestCoin';f.fa=metadata[0];save();
  console.log('APTOS_TESTNET_FIXTURE_READY coin=true fa=true; no secrets printed.');
 }
} catch { console.error('Aptos testnet fixture failed at '+stage+'; secret-bearing output suppressed.');process.exitCode=1 }
