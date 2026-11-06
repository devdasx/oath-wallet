// Rebuild share cards from the same approved logo as the website and iOS app.
import {readFile, writeFile, readdir} from 'node:fs/promises';
import sharp from 'sharp';
import {brandVersion} from '../src/brand.js';

const root = new URL('../public/', import.meta.url);
const logo = await readFile(new URL('assets/brand/oath-logo.svg', root));
const image = `data:image/svg+xml;base64,${logo.toString('base64')}`;
const cards = {
  home: ['SELF-CUSTODY CRYPTO WALLET · IPHONE', 'A wallet,', 'not a marketplace.'],
  features: ['FEATURES', 'Your wallet.', 'Your control.'],
  security: ['SECURITY', 'Built for', 'self-custody.'],
  articles: ['ARTICLES', 'Notes on', 'keeping it.'],
  privacy: ['PRIVACY', 'Your wallet.', 'Your privacy.'],
  terms: ['TERMS OF SERVICE', 'Clear terms.', 'Your choice.'],
  support: ['SUPPORT', 'Here to help.', 'Every step.'],
};
const esc = text => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;');
for (const [name, [label, first, second]] of Object.entries(cards)) {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630">
    <rect width="1200" height="630" fill="#0B0B0D"/>
    <image href="${image}" x="72" y="60" width="56" height="56"/>
    <text x="142" y="100" fill="#FFFFFF" font-family="sans-serif" font-size="38" font-weight="600">Oath</text>
    <text x="1128" y="92" fill="#A1A1A6" text-anchor="end" font-family="sans-serif" font-size="17" letter-spacing="2">${esc(label)}</text>
    <text x="72" y="315" fill="#FFFFFF" font-family="serif" font-size="82">${esc(first)}</text>
    <text x="72" y="410" fill="#A1A1A6" font-family="serif" font-size="76" font-style="italic">${esc(second)}</text>
    <image href="${image}" x="868" y="196" width="260" height="260"/>
    <path d="M0 548H1200" stroke="#242427"/>
    <text x="72" y="595" fill="#A1A1A6" font-family="sans-serif" font-size="17" letter-spacing="2">OATHWALLET.ORG</text>
    <text x="1128" y="595" fill="#A1A1A6" text-anchor="end" font-family="sans-serif" font-size="17">FREE ON THE APP STORE · OPEN SOURCE</text>
  </svg>`;
  await sharp(Buffer.from(svg)).png().toFile(new URL(`og/${name}.png`, root).pathname);
}
// The release-history article used a second copy of the retired home card.
const home = await readFile(new URL('og/home.png', root));
await writeFile(new URL('og-image.png', root), home);
for (const path of ['../content/articles/oath-wallet-release-history/cover.png', 'assets/articles/editorials/oath-wallet-release-history/cover.png']) {
  await writeFile(new URL(path, root), home);
}
// Replace the older Appearance screenshot at its public alias with the current one.
await writeFile(new URL('help/assets/app-icons.webp', root),
  await readFile(new URL('help/assets/guide-10-app-icons.webp', root)));
// This unused legacy preview remains a public URL; replace its embedded kit logo too.
await writeFile(new URL('assets/press/2026-10/oath-press-preview.png', root),
  await readFile(new URL('og/press.png', root)));

// Bust previously cached share cards in static pages after all other builders.
async function update(directory) {
  for (const entry of await readdir(directory, {withFileTypes: true})) {
    const url = new URL(entry.name + (entry.isDirectory() ? '/' : ''), directory);
    if (entry.isDirectory()) await update(url);
    else if (/\.(html|md|json|txt)$/.test(entry.name)) {
      const old = await readFile(url, 'utf8');
      const next = old.replace(/\/og-image\.png(?:\?v=[\w-]+)?/g, `/og-image.png?v=${brandVersion}`).replace(/\/og\/(home|features|security|articles|privacy|terms|support)\.png(?:\?v=[\w-]+)?/g,
        `/og/$1.png?v=${brandVersion}`);
      if (next !== old) await writeFile(url, next);
    }
  }
}
await update(root);
console.log(`Built ${Object.keys(cards).length} share previews using approved artwork ${brandVersion}.`);
