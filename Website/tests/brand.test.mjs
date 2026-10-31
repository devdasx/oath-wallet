import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import sharp from 'sharp';
import {brandVersion,logoUrl,faviconUrl} from '../src/brand.js';
import {brandUrls} from '../scripts/brand-urls.mjs';
const root=new URL('../public/',import.meta.url);
test('shared logo and favicon aliases match the master and its cache revision',async()=>{
 const master=await readFile(new URL('../content/brand/oath-logo.svg',import.meta.url));
 assert.equal(brandVersion,createHash('sha256').update(master).digest('hex').slice(0,12));
 for(const name of ['assets/brand/oath-logo.svg','assets/brand/oath-mark-dark.svg','assets/brand/oath-mark-light.svg','favicon.svg'])assert.deepEqual(await readFile(new URL(name,root)),master,name);
 assert.equal(brandUrls('/assets/brand/oath-mark-light.svg?v=old'),logoUrl);
 assert.equal(brandUrls('/favicon.svg?v=old'),faviconUrl);
 assert.equal(brandUrls(brandUrls(logoUrl)),logoUrl);
});
test('raster logo formats derive from the master with transparent rounded corners',async()=>{
 const master=await readFile(new URL('../content/brand/oath-logo.svg',import.meta.url));
 for(const [name,size] of [['favicon-16.png',16],['favicon-32.png',32],['apple-touch-icon.png',180],['icon-192.png',192],['icon-512.png',512],['wallet-logo.png',512]]){
  const actual=await sharp(await readFile(new URL(name,root))).ensureAlpha().raw().toBuffer();
  const expected=await sharp(master).resize(size,size).ensureAlpha().raw().toBuffer();
  assert.deepEqual(actual,expected,name);assert.equal(actual[3],0,name+' corner');
 }
});
