import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import worker from '../src/index.js';
import catalog from '../content/networks.json' with {type:'json'};
import { articleRoutes } from '../src/article-routes.js';
import { Script } from 'node:vm';
const publicURL = new URL('../public/', import.meta.url);
const env = { ASSETS: { async fetch(req) {
  try { return new Response(await readFile(new URL('.' + new URL(req.url).pathname, publicURL))); }
  catch { return new Response('Missing', { status: 404 }); }
} } };
test('main search sitemap excludes moved articles, support and machine representations', async () => {
  const xml = await readFile(new URL('sitemap.xml', publicURL), 'utf8');
  const urls = [...xml.matchAll(/<loc>(.*?)<\/loc>/g)].map(m => m[1]);
  const paths = ['/', '/features', '/press', '/terms', '/privacy', '/security', '/about', '/networks', ...catalog.networks.map(n => '/networks/'+n.slug)];
  const expectedURLs = await Promise.all(paths.map(async path => {
    const articleFile = articleRoutes[path];
    if (typeof articleFile !== 'string') return 'https://oathwallet.org' + path;
    const html = await readFile(new URL('.' + articleFile, publicURL), 'utf8');
    const canonical = html.match(/<link rel="canonical" href="([^"]+)"/)?.[1];
    assert.ok(canonical, path + ' declares its canonical article URL');
    return canonical;
  }));
  assert.deepEqual(new Set(urls), new Set(expectedURLs));
  assert.equal(urls.length, paths.length);
});
test('alternate Markdown identifies its canonical web page while remaining accessible', async () => {
  for (const path of ['/index.md', '/features.md']) {
    const r = await worker.fetch(new Request('https://oathwallet.org' + path), env);
    assert.equal(r.status, 200);
    const expected = path === '/index.md' ? '/' : path.slice(0, -3);
    assert.ok(r.headers.get('Link').includes('https://oathwallet.org' + expected));
    assert.match(r.headers.get('Link'), /rel="canonical"/);
  }
  const r = await worker.fetch(new Request('https://oathwallet.org/llms.txt'), env);
  assert.equal(r.status, 200);
  assert.equal(r.headers.get('X-Robots-Tag'), 'noindex');
});

test('all core pages deliver readable content and navigation before JavaScript', async () => {
  for (const page of ['index','features','articles','support','press','security','terms','privacy']) {
    const html = await readFile(new URL(page+'.html',publicURL),'utf8');
    assert.match(html, /<html lang="en">/, page);
    const readable = html.match(/<!-- oath-server-content:start -->([\s\S]*?)<!-- oath-server-content:end -->/)?.[1];
    assert.ok(readable, page+' has server HTML');
    assert.match(readable, /<h1>[\s\S]+?<\/h1>/,page);
    assert.equal((html.match(/<h1(?:\s|>)/gi)||[]).length,1,page+' has one H1 even when inert templates are parsed');
    assert.match(readable, /<nav aria-label="Main navigation"[^>]*>/,page);
    assert.match(readable, /href="(?:https:\/\/oathwallet.org)?\/security"/,page);
    assert.match(readable, /href="https:\/\/apps.apple.com\//,page);
    assert.doesNotMatch(readable, /<noscript|<template|\{\{/,page);
    const enhancedTemplate=html.match(/<template data-oath-template>([\s\S]*?)<\/template>/)?.[1];
    assert.match(enhancedTemplate, /<main id="main-content">[\s\S]+<\/main>/,page+' retains a main landmark after enhancement');
    assert.equal((html.match(/<html(?:\s|>)/g)||[]).length,1,page+' contains only one document');
    assert.equal((html.match(/<\/html>/g)||[]).length,1,page+' contains only one document end');
    assert.doesNotMatch(html,/docs\/AUDIT_SCOPE\.md|580cf943/,page+' does not send readers to retired source instructions');
    for (const match of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)) {
      if (/application\/ld\+json/.test(match[1])) JSON.parse(match[2]);
      else if (match[2].trim()) new Script(match[2],{filename:page+'.html'});
    }
  }
});

test('privacy copies scope app reporting to the App Store release and retain separate service disclosures', async () => {
  const copies=await Promise.all(['Oath Legal Doc.dc.html','privacy.md','privacy.html','llms-full.txt'].map(p=>readFile(new URL(p,publicURL),'utf8')));
  for (const text of copies) {
    assert.match(text,/October 30, 2026/);
    assert.match(text,/App Store version of Oath Wallet does not automatically upload app errors/);
    assert.doesNotMatch(text,/supabase|automatically sends limited technical reports|limited diagnostics|operational diagnostics|optional diagnostics/i);
    assert.match(text,/first-party website analytics/);
    assert.match(text,/selected topics, signup source page/);
    assert.match(text,/notification tokens and device metadata/);
    assert.match(text,/both the encrypted backup file and its backup password/);
    assert.match(text,/outside the app-reset boundary/);
    assert.doesNotMatch(text,/Your keys and recovery phrase never leave your device/);
  }
});

test('security evidence is pinned and agrees across public representations', async () => {
  const [html,markdown,allText,dataText] = await Promise.all(['security.html','security.md','llms-full.txt','oath-data.json'].map(p=>readFile(new URL(p,publicURL),'utf8')));
  const data=JSON.parse(dataText);
  assert.match(data.security.reviewed_source_commit,/^[a-f0-9]{40}$/);
  for (const text of [html,markdown,allText,dataText]) {
    assert.doesNotMatch(text,/Aperture\/Sources|210,000|210_000|binary-verified|audited by independent firms|580cf943/);
    assert.match(text,/Keychain/);
    assert.match(text,/600,000|600_000/);
    assert.match(text,/password/i);
  }
  const links=[...html.matchAll(/https:\/\/github\.com\/devdasx\/oath-wallet\/blob\/([^/]+)\//g)];
  assert.ok(links.length>=7);
  assert.ok(links.every(m=>m[1]===data.security.reviewed_source_commit || m[1]==='main'));
  const swiftLinks=[...html.matchAll(/https:\/\/github\.com\/devdasx\/oath-wallet\/blob\/([^/]+)\/[^"\s<>]+\.swift/g)];
  assert.ok(swiftLinks.every(m=>m[1]===data.security.reviewed_source_commit));
  assert.match(markdown,/receiving (?:and|or) discovery/);
  assert.match(markdown,/does not establish an independent security audit/);
});
