// Public read-only post-deploy check. No credentials or browser session required.
import assert from 'node:assert/strict';
import {HELP_ORIGIN, HELP_SOCIAL_IMAGE} from '../src/help/render.js';

const bots = ['Twitterbot/1.0', 'facebookexternalhit/1.1'];
const get = (url, bot = bots[0]) => fetch(url, {
  headers:{'User-Agent':bot}, signal:AbortSignal.timeout(20000),
});
const metas = html => Object.fromEntries([...html.matchAll(/<meta (?:property|name)="([^"]+)" content="([^"]*)">/g)]
  .map(match => [match[1], match[2]]));
const sitemap = await get(HELP_ORIGIN + '/sitemap.xml');
assert.equal(sitemap.status, 200);
const urls = [...(await sitemap.text()).matchAll(/<loc>([^<]+)<\/loc>/g)].map(match => match[1]);
assert.ok(urls.length > 1);
let checked = 0;
// Bounded concurrency to keep the crawl light.
for (let start = 0; start < urls.length; start += 5) {
  await Promise.all(urls.slice(start, start + 5).map(async url => {
    const response = await get(url);
    assert.equal(response.status, 200, url);
    const meta = metas((await response.text()).split('</head>')[0]);
    assert.equal(meta['og:image'], HELP_SOCIAL_IMAGE, url);
    assert.equal(meta['twitter:image'], HELP_SOCIAL_IMAGE, url);
    assert.equal(meta['twitter:card'], 'summary_large_image', url);
    assert.equal(meta['og:url'], url, url);
    assert.equal(meta['og:image:width'], '1200', url);
    assert.equal(meta['og:image:height'], '630', url);
    checked++;
  }));
}
for (const bot of bots) {
  const image = await get(HELP_SOCIAL_IMAGE, bot);
  assert.equal(image.status, 200, bot);
  assert.match(image.headers.get('Content-Type'), /^image\/png/);
  const bytes = Buffer.from(await image.arrayBuffer());
  assert.equal(bytes.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
  assert.equal(bytes.readUInt32BE(16), 1200);
  assert.equal(bytes.readUInt32BE(20), 630);
  assert.ok(bytes.length < 5_000_000);
  const article = await get(HELP_ORIGIN + '/articles/add-passphrase', bot);
  assert.equal(article.status, 200);
  assert.equal(metas(await article.text())['og:image'], HELP_SOCIAL_IMAGE);
  console.log(`${bot}: image accessible, PNG 1200x630, ${bytes.length} bytes; guide metadata present`);
}
const robots = await get(HELP_ORIGIN + '/robots.txt');
assert.equal(robots.status, 200);
assert.doesNotMatch(await robots.text(), /Disallow:\s*(?:\/\s*$|\/help)/m);
console.log(`PASS: ${checked} live sitemap URLs share the global image; crawler access verified.`);
