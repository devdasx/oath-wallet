import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {runInNewContext} from 'node:vm';
import sharp from 'sharp';
import {brandUrls} from '../scripts/brand-urls.mjs';
const root=new URL('../public/',import.meta.url),dir=new URL('assets/press/2026-10/',root);
test('press page works without hydration and every asset download is present',async()=>{
 const html=await readFile(new URL('press.html',root),'utf8');
 assert.equal((html.match(/<h1\b/g)||[]).length,1);assert.match(html,/<main id="main-content"/);
 assert.doesNotMatch(html,/<template|support\.js|oath-server-content/);
 assert.match(html,/oath-shared-header:start/);assert.match(html,/oath-shared-footer:start/);
 for(const id of ['assets','product','story','guidelines','permissions','contact','leadership'])assert.ok(html.includes(`id="${id}"`));
 const downloads=[...html.matchAll(/href="([^"#]+)" download/g)].map(m=>m[1]);assert.ok(downloads.length>=15);
 for(const href of downloads){const b=await readFile(new URL('.'+href.split('?')[0],root));assert.ok(b.length,href);}
 for(const text of ['Clear space','Minimum size','Editorial coverage','Impersonation','Brand rights'])assert.ok(html.includes(text));
 const sample='/assets/press/2026-10/oath-app-icon.svg?v=press-edition';assert.equal(brandUrls(sample),sample,'website brand aliases must not rewrite curated press assets');
});
test('complete ZIP is valid and its published assets match the manifest and checksum',async()=>{
 const manifest=JSON.parse(await readFile(new URL('manifest.json',dir),'utf8'));
 for(const item of manifest.files){const b=await readFile(new URL(item.name,dir));assert.equal(b.length,item.bytes);assert.equal(createHash('sha256').update(b).digest('hex'),item.sha256);}
 const zip=await readFile(new URL('oath-press-kit.zip',dir));const sum=await readFile(new URL('oath-press-kit.sha256',dir),'utf8');assert.ok(sum.startsWith(createHash('sha256').update(zip).digest('hex')));
 execFileSync('python3',['-c',`import zipfile,json,sys,pathlib,hashlib\np=pathlib.Path(sys.argv[1]);z=zipfile.ZipFile(p/'oath-press-kit.zip');assert z.testzip() is None\nnames=z.namelist();assert len(names)==len(set(names))\nfor n in names:\n assert n.startswith('Oath-Wallet-Press-Kit/') and '..' not in n\n assert z.read(n)==(p/n.split('/')[-1]).read_bytes()\nm=json.loads(z.read('Oath-Wallet-Press-Kit/manifest.json'));assert len(names)==len(m['files'])+2\nfor n in ['brand-guidelines.html','brand-guide.txt','press-facts.txt','README.txt']:\n assert 'oath' in z.read('Oath-Wallet-Press-Kit/'+n).decode().lower()`,dir.pathname]);
});
test('curated SVG marks preserve the master silhouette and PNG previews have advertised dimensions',async()=>{
 const master=await readFile(new URL('../content/press/oath-app-icon.svg',import.meta.url),'utf8');
 assert.equal(await readFile(new URL('oath-app-icon.svg',dir),'utf8'),master);
 const paths=[...master.matchAll(/\bd="([^"]+)"/g)].map(m=>m[1]);
 for(const tone of ['ink','white']){
  const svg=await readFile(new URL(`oath-mark-${tone}.svg`,dir),'utf8');assert.deepEqual([...svg.matchAll(/\bd="([^"]+)"/g)].map(m=>m[1]),paths);
  assert.doesNotMatch(svg,/<image|<script|<foreignObject|<metadata/);
  const raster=await sharp(Buffer.from(svg)).resize(1536).ensureAlpha().raw().toBuffer();const png=await sharp(await readFile(new URL(`oath-mark-${tone}.png`,dir))).ensureAlpha().raw().toBuffer();assert.deepEqual(raster,png);
 }
 for(const name of ['portfolio','market','receive']){const m=await sharp(await readFile(new URL(`oath-${name}-iphone.png`,dir))).metadata();assert.equal(m.width,1206);assert.equal(m.height,2622);}
});
test('copy controls provide success and denied-clipboard feedback',async()=>{
 const code=await readFile(new URL('press.js',root),'utf8');let click;const status={textContent:'',classList:{add(){},remove(){}}};let copied;
 const b={dataset:{copyTarget:'short'},addEventListener:(event,cb)=>click=cb};const clipboard={writeText:async text=>{copied=text}};
 runInNewContext(code,{document:{getElementById:id=>id==='press-copy-status'?status:{textContent:'  About Oath  '},querySelectorAll:()=>[b]},navigator:{clipboard},setTimeout:()=>0,clearTimeout(){}});
 await click();assert.equal(copied,'About Oath');assert.equal(status.textContent,'Press text copied.');b.dataset={copyValue:'#247BFF'};await click();assert.equal(copied,'#247BFF');
 clipboard.writeText=async()=>{throw Error('denied')};await click();assert.match(status.textContent,/Select the visible text/);
});
