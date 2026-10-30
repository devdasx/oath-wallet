// Public deterministic test vectors. Never fund these published keys.
const fs=require('fs'),xrpl=require('xrpl');
const owner=xrpl.Wallet.fromEntropy(new Uint8Array(16).fill(71),{algorithm:xrpl.ECDSA.secp256k1});
const signers=[72,73,74].map(n=>xrpl.Wallet.fromEntropy(new Uint8Array(16).fill(n),{algorithm:xrpl.ECDSA.secp256k1}));
const {decodeAccountID}=require('ripple-address-codec');
signers.sort((a,b)=>Buffer.compare(decodeAccountID(a.address),decodeAccountID(b.address)));
const entries=signers.map(w=>({SignerEntry:{Account:w.address,SignerWeight:1}}));
const common={Flags:2147483648,Account:owner.address,Sequence:42,LastLedgerSequence:120,Fee:'36'};
const recipient='rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh';
const result={accountKey:owner.privateKey.slice(2),account:owner.address,keys:signers.map(w=>w.privateKey.slice(2)),signers:signers.map(w=>w.address),vectors:[]};
for(const kind of ['signerList','disableMaster','native','issued','mpt','trust','authorize']){
 let tx=kind==='signerList'?{...common,TransactionType:'SignerListSet',SignerQuorum:2,SignerEntries:entries}:kind==='disableMaster'?{...common,TransactionType:'AccountSet',SetFlag:4}:{...common,TransactionType:'Payment',Destination:recipient,DestinationTag:0,Amount:kind==='native'?'123456':kind==='issued'?{currency:'OAT',issuer:recipient,value:'1.25'}:{mpt_issuance_id:'000000010000000000000000000000000000000000000000',value:'123'}};
 if(kind==='trust')tx={...common,TransactionType:'TrustSet',Flags:2147614720,LimitAmount:{currency:'OAT',issuer:recipient,value:'1.25'}};
 if(kind==='authorize')tx={...common,TransactionType:'MPTokenAuthorize',MPTokenIssuanceID:'000000010000000000000000000000000000000000000000'};
 if(['issued','mpt'].includes(kind))tx.SendMax=tx.Amount;
 let blob;
 if(['signerList','disableMaster'].includes(kind))blob=owner.sign(tx).tx_blob;
 else blob=xrpl.multisign(signers.slice(0,2).map(w=>w.sign({...tx,SigningPubKey:''},true).tx_blob));
 result.vectors.push({kind,bytes:blob});
}
fs.writeFileSync(process.argv[2],JSON.stringify(result,null,2)+'\n');
