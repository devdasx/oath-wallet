import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import worker from '../src/index.js';

const policy = 'max-age=31536000; includeSubDomains; preload';
const env = { ASSETS: { async fetch(request) {
  const url = new URL(typeof request === 'string' ? request : request.url);
  try {
    const body = await readFile(new URL('../public' + url.pathname, import.meta.url));
    return new Response(body, { headers: { 'X-Asset-Test': 'preserved' } });
  } catch {
    return new Response('Missing', { status: 404 });
  }
} } };

test('HTTPS policy covers pages, static assets, text and 404 responses', async () => {
  for (const [path, status] of [['/', 200], ['/press', 200], ['/press.md', 200], ['/favicon.svg', 200], ['/missing-page', 404]]) {
    const response = await worker.fetch(new Request('https://oathwallet.org' + path), env);
    assert.equal(response.status, status, path);
    assert.equal(response.headers.get('Strict-Transport-Security'), policy, path);
    if (status === 200) assert.equal(response.headers.get('X-Asset-Test'), 'preserved');
    if (path.endsWith('.md')) {
      assert.equal(response.headers.get('Access-Control-Allow-Origin'), '*');
      assert.match(response.headers.get('Content-Type'), /text\/markdown/);
    }
  }
});

test('HTTPS redirects retain HSTS and preserve query strings', async () => {
  for (const [url, destination, status] of [
    ['https://www.oathwallet.org/press?from=listing', 'https://oathwallet.org/press?from=listing', 301],
    ['https://oathwallet.org/press.html?from=listing', 'https://oathwallet.org/press?from=listing', 308],
    ['https://oathwallet.org/index.html', 'https://oathwallet.org/', 308]
  ]) {
    const response = await worker.fetch(new Request(url), env);
    assert.equal(response.status, status);
    assert.equal(response.headers.get('Location'), destination);
    assert.equal(response.headers.get('Strict-Transport-Security'), policy);
  }
});

test('HTTP upgrades to HTTPS on the same host with status 301', async () => {
  for (const host of ['oathwallet.org', 'www.oathwallet.org']) {
    const response = await worker.fetch(new Request('http://' + host + '/press?from=listing'), env);
    assert.equal(response.status, 301);
    assert.equal(response.headers.get('Location'), 'https://' + host + '/press?from=listing');
    assert.equal(response.headers.get('Strict-Transport-Security'), null);
  }
});

test('local development remains available over HTTP', async () => {
  const response = await worker.fetch(new Request('http://127.0.0.1:8793/press'), env);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Strict-Transport-Security'), null);
});

test('MCP success and error responses receive HSTS and expose public leadership', async () => {
  const request = body => new Request('https://oathwallet.org/mcp', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body
  });
  const response = await worker.fetch(request(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'get_contact', arguments: {} } })), env);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Strict-Transport-Security'), policy);
  const body = await response.json();
  assert.deepEqual(body.result.structuredContent.leadership, { name: 'Marco Valenti', role: 'Founder & CEO', profile: 'https://x.com/MarcoValentiX' });
  const invalid = await worker.fetch(request('{invalid'), env);
  assert.equal(invalid.status, 400);
  assert.equal(invalid.headers.get('Strict-Transport-Security'), policy);
});
