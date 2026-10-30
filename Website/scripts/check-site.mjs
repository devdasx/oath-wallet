import assert from 'node:assert/strict';
import { mkdir, writeFile, readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import dns from 'node:dns';
import { Resolver } from 'node:dns/promises';
import { Agent, setGlobalDispatcher } from 'undici';
import { chromium } from 'playwright';

const base = (process.argv[2] || 'http://127.0.0.1:8793').replace(/\/$/, '');
const output = path.resolve(process.argv[3] || '../Reports/oath-website-deployment-2026-09-23/local');
await mkdir(output, { recursive: true });
const report = { base, at: new Date().toISOString(), pages: [], checks: [], failures: [] };
const browserArgs = [];
if (process.env.OATH_QA_PUBLIC_DNS === '1') {
  // A newly connected domain can have a stale negative answer in the local resolver.
  // Resolve it publicly for this test process only; TLS verification remains enabled.
  const resolver = new Resolver();
  resolver.setServers(['1.1.1.1', '8.8.8.8']);
  const hosts = [new URL(base).hostname];
  if (hosts[0] === 'oathwallet.org') hosts.push('www.oathwallet.org');
  const records = Object.fromEntries(await Promise.all(hosts.map(async host => [host, await resolver.resolve4(host)])));
  report.dns = { resolvers: ['1.1.1.1', '8.8.8.8'], records, tlsVerification: true };
  setGlobalDispatcher(new Agent({ connect: { lookup(host, options, callback) {
    if (!records[host]) return dns.lookup(host, options, callback);
    const addresses = records[host].map(address => ({ address, family: 4 }));
    if (options.all) callback(null, addresses);
    else callback(null, addresses[0].address, 4);
  } } }));
  browserArgs.push('--host-resolver-rules=' + Object.entries(records).map(([host, ips]) => `MAP ${host} ${ips[0]}`).join(', '));
}
const check = (condition, message) => { assert.ok(condition, message); report.checks.push(message); };
const pages = ['/', '/features', '/articles', '/support', '/press', '/terms', '/privacy', '/security'];

async function filesIn(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  const groups = await Promise.all(entries.filter(e => e.name !== '_headers').map(async e => {
    const file = path.join(dir, e.name);
    return e.isDirectory() ? filesIn(file) : [file];
  }));
  return groups.flat();
}

async function checkHTTP() {
  const files = await filesIn('public');
  for (const file of files) {
    const route = file.slice('public'.length).split('/').map(encodeURIComponent).join('/');
    const response = await fetch(base + route);
    check(response.status === 200, `Asset ${route} returns 200`);
    let body = Buffer.from(await response.arrayBuffer());
    if (response.headers.get('content-type')?.includes('text/html')) body = Buffer.from(body.toString().replace('<script src="/visitor-events.js" defer></script>', ''));
    check(body.equals(await readFile(file)), `Asset ${route} matches deployed bytes`);
  }
  const missing = await fetch(base + '/missing/deep/page');
  check(missing.status === 404 && (await missing.text()).includes('A little off course.'), 'Nested missing URLs serve the branded 404');
  for (const file of ['/mcp.php', '/.htaccess', '/README.txt', '/package.json', '/wrangler.jsonc']) {
    check((await fetch(base + file)).status === 404, `${file} is not published`);
  }
  for (const route of ['/index.html', '/features.html', '/support/', '/terms.html', '/privacy.html', '/security.html']) {
    const response = await fetch(base + route, { redirect: 'manual' });
    check(response.status === 308 && response.headers.has('location') && !new URL(response.headers.get('location')).pathname.endsWith('.html'), `Clean canonical redirect ${route}`);
  }
  check((await fetch(base + '/features.md')).headers.get('content-type').startsWith('text/markdown'), 'Markdown served with the correct content type');
}

async function checkMCP() {
  let id = 0;
  const rpc = async (method, params = {}) => {
    const response = await fetch(base + '/mcp', { method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream', 'MCP-Protocol-Version': '2025-06-18' }, body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }) });
    check(response.status === 200, `MCP ${method} responds successfully`);
    const body = await response.json();
    assert.equal(body.id, id);
    return body;
  };
  check((await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'oath-deployment-check', version: '1' } })).result.protocolVersion === '2025-06-18', 'MCP protocol negotiation');
  const notification = await fetch(base + '/mcp', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) });
  check(notification.status === 202 && await notification.text() === '', 'MCP notification acknowledgement');
  check((await rpc('tools/list')).result.tools.length === 8, 'All eight MCP tools advertised');
  const argumentsByName = { get_overview: {}, list_features: {}, get_feature: { feature: 'evm-access' }, search_help: { query: 'network fees' }, get_contact: {}, get_download: {}, get_policy: { document: 'privacy' }, list_articles: {} };
  for (const [name, args] of Object.entries(argumentsByName)) {
    const { result } = await rpc('tools/call', { name, arguments: args });
    check(!result.isError && result.content[0].text.length > 10, `MCP ${name} returns content`);
    if (name === 'get_contact') check(result.structuredContent.email === 'care@oathwallet.org', 'MCP contact uses care@oathwallet.org');
    if (name === 'get_feature') check(result.structuredContent.id === 'evm-access', 'MCP feature lookup returns the exact requested feature');
    if (name === 'search_help') check(result.structuredContent.results.length > 0, 'MCP help search returns matching answers');
  }
  check((await rpc('tools/call', { name: 'get_policy', arguments: { document: 'terms' } })).result.content[0].text.includes('Terms'), 'MCP terms policy available');
  const resources = (await rpc('resources/list')).result.resources;
  check(resources.length === 9, 'All nine MCP resources advertised');
  for (const resource of resources) {
    check((await rpc('resources/read', { uri: resource.uri })).result.contents[0].text.length > 100, `MCP resource ${resource.name} readable`);
  }
  check((await rpc('resources/read', { uri: 'https://example.com/private' })).error.code === -32002, 'MCP disallows resources outside its public allowlist');
  check((await rpc('tools/call', { name: 'get_policy', arguments: { document: '../src/mcp.js' } })).result.isError, 'MCP rejects invalid policy paths');
  check((await rpc('tools/call', { name: 'get_feature', arguments: { feature: 123 } })).result.isError, 'MCP validates argument types');
  check((await rpc('prompts/list')).result.prompts.length === 1, 'MCP prompt advertised');
  check((await rpc('prompts/get', { name: 'explain_oath' })).result.messages.length === 2, 'MCP prompt includes source material');
  const invalid = await fetch(base + '/mcp', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{invalid' });
  check(invalid.status === 400 && (await invalid.json()).error.code === -32700, 'MCP malformed JSON handled');
  check((await fetch(base + '/mcp', { headers: { Origin: 'https://untrusted.example' } })).status === 403, 'MCP validates browser origins');
  check((await fetch(base + '/mcp', { headers: { Accept: 'text/event-stream' } })).status === 405, 'Stateless MCP does not advertise an unsupported event stream');
}

async function checkBrowser(browser, viewport) {
  const context = await browser.newContext({ viewport, isMobile: viewport.width < 600, deviceScaleFactor: 1, hasTouch: viewport.width < 600, acceptDownloads: true });
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  try {
    for (const route of pages) {
      const page = await context.newPage();
      const errors = [];
      page.on('pageerror', e => errors.push(e.message));
      page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
      page.on('requestfailed', r => { if (r.failure()?.errorText !== 'net::ERR_ABORTED') errors.push(`${r.url()}: ${r.failure()?.errorText}`); });
      page.on('response', r => { if (r.status() >= 400) errors.push(`${r.status()} ${r.url()}`); });
      try {
        const response = await page.goto(base + route, { waitUntil: 'domcontentloaded', timeout: 30000 });
        assert.equal(response.status(), 200);
        check(new URL(page.url()).pathname === route, `${route} stays on its clean URL`);
        await page.waitForFunction(() => !!document.querySelector('header a') && !!document.querySelector('footer a') && !!window.OathIcons);
        await page.waitForTimeout(1800);
        check(await page.locator('a[href$=".html"]').count() === 0, `${route} has no .html navigation links`);
        const title = await page.locator('h1:visible').innerText();
        check(title.length > 3 && !title.includes('{{'), `${viewport.width}px ${route} renders its heading`);
        await page.evaluate(async () => {
          for (let y = 0; y < document.body.scrollHeight; y += innerHeight * .8) {
            window.scrollTo({ top: y, behavior: 'instant' });
            await new Promise(resolve => setTimeout(resolve, 100));
          }
        });
        await page.waitForTimeout(500);
        const imageErrors = await page.evaluate(() => [...document.images].filter(i => !i.closest('x-dc') && i.getClientRects().length && (!i.complete || i.naturalWidth === 0)).map(i => i.src.slice(0,100)));
        check(imageErrors.length === 0, `${viewport.width}px ${route} images load`);
        check(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `${viewport.width}px ${route} has no horizontal overflow`);
        const emails = await page.locator('a[href^="mailto:"]:visible').evaluateAll(nodes => nodes.map(n => n.getAttribute('href')));
        check(emails.length > 0 && emails.every(href => href.startsWith('mailto:care@oathwallet.org')), `${viewport.width}px ${route} contact links use the correct address`);
        await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'instant' }));
        await page.waitForTimeout(300);
        const screenshot = `${viewport.width}-${route === '/' ? 'home' : route.slice(1)}.png`;
        await page.screenshot({ path: path.join(output, screenshot) });

        if (route === '/support') {
          const search = page.getByPlaceholder('Search — recovery phrase, passkey, fees…');
          await search.fill('network fees');
          await page.getByRole('button', { name: /What are network fees/ }).waitFor();
          check(await page.locator('#faq button:visible').count() >= 1, `${viewport.width}px support FAQ search works`);
          await search.fill('zzznomatch');
          await page.getByText('No answers match', { exact: false }).waitFor({ timeout: 5000 }).catch(() => {});
          check(!(await page.getByRole('button', { name: /What are network fees/ }).count()), `${viewport.width}px support search removes nonmatching results`);
          await search.fill('');
          await page.getByRole('button', { name: /Can I import a wallet/ }).click();
          const answer = page.getByText(/^Yes\. Tap “I already have a wallet”/).last();
          await answer.waitFor({ state: 'visible' });
          check((await answer.boundingBox()).height > 10, `${viewport.width}px FAQ accordion opens`);
          await page.getByPlaceholder('you@example.com').fill('qa@example.com');
          await page.getByPlaceholder('Describe the issue. Never include your recovery phrase.').fill('QA check: where can I see transaction fees?');
          const link = page.getByRole('link', { name: 'Send to care@oathwallet.org' });
          const mailto = await link.getAttribute('href');
          check(mailto.startsWith('mailto:care@oathwallet.org?') && decodeURIComponent(mailto).includes('QA check:'), `${viewport.width}px support form prepares the correct email without sending`);
          await page.getByRole('button', { name: 'Copy address', exact: true }).click();
          check(await page.evaluate(() => navigator.clipboard.readText()) === 'care@oathwallet.org', `${viewport.width}px contact copy button works`);
        }
        if (route === '/press' && viewport.width > 600) {
          for (const extension of ['SVG', 'PNG']) {
            const downloadEvent = page.waitForEvent('download');
            await page.getByRole('button', { name: `${extension} ↓`, exact: true }).first().click();
            const download = await downloadEvent;
            await download.saveAs(path.join(output, download.suggestedFilename()));
            const content = await readFile(path.join(output, download.suggestedFilename()));
            check(extension === 'PNG' ? content.subarray(1,4).toString() === 'PNG' : content.toString().includes('<svg'), `Press ${extension} download produces a valid file`);
          }
        }
        if (route === '/articles') {
          await page.getByPlaceholder('Search articles').fill('wallet');
          check(await page.getByRole('link').filter({ hasText: 'Oath' }).count() > 1, `${viewport.width}px articles search returns published articles`);
          await page.getByPlaceholder('Search articles').fill('zzznomatch');
          await page.getByText('No articles match that.', { exact: true }).waitFor();
          await page.getByPlaceholder('Search articles').fill('');
        }
        check(errors.length === 0, `${viewport.width}px ${route} has no browser or network errors: ${errors.join('; ')}`);
        report.pages.push({ route, viewport, title, screenshot, errors });
        console.log('PASS', viewport.width, route);
      } finally { await page.close(); }
    }
  } finally { await context.close(); }
}

const browser = await chromium.launch({ channel: 'chrome', headless: true, args: browserArgs });
try {
  const outcomes = await Promise.allSettled([
    checkHTTP(), checkMCP(),
    checkBrowser(browser, { width: 1440, height: 1000 }),
    checkBrowser(browser, { width: 390, height: 844 })
  ]);
  for (const outcome of outcomes) if (outcome.status === 'rejected') report.failures.push(outcome.reason.stack || String(outcome.reason));
} finally {
  await browser.close();
  await writeFile(path.join(output, 'checks.json'), JSON.stringify(report, null, 2));
}
console.log(JSON.stringify({ passed: report.checks.length, renderedPages: report.pages.length, failures: report.failures, report: path.join(output, 'checks.json') }, null, 2));
if (report.failures.length) process.exitCode = 1;
