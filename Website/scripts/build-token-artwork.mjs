import {readFile,writeFile,mkdir,rm} from 'node:fs/promises';
import {gunzipSync} from 'node:zlib';
import {artworkSnapshot,attachArtwork} from './token-artwork.mjs';
const root = new URL('../',import.meta.url), snapshot = await artworkSnapshot();
const source = JSON.parse(gunzipSync(await readFile(new URL('content/tokens/source.json.gz',root))));
const directory = new URL('public/token-artwork-data/',root);
await rm(directory,{recursive:true,force:true});
await mkdir(new URL(snapshot.version+'/',directory),{recursive:true});
const shards = {};
for (const a of attachArtwork(source.entries,snapshot)) {
  if (!a.artwork) continue;
  const key = a.artwork.split('/').at(-1);
  (shards[key.slice(0,2)] ??= {})[key] = {source:snapshot.images[a.network+':'+a.reference],initials:Array.from(a.symbol).slice(0,2).join('')};
}
for(const [shard,data] of Object.entries(shards)) await writeFile(new URL(snapshot.version+'/'+shard+'.json',directory),JSON.stringify(data));
const manifest={format:1,version:snapshot.version,prefix:'/token-artwork-data/'+snapshot.version,entries:Object.keys(snapshot.images).length,reviewed:snapshot.reviewed,networks:snapshot.networks};
await writeFile(new URL('src/artwork-manifest.json',root),JSON.stringify(manifest,null,2)+'\n');
console.log(`Built artwork for ${manifest.entries} exact catalog entries; unresolved images retain initials.`);
