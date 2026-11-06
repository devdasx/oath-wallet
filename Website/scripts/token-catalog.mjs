import {createHash} from 'node:crypto';

export const digest = value => createHash('sha256').update(value).digest('hex');
export const identity = e => `${e.network}:${e.reference}`;
export const readLedger=value=>value.format===2?{format:1,coins:Object.fromEntries(value.coins),assets:Object.fromEntries(value.assets)}:value;
export const writeLedger=value=>({format:2,coins:Object.entries(value.coins),assets:Object.entries(value.assets)});
export const nativeAlias=e=>(e.network==='arc'&&e.reference.toLowerCase()==='0x3600000000000000000000000000000000000000')||(e.network==='celo'&&e.reference.toLowerCase()==='0x471ece3750da237f93b8e339c536989b8978a438');
const shapes={solana:/^[1-9A-HJ-NP-Za-km-z]{32,44}$/,tron:/^T[1-9A-HJ-NP-Za-km-z]{33}$/,ton:/^-?[0-9]+:[a-f0-9]{64}$/,
  stellar:/^(?:C[A-Z2-7]{55}|[a-zA-Z0-9]{1,12}[-:]G[A-Z2-7]{55})$/,xrpl:/^(?:[A-Za-z0-9]{3}|[A-Fa-f0-9]{40})\.r[1-9A-HJ-NP-Za-km-z]{24,34}$/,
  near:/^[a-z0-9]+(?:[._-][a-z0-9]+)*$/,polkadot:/^(?:assets:[0-9]+|foreign:.*)$/,thorchain:/^[a-zA-Z0-9/._:-]+$/,
  aptos:/^0x[a-f0-9]{1,64}(?:::[a-zA-Z_][a-zA-Z0-9_]*::[a-zA-Z_][a-zA-Z0-9_]*)?$/,sui:/^0x[a-f0-9]{1,64}::[a-zA-Z_][a-zA-Z0-9_]*::[a-zA-Z_][a-zA-Z0-9_]*$/};
export function validateSnapshot(source) {
  if(source.format!==1 || !/^[a-f0-9]{40}$/.test(source.revision) || !/^\d{4}-\d{2}-\d{2}$/.test(source.sourceDate)) throw Error('Invalid catalog provenance');
  if(!source.entries?.length || new Set(source.enabled).size!==source.enabled.length) throw Error('Invalid network catalog');
  const enabled=new Set(source.enabled), native=new Set(source.nativeOnly), seen=new Set();
  for(const e of source.entries) {
    for(const k of ['coinID','name','symbol','network','reference']) if(typeof e[k]!=='string'||!e[k].trim()||e[k].length>(k==='reference'?4096:300)||/[\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069]/.test(e[k])) throw Error(`Invalid ${k} in catalog`);
    if(!/^[a-z0-9-]{1,200}$/.test(e.coinID)||Buffer.byteLength(e.name)>256||Buffer.byteLength(e.symbol)>64||e.name.trim()!==e.name||e.symbol.trim()!==e.symbol)throw Error('Invalid app catalog metadata');
    if(!enabled.has(e.network)||native.has(e.network)||e.reference==='native'||nativeAlias(e)) throw Error('Unsupported token network or native representation');
    if(!(shapes[e.network]||/^0x[a-f0-9]{40}$/).test(e.reference)) throw Error('Malformed token identity: '+e.network);
    if(seen.has(identity(e))) throw Error('Duplicate network/token identity');
    seen.add(identity(e));
    if(e.decimals!=null && (!Number.isInteger(e.decimals)||e.decimals<0||e.decimals>255)) throw Error('Invalid token scale');
  }
  return source;
}
export function assignRoutes(source, previous={format:1,coins:{},assets:{}}) {
  // Keep removed identities in the ledger: a new contract cannot inherit an old URL.
  const ledger=structuredClone(previous), usedCoins=new Set(Object.values(ledger.coins)), usedPaths=new Set(Object.values(ledger.assets));
  if(ledger.format!==1 || usedPaths.size!==Object.keys(ledger.assets).length)throw Error('Invalid route ledger');
  if(Object.values(ledger.coins).some(s=>typeof s!=='string'||!/^[a-z0-9-]+$/.test(s))||Object.values(ledger.assets).some(s=>typeof s!=='string'||!/^\/tokens\/[a-z0-9-]+\/[a-z0-9-]+$/.test(s)))throw Error('Malformed route ledger');
  // A provider rename must be reviewed, rather than silently moving an existing identity
  // into another asset group. The accepted snapshot remains usable on failure.
  for(const e of source.entries){const path=ledger.assets[identity(e)];if(path && path.split('/')[2]!==ledger.coins[e.coinID])throw Error('Asset grouping changed; review identity migration before refresh');}
  const aliases={'tether':'usdt','usd-coin':'usdc'};
  for(const coin of [...new Set(source.entries.map(e=>e.coinID))].sort()) {
    if(Object.hasOwn(ledger.coins,coin)) continue;
    let slug=aliases[coin] || coin.toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'') || 'asset';
    if(usedCoins.has(slug) || (['usdt','usdc'].includes(slug)&&aliases[coin]!==slug)) slug+='-'+digest(coin).slice(0,12);
    if(usedCoins.has(slug)) throw Error('Token slug collision');
    ledger.coins[coin]=slug;usedCoins.add(slug);
  }
  const rows=source.entries.map(e=>{
    const key=identity(e), slug=ledger.coins[e.coinID];
    if(!ledger.assets[key]) {
      let tail=source.networks.find(n=>n.id===e.network)?.slug;
      if(!tail)throw Error('Missing website network');
      let path=`/tokens/${slug}/${tail}`;
      if(usedPaths.has(path))path+='-'+digest(key).slice(0,12);
      if(usedPaths.has(path))throw Error('Token path collision');
      ledger.assets[key]=path;usedPaths.add(path);
    }
    return {...e,slug,path:ledger.assets[key]};
  });
  return {ledger,rows};
}
