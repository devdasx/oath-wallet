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
