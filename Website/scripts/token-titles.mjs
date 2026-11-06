import {tokenPageTitle} from '../src/token-titles.js';

const normalized=title=>title.normalize('NFC').replace(/\s+/g,' ').toLocaleLowerCase('en');
const groupsFor=(entries,title)=>{
  const groups=new Map();
  for(const entry of entries){const key=normalized(title(entry));if(!groups.has(key))groups.set(key,[]);groups.get(key).push(entry);}
  return [...groups.values()];
};
export function qualifyTokenTitles(rows,networks) {
  const result=rows.map(({titleQualifier,...row})=>({...row}));
  const byNetwork=new Map(networks.map(n=>[n.id,n]));
  const title=row=>tokenPageTitle(row,byNetwork.get(row.network));
  for(const group of groupsFor(result,title)){
    if(group.length<2)continue;
    // Match public identifiers without inventing an issuer or a token name.
    // Grow the displayed ends until every reference in this group is distinct.
    let width=6,labels;
    do{
      labels=group.map(row=>{const ref=Array.from(row.reference);return ref.length<=width*2?row.reference:ref.slice(0,width).join('')+'…'+ref.slice(-width).join('');});
      width+=2;
    }while(new Set(labels.map(normalized)).size!==group.length&&width<=4096);
    if(new Set(labels.map(normalized)).size!==group.length)throw Error('Indistinguishable token title identities');
    group.forEach((row,i)=>{row.titleQualifier=labels[i];});
  }
  if(groupsFor(result,title).some(g=>g.length>1))throw Error('Duplicate token titles after identity qualification');
  return result;
}

export function qualifyOverviewTitles(coins) {
  const hubs=coins.filter(c=>c.assets.length>1);
  for(const group of groupsFor(hubs,coin=>tokenPageTitle(coin))){
    if(group.length>1)for(const coin of group)coin.titleQualifier=coin.coinID;
  }
  if(groupsFor(hubs,coin=>tokenPageTitle(coin)).some(g=>g.length>1))throw Error('Duplicate asset overview titles');
}
