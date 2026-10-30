import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import worker from '../src/index.js';

test('Apple association returns JSON without redirects on both standard paths', async () => {
  for (const path of ['/.well-known/apple-app-site-association', '/apple-app-site-association']) {
    const response = await worker.fetch(new Request('https://oathwallet.org' + path), {});
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('Content-Type'), 'application/json');
    assert.equal(response.headers.get('Location'), null);
    assert.deepEqual((await response.json()).applinks.details, [{ appID: 'C5T44SZNQX.com.aperture.wallet', paths: ['/wc', '/wc/'] }]);
  }
});
test('Landing never reflects pairing secrets or loads site analytics', async () => {
  const response = await worker.fetch(new Request('https://oathwallet.org/wc?uri=secret-fixture'), {});
  const html = await response.text();
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.equal(response.headers.get('Referrer-Policy'), 'no-referrer');
  assert.match(response.headers.get('Content-Security-Policy'), /connect-src 'none'/);
  assert.ok(!html.includes('secret-fixture'));
  assert.ok(!html.includes('visitor-events') && !html.includes('newsletter.js'));
  assert.match(html, /oathwallet:\/\//);
});
test('HEAD and unsupported methods preserve correct status', async () => {
  for (const path of ['/wc', '/wc/', '/.well-known/apple-app-site-association']) {
    const head = await worker.fetch(new Request('https://oathwallet.org' + path, { method: 'HEAD' }), {});
    assert.equal(head.status, 200); assert.equal(await head.text(), '');
    const post = await worker.fetch(new Request('https://oathwallet.org' + path, { method: 'POST' }), {});
    assert.equal(post.status, 405);
  }
});
const script = readFileSync(new URL('../public/wallet-open.js', import.meta.url), 'utf8');
function runLink(search = '') {
  const button = { href: 'oathwallet://', removeAttribute(name) { delete this[name]; }, setAttribute(name, value) { this[name] = value; } };
  const message = {};
  let scrubbed;
  runInNewContext(script, { URL, Set, encodeURIComponent, decodeURIComponent,
    window: { location: { href: 'https://oathwallet.org/wc' + search }, history: { replaceState(_a, _b, value) { scrubbed = value; } } },
    document: { getElementById(id) { return id === 'open-wallet' ? button : message; } } });
  return { button, message, scrubbed };
}
test('Browser fallback preserves the encoded pairing and removes it from history', () => {
  const uri = 'wc:' + 'aa'.repeat(32) + '@2?relay-protocol=irn&symKey=' + 'bb'.repeat(32);
  for (const search of ['?uri=' + encodeURIComponent(uri), '?uri=' + uri]) {
    const result = runLink(search);
    assert.equal(result.scrubbed, '/wc');
    assert.equal(result.button.href, 'oathwallet://wc?uri=' + encodeURIComponent(uri));
  }
  assert.equal(runLink().button.href, 'oathwallet://');
});
test('Browser fallback rejects arbitrary schemes, duplicate URIs and redirect injection', () => {
  for (const search of ['?uri=javascript:alert(1)', '?uri=https://evil.example', '?uri=', '?uri=wc:aa@2&redirect=https://evil.example', '?uri=wc:aa@2&uri=wc:bb@2', '?uri=wc:aa@2#fragment']) {
    const result = runLink(search);
    assert.equal(result.button.href, undefined);
    assert.equal(result.button['aria-disabled'], 'true');
  }
});
