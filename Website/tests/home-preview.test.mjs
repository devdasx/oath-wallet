import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {runInNewContext} from 'node:vm';

test('home preview uses the requested synthetic portfolio and app artwork',async()=>{
 const source=await readFile(new URL('../public/Oath App Home.dc.html',import.meta.url),'utf8');
 const script=source.match(/<script type="text\/x-dc"[^>]*>([\s\S]*?)<\/script>/)[1];
 const values=runInNewContext(script+';new Component().renderVals()', {DCLogic:class{},React:{createRef:()=>({current:null})}});
 assert.equal(values.assets.length,5);
 assert.match(source,/font-family:'SF Pro Rounded',ui-rounded/);
 assert.match(source,/background:#244DE0 url\('\/assets\/home-preview\/cobalt.jpg'\)/);
 assert.ok((await readFile(new URL('../public/assets/home-preview/cobalt.jpg',import.meta.url))).length>0);
 assert.match(source,/font-variant-numeric:tabular-nums/);
 assert.doesNotMatch(source,/Instrument Sans/);
 assert.equal(values.assets.reduce((sum,a)=>sum+Math.round(Number(a.val.replace(/[$,]/g,''))*1000),0),1259301765);
 assert.match(source,/>\$1,259,301\.765</);
 assert.doesNotMatch(source,/Markets|Trending|Pinned Assets|31,509/);
 for(const asset of values.assets)assert.ok((await readFile(new URL('../public'+asset.icon,import.meta.url))).length>0);
 const home=await readFile(new URL('../public/index.html',import.meta.url),'utf8');
 assert.match(home,/aspect-ratio:440\/956/);
});
