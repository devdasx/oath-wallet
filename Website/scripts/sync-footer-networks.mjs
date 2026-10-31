import {readFile,writeFile} from 'node:fs/promises';
import catalog from '../content/networks.json' with {type:'json'};
const file=new URL('../public/Oath Footer.dc.html',import.meta.url);
const source=await readFile(file,'utf8');
const marker=/\/\* NETWORK_CATALOG_START \*\/[\s\S]*?\/\* NETWORK_CATALOG_END \*\//;
if(!marker.test(source))throw Error('Missing footer network catalog marker');
const links=catalog.networks.map(({name,slug,icon})=>({name,href:`https://oathwallet.org/networks/${slug}`,icon}));
await writeFile(file,source.replace(marker,`/* NETWORK_CATALOG_START */ ${JSON.stringify(links)} /* NETWORK_CATALOG_END */`));
console.log(`Synced ${links.length} footer network links from the app-reviewed catalog.`);
