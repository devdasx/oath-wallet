// npm dependency: tronweb@6.2.2. Generates only NEW disposable Nile keys.
// Never use a wallet recovery phrase/private key from the app for these tests.
const fs=require('fs'),{TronWeb}=require('tronweb');
(async()=>{
 const path=process.env.OATH_TRON_TESTNET_FIXTURE;
 if(!path)throw Error('Missing fixture path');
 if(fs.existsSync(path))throw Error('Refusing to replace an existing fixture');
 const sender=await TronWeb.createAccount(),recipient=await TronWeb.createAccount();
 fs.writeFileSync(path,JSON.stringify({network:'nile',key:sender.privateKey,sender:sender.address.base58,recipientKey:recipient.privateKey,recipient:recipient.address.base58}),{flag:'wx',mode:0o600});
 console.log('Fund this NEW Nile test address with faucet TRX, USDT and TRN: '+sender.address.base58);
})().catch(()=>{console.error('Fixture setup failed; no key material printed');process.exitCode=1;});
