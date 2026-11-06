import assert from 'node:assert/strict';

const urls = ['https://oathwallet.org/', 'https://oathwallet.org/security',
  'https://articles.oathwallet.org/', 'https://help.oathwallet.org/'];
await Promise.all(urls.map(async url => {
  const response = await fetch(url, {signal: AbortSignal.timeout(20000)});
  assert.equal(response.status, 200, url);
  assert.ok((await response.text()).length > 500, url);
  if (url.includes('help.')) assert.equal(response.headers.get('x-oath-content'), 'git');
}));
console.log('Production main site, security, articles and Git-owned Help Center verified.');

const {default:tokens}=await import('../src/tokens-manifest.json',{with:{type:'json'}});
const published=await fetch('https://oathwallet.org'+tokens.prefix+'/manifest.json',{signal:AbortSignal.timeout(20000)});
assert.equal(published.status,200);assert.deepEqual(await published.json(),tokens,'Published catalog differs from this commit');
for(let offset=0;offset<tokens.samples.length;offset+=5){
 await Promise.all(tokens.samples.slice(offset,offset+5).map(async path=>{
  const r=await fetch('https://oathwallet.org'+path,{method:'HEAD',signal:AbortSignal.timeout(20000)});
  assert.equal(r.status,200,path);assert.equal(r.headers.get('x-oath-catalog-version'),tokens.version,path);assert.ok(r.headers.get('link')?.includes('https://oathwallet.org'+path+'>; rel="canonical"'),path);
 }));
}
const search=await fetch('https://oathwallet.org/tokens?q=USDC&network=base',{signal:AbortSignal.timeout(20000)});
assert.equal(search.status,200);assert.ok(search.headers.get('x-robots-tag')?.includes('noindex'));assert.ok((await search.text()).includes('/tokens/usdc/base'));
const tokenDocuments=await fetch('https://oathwallet.org/tokens/documents.json',{signal:AbortSignal.timeout(20000)});
assert.equal(tokenDocuments.status,200);assert.equal((await tokenDocuments.json()).documents.length,100);
console.log(`Verified catalog ${tokens.version}: ${tokens.count} identities; ${tokens.samples.length} live samples covering every token network, search and bounded discovery.`);

// Compare the deployed text with the Markdown generated from this checkout.
const {documents,documentText} = await import('../src/agent-content.js');
const {readFile} = await import('node:fs/promises');
const {default:catalog} = await import('../public/oath-data.json',{with:{type:'json'}});
for (const article of catalog.articles.filter(a=>a.github_editorial)) {
  const doc = documents.find(d=>d.url===article.url);
  assert.ok(doc, article.url);
  const file = new URL('../public'+doc.file,import.meta.url);
  const expected = await documentText(doc,{},new Response(await readFile(file)));
  const res = await fetch(doc.markdown_url,{signal:AbortSignal.timeout(20000)});
  assert.equal(res.status,200,doc.markdown_url);
  assert.equal(await res.text(),expected,doc.markdown_url+' differs from the deployed commit');
  console.log('Verified published article: '+doc.url);
}

// Feature pages must match this commit, not merely return a successful status.
const {default:features}=await import('../content/features.json',{with:{type:'json'}});
const {createHash}=await import('node:crypto');
const featureCSS=await fetch('https://oathwallet.org/feature-pages.css',{signal:AbortSignal.timeout(20000)});
assert.equal(featureCSS.status,200);
assert.equal(await featureCSS.text(),await readFile(new URL('../public/feature-pages.css',import.meta.url),'utf8'),'Feature stylesheet differs from commit');
for(const feature of features.features){
 const url='https://oathwallet.org'+feature.path;
 const response=await fetch(url,{signal:AbortSignal.timeout(20000)});
 assert.equal(response.status,200,url);
 const html=await response.text();
 assert.ok(html.includes('<link rel="canonical" href="'+url+'">'),url);
 assert.ok(html.includes(feature.image.path)&&html.includes(feature.image.version),url+' screenshot provenance');
 const localHTML=await readFile(new URL('../public'+feature.path+'.html',import.meta.url),'utf8');
 assert.equal(html.match(/<main\b[\s\S]*?<\/main>/)?.[0],localHTML.match(/<main\b[\s\S]*?<\/main>/)?.[0],url+' initial HTML differs from commit');
 const doc=documents.find(d=>d.url===url);
 const expected=await documentText(doc,{},new Response(await readFile(new URL('../public'+doc.file,import.meta.url))));
 const markdown=await fetch(doc.markdown_url,{signal:AbortSignal.timeout(20000)});
 assert.equal(markdown.status,200);assert.equal(await markdown.text(),expected,url+' content differs from commit');
 const image=await fetch('https://oathwallet.org'+feature.image.path,{signal:AbortSignal.timeout(20000)});
 assert.equal(image.status,200);
 assert.equal(createHash('sha256').update(Buffer.from(await image.arrayBuffer())).digest('hex'),feature.image.sha256);
 console.log('Verified published feature and original screenshot: '+url);
}

// SEO changes must be visible in the publishing commit's initial HTML.
const {default:decisionGuides}=await import('../content/decision-guides.json',{with:{type:'json'}});
const {default:priority}=await import('../content/priority-guidance.json',{with:{type:'json'}});
const {priorityHTML}=await import('../src/seo-guidance.js');
for(const p of decisionGuides.pages){
 const url='https://oathwallet.org'+p.path,r=await fetch(url,{signal:AbortSignal.timeout(20000)});
 assert.equal(r.status,200,url);const html=await r.text(),expected=await readFile(new URL('../public'+p.path+'.html',import.meta.url),'utf8');
 assert.equal(html.match(/<main\b[\s\S]*?<\/main>/)?.[0],expected.match(/<main\b[\s\S]*?<\/main>/)?.[0],url+' differs from this commit');
 assert.ok(html.includes('<link rel="canonical" href="'+url+'">'));assert.ok(!r.headers.get('x-robots-tag')?.includes('noindex'));
}
const priorityPaths=Object.keys(priority.pages);
for(let offset=0;offset<priorityPaths.length;offset+=4)await Promise.all(priorityPaths.slice(offset,offset+4).map(async path=>{
 const response=await fetch('https://oathwallet.org'+path,{signal:AbortSignal.timeout(20000)});assert.equal(response.status,200,path);assert.ok((await response.text()).includes(priorityHTML(path)),path+' is missing current practical guidance');
}));
for(const [url,name]of [['https://oathwallet.org/','Oath Wallet'],['https://articles.oathwallet.org/','Oath Wallet Articles'],['https://help.oathwallet.org/','Oath Wallet Help']]){
 const r=await fetch(url,{signal:AbortSignal.timeout(20000)});assert.equal(r.status,200);const html=await r.text();
 assert.ok(html.includes('property="og:site_name" content="'+name+'"'),url+' site name');
 const nodes=[...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].flatMap(m=>{const value=JSON.parse(m[1]);return value['@graph']||[value];});
 assert.equal(nodes.find(n=>n['@type']==='WebSite')?.name,name,url+' structured site name');
 if(url==='https://oathwallet.org/'){
  const app=nodes.find(n=>n['@type']==='MobileApplication');assert.ok(app);assert.equal(app.aggregateRating,undefined);assert.equal(app.review,undefined);
 }
}
console.log(`Verified all three site identities, rating markup, ${decisionGuides.pages.length} decision guides and ${priorityPaths.length} enriched priority pages.`);

const {transferURL,transferPath}=await import('../src/transfer-preparation.js');
for(const path of ['/transfer-preparation.js','/decision-guides.css']){
 const response=await fetch('https://oathwallet.org'+path,{signal:AbortSignal.timeout(20000)});
 assert.equal(response.status,200);assert.equal(await response.text(),await readFile(new URL('../public'+path,import.meta.url),'utf8'),path+' differs from this commit');
}
for(const network of Object.values(tokens.networks)){
 const asset=network.featured[0];
 const response=await fetch('https://oathwallet.org'+transferURL(asset),{signal:AbortSignal.timeout(20000)});
 assert.equal(response.status,200,asset.path);assert.match(response.headers.get('x-robots-tag'),/noindex/);
 const html=await response.text();
 assert.ok(html.includes(`data-transfer-path="${asset.path}">`),asset.path+' is not preselected');
 assert.ok(html.includes(`href="https://oathwallet.org${transferPath}"`));
}
for(const path of ['/','/features']){
 const response=await fetch('https://oathwallet.org'+path,{signal:AbortSignal.timeout(20000)}),html=await response.text();
 assert.doesNotMatch(html,/4\.1\.14|use physical entropy|addEntropy/);
 if(path==='/')assert.ok(html.includes('networks/choose-token-network#prepare-transfer'));
}
const tokenEntry=await fetch('https://oathwallet.org/tokens/usdc/base',{signal:AbortSignal.timeout(20000)});
assert.ok((await tokenEntry.text()).includes('choose-token-network?token=usdc&amp;network=base#prepare-transfer'));
console.log(`Verified transfer preparation across ${Object.keys(tokens.networks).length} networks, exact token links, current copy and published tool assets.`);

for(const path of ['/assets/home-preview/wallet-motion.js','/assets/home-preview/cobalt.webp','/Oath App Home.dc.html']){
 const response=await fetch('https://oathwallet.org'+encodeURI(path),{signal:AbortSignal.timeout(20000)});
 assert.equal(response.status,200,path);
 let expected=await readFile(new URL('../public'+path,import.meta.url));
 // The public Worker appends these shared scripts to every successful HTML head.
 // Compare the exact served representation, including that deliberate transform.
 if(path.endsWith('.html')) expected=Buffer.from(expected.toString().replace('</head>','<script src="/visitor-events.js" defer></script><link rel="stylesheet" href="/newsletter.css"><script src="/newsletter.js" defer></script></head>'));
 assert.equal(createHash('sha256').update(Buffer.from(await response.arrayBuffer())).digest('hex'),createHash('sha256').update(expected).digest('hex'),path+' differs from the deployed commit');
}
console.log('Verified the published homepage artwork and bounded animation renderer.');

// Check the shipped artwork integration and representative real image responses.
const {default:artwork}=await import('../src/artwork-manifest.json',{with:{type:'json'}});
const {imageType}=await import('../src/artwork-route.js');
for(const path of ['/token-artwork.css','/token-artwork.js']){
 const response=await fetch('https://oathwallet.org'+path,{signal:AbortSignal.timeout(20000)});
 assert.equal(response.status,200);assert.equal(await response.text(),await readFile(new URL('../public'+path,import.meta.url),'utf8'),path+' differs from this commit');
}
const imageSamples=new Map();
for(const path of ['/tokens','/tokens?q=USDC&network=base','/tokens/usdc','/tokens/usdc/base','/tokens/usdc/solana','/tokens/usdt/tron','/networks/base/tokens','/networks/base','/networks/choose-token-network?token=usdc&network=base']){
 const response=await fetch('https://oathwallet.org'+path,{signal:AbortSignal.timeout(20000)});
 assert.equal(response.status,200);const html=await response.text();
 const matches=[...html.matchAll(new RegExp('src="(/token-artwork/'+artwork.version+'/[a-f0-9]{32})"','g'))];
 assert.ok(matches.length,path+' is missing current token artwork');
 assert.ok(html.includes('/token-artwork.css')&&html.includes('/token-artwork.js'),path);
 if(['/tokens/usdc/base','/tokens/usdc/solana','/tokens/usdt/tron'].includes(path))imageSamples.set(matches[0][1],true);
}
for(const network of Object.values(tokens.networks)){
 const row=network.featured.find(a=>a.artwork);
 if(row&&!imageSamples.has(row.artwork))imageSamples.set(row.artwork,false);
}
let actualImages=0,fallbacks=0;
for(const [path,required]of imageSamples){
 const response=await fetch('https://oathwallet.org'+path,{signal:AbortSignal.timeout(20000)});
 assert.equal(response.status,200,path);const kind=response.headers.get('X-Oath-Artwork');
 assert.ok(['image','fallback'].includes(kind),path+' unrecognized image response');
 const bytes=new Uint8Array(await response.arrayBuffer());assert.equal(imageType(bytes),response.headers.get('Content-Type'),path);
 if(required)assert.equal(kind,'image',path+' priority artwork is unavailable');
 if(kind==='image')actualImages++;else fallbacks++;
}
assert.equal((await fetch('https://oathwallet.org/token-artwork/unknown',{signal:AbortSignal.timeout(20000)})).status,404);
console.log(`Verified artwork version ${artwork.version}: ${artwork.entries} identity matches; ${actualImages} live image samples, ${fallbacks} working fallbacks; all token surfaces and priority stablecoin images.`);
