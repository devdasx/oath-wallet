import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import data from '../src/help/content.json' with {type:'json'};
import {home, collection, article, searchResults, notFound, HELP_SOCIAL_IMAGE} from '../src/help/render.js';
import {handleHelp} from '../src/help/index.js';

function meta(html, key) {
  const matches = [...html.matchAll(/<meta (?:property|name)="([^"]+)" content="([^"]*)">/g)]
    .filter(match => match[1] === key);
  assert.equal(matches.length, 1, `${key} must appear exactly once`);
  return matches[0][2];
}

test('all shared Help Center routes include the same image before JavaScript runs', () => {
  const pages = [
    home(data), ...data.categories.map(c => collection(data, c)),
    ...data.articles.map(a => article(data, a)),
    searchResults(data, 'backup'), notFound(),
    article(data, {...data.articles[0], slug:'future-guide', title:'Future guide', screenshot:null}),
  ];
  for (const page of pages) {
    const head = page.split('</head>')[0];
    assert.equal(meta(head, 'og:image'), HELP_SOCIAL_IMAGE);
    assert.equal(meta(head, 'og:image:secure_url'), HELP_SOCIAL_IMAGE);
    assert.equal(meta(head, 'twitter:image'), HELP_SOCIAL_IMAGE);
    assert.equal(meta(head, 'twitter:card'), 'summary_large_image');
    assert.equal(meta(head, 'twitter:site'), '@OathWallet');
    assert.equal(meta(head, 'og:image:type'), 'image/png');
    assert.equal(meta(head, 'og:image:width'), '1200');
    assert.equal(meta(head, 'og:image:height'), '630');
    assert.equal(meta(head, 'og:image:alt'), meta(head, 'twitter:image:alt'));
    assert.ok(meta(head, 'og:image:alt').length > 20);
    assert.equal(meta(head, 'twitter:title'), meta(head, 'og:title'));
    assert.equal(meta(head, 'twitter:description'), meta(head, 'og:description'));
  }
});

test('guide metadata stays specific and escapes content without affecting the image', () => {
  const html = article(data, {...data.articles[0], title:'Wallet "A" & <B>', summary:'A "quoted" description <script>'});
  assert.equal(meta(html, 'twitter:title'), 'Wallet &quot;A&quot; &amp; &lt;B&gt;');
  assert.equal(meta(html, 'twitter:description'), 'A &quot;quoted&quot; description &lt;script&gt;');
  assert.equal(meta(html, 'twitter:image'), HELP_SOCIAL_IMAGE);
  assert.match(searchResults(data, 'wallet'), /name="robots" content="noindex,follow"/);
});

test('global preview is a small valid PNG at the advertised dimensions and is served as an asset', async () => {
  const url = new URL(HELP_SOCIAL_IMAGE);
  const bytes = await readFile(new URL('../public' + url.pathname, import.meta.url));
  assert.equal(bytes.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
  assert.equal(bytes.readUInt32BE(16), 1200);
  assert.equal(bytes.readUInt32BE(20), 630);
  assert.ok(bytes.length < 5_000_000);
  for (const method of ['GET', 'HEAD']) {
    let called = false;
    const response = await handleHelp(new Request(url, {method}), {ASSETS:{fetch(request) {
      called = true;
      assert.equal(request.url, HELP_SOCIAL_IMAGE);
      assert.equal(request.method, method);
      return new Response(method === 'HEAD' ? null : bytes, {headers:{'Content-Type':'image/png'}});
    }}});
    assert.equal(called, true, 'must reach static assets, not the guide lookup or 404');
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('Content-Type'), 'image/png');
  }
});
