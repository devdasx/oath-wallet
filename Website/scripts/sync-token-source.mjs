// Explicit, release-pinned refresh. Never fetch token metadata during page requests.
import {execFileSync} from 'node:child_process';
import {readFile, writeFile, mkdir, rename} from 'node:fs/promises';
import {gzipSync,gunzipSync} from 'node:zlib';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {validateSnapshot,assignRoutes,nativeAlias,readLedger} from './token-catalog.mjs';

const root = new URL('../../', import.meta.url);
const evidence = JSON.parse(await readFile(new URL('Website/content/release-evidence.json', root)));
const distribution = JSON.parse(await readFile(new URL(`releases/${evidence.version}-distribution.json`, root)));
if (distribution.source_commit !== evidence.source_commit || distribution.status !== 'READY_FOR_DISTRIBUTION') throw Error('A confirmed distribution record matching the source evidence is required.');
const revision = evidence.source_commit;
const read = path => execFileSync('git', ['show', `${revision}:${path}`], {cwd:fileURLToPath(root), maxBuffer:20*1024*1024});
const seedPath = 'Packages/OathAnkr/Sources/OathAnkr/Resources/TokenDiscoverySeed.json';
const registryPath = 'OathAtmosphere/Import/OathImportCatalog.swift';
const raw = read(seedPath), registry = read(registryPath).toString();
const declaration = registry.split('public enum OathImportChain:')[1]?.split('public var id:')[0];
if (!declaration) throw Error('Unrecognized network registry; review its extraction.');
const declared = [...declaration.matchAll(/^\s*case ([a-zA-Z, ]+)$/gm)].flatMap(m=>m[1].split(',').map(s=>s.trim()));
const enabledExpression = /public var isEnabled: Bool \{\s*([^}]+)\}/.exec(registry)?.[1].trim();
if (enabledExpression !== 'self != .cronos' && !(enabledExpression===undefined && !declared.includes('cronos'))) throw Error('Network availability changed; review the released registry before refreshing.');
const enabled = declared.filter(n=>enabledExpression!=='self != .cronos'||n!=='cronos');
const nativeOnly = ['bitcoin','bitcoincash','dogecoin','litecoin'];
const seed = JSON.parse(raw);
const featured = JSON.parse(read('OathApp/Resources/ReceiveAssets.json')).networks;
const sourceDate = execFileSync('git',['log','-1','--format=%cs',revision,'--',seedPath],{cwd:fileURLToPath(root)}).toString().trim();
const snapshot = {format:1, version:evidence.version, build:evidence.build, revision, sourceDate,
  sha256:createHash('sha256').update(raw).digest('hex'), enabled, nativeOnly, featured,
  rawCount:seed.entries.length,excludedNativeAliases:seed.entries.filter(nativeAlias).map(e=>e.network+':'+e.reference),entries:seed.entries.filter(e=>!nativeAlias(e))};
validateSnapshot(snapshot);
let accepted;
try{accepted=JSON.parse(gunzipSync(await readFile(new URL('Website/content/tokens/source.json.gz',root))));}catch(e){if(e.code!=='ENOENT')throw e;}
snapshot.updatedDate=accepted?.sha256===snapshot.sha256&&accepted?.revision===revision&&accepted?.updatedDate?accepted.updatedDate:new Date().toISOString().slice(0,10);
const networkCatalog=JSON.parse(await readFile(new URL('Website/content/networks.json',root)));
let ledger;try{ledger=readLedger(JSON.parse(await readFile(new URL('Website/content/tokens/routes.json',root))));}catch(e){if(e.code!=='ENOENT')throw e;}
assignRoutes({...snapshot,networks:networkCatalog.networks.filter(n=>enabled.includes(n.id))},ledger);
const destination = new URL('Website/content/tokens/',root);
await mkdir(destination,{recursive:true});
const bytes = gzipSync(JSON.stringify(snapshot),{level:9,mtime:0});
const target = new URL('source.json.gz',destination), temporary = new URL('source.json.gz.next',destination);
await writeFile(temporary,bytes); await rename(temporary,target);
console.log(`Pinned ${snapshot.entries.length} entries to Oath ${snapshot.version} (${snapshot.build}), ${revision}.`);
