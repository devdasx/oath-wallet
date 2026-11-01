import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join, extname, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const extensions = new Set(['.html', '.css', '.js', '.mjs', '.py', '.json', '.svg', '.tsx']);
function files(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    if (entry.name.startsWith('._') || entry.name === 'vendor') return [];
    const path = join(dir, entry.name);
    return entry.isDirectory() ? files(path) : extensions.has(extname(path)) ? [path] : [];
  });
}

test('website pages and generators omit northeast arrow decorations', () => {
  const forbidden = /\u2197|&#(?:0*8599|x0*2197);?|&nearr;|\\u\{?2197\}?|\\2197\b|arrow[-_]?up[-_]?right|north[-_]?east[-_]?arrow/i;
  const violations = ['public', 'scripts', 'src', 'content'].flatMap(dir => files(join(root, dir)))
    .filter(path => forbidden.test(readFileSync(path, 'utf8')))
    .map(path => relative(root, path));
  assert.deepEqual(violations, [], `Remove northeast arrow decorations from: ${violations.join(', ')}`);
});
