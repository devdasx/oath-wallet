import {readFile} from 'node:fs/promises';
import {gunzipSync} from 'node:zlib';
import {createHash} from 'node:crypto';
import {permittedArtworkURL} from '../src/token-artwork.js';
const hash = value => createHash('sha256').update(value).digest('hex');
export async function artworkSnapshot() {
  const bytes = await readFile(new URL('../content/tokens/artwork.json.gz', import.meta.url));
  const snapshot = JSON.parse(gunzipSync(bytes));
  const source = JSON.parse(gunzipSync(await readFile(new URL('../content/tokens/source.json.gz', import.meta.url))));
  if (snapshot.format !== 1 || snapshot.source_revision !== source.revision || snapshot.source_sha256 !== source.sha256) throw Error('Artwork snapshot must match the accepted released catalog');
  const identities = new Set(source.entries.map(a => a.network + ':' + a.reference));
  for (const [identity, url] of Object.entries(snapshot.images)) {
    if (!identities.has(identity) || !permittedArtworkURL(url)) throw Error('Unaccepted artwork identity or source');
  }
  const delivery = await Promise.all(['../src/artwork-route.js','../src/token-artwork.js'].map(path=>readFile(new URL(path,import.meta.url),'utf8')));
  return {...snapshot, version: hash(JSON.stringify(snapshot)+delivery.join('\n')).slice(0,16)};
}
export function attachArtwork(rows, snapshot) {
  return rows.map(asset => {
    const identity = asset.network + ':' + asset.reference, source = snapshot.images[identity];
    const key = source ? hash(identity + '\n' + source).slice(0,32) : null;
    const {artwork: previousArtwork, ...catalogAsset} = asset;
    return {...catalogAsset, ...(key ? {artwork:`/token-artwork/${snapshot.version}/${key}`} : {})};
  });
}
