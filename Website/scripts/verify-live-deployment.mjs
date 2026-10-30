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
