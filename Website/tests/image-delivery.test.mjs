import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {runInNewContext} from 'node:vm';
import sharp from 'sharp';
const root=new URL('../public/',import.meta.url);
test('responsive icons retain the source pixels at each target size and reduce transferred bytes',async()=>{
 let original=0,delivered=0,count=0;
 for(const directory of ['assets/networks/','assets/home-preview/']){
  for(const name of await readdir(new URL(directory,root))){
   if(!(directory.includes('networks')?/\.webp$/:/\.png$/).test(name))continue;
   const source=await readFile(new URL(directory+name,root)); original+=source.length;
   for(const width of [56,112,168]){
    const bytes=await readFile(new URL(`${directory}responsive/${name.replace(/\.[^.]+$/,'')}-${width}.webp`,root));
    const expected=await sharp(source).resize(width,width,{fit:'inside',withoutEnlargement:true}).ensureAlpha().raw().toBuffer();
    const actual=await sharp(bytes).ensureAlpha().raw().toBuffer();
    // WebP may discard RGB under fully transparent pixels; visible pixels are exact.
    assert.equal(actual.length,expected.length);
    for(let i=0;i<actual.length;i+=4){assert.equal(actual[i+3],expected[i+3]);if(expected[i+3])assert.deepEqual(actual.subarray(i,i+3),expected.subarray(i,i+3));}
    if(width===168)delivered+=bytes.length;
   }
   count++;
  }
 }
 assert.equal(count,47); assert.ok(delivered<original*.25,`${delivered} vs ${original}`);
});
test('phone preview points to working density candidates without changing its presentation',async()=>{
 const source=await readFile(new URL('Oath App Home.dc.html',root),'utf8');
 const script=source.match(/<script type="text\/x-dc"[^>]*>([\s\S]*?)<\/script>/)[1];
 const values=runInNewContext(script+';new Component().renderVals()', {DCLogic:class{},React:{createRef:()=>({current:null})}});
 assert.match(source,/srcset="{{ a.iconSet }}" sizes="40px"/);
 for(const asset of values.assets)for(const candidate of asset.iconSet.split(', ')){
  const [path,width]=candidate.split(' ');assert.ok(['56w','112w','168w'].includes(width));
  assert.ok((await readFile(new URL('.'+path,root))).length>0);
 }
 const home=await readFile(new URL('index.html',root),'utf8');
 assert.match(home,/<link rel="preload" as="image" href="\/assets\/home-preview\/cobalt.jpg" fetchpriority="high">/);
 assert.match(home,/class="network-card"[^]*?srcset="\/assets\/networks\/responsive\//);
});
