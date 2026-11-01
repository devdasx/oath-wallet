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
