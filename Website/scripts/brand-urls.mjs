import {brandVersion} from '../src/brand.js';
// Keep public and legacy URLs on the same build-owned logo revision.
export function brandUrls(text) {
 return text.replace(/\/assets\/brand\/oath-(?:mark-(?:dark|light)|logo)\.svg(?:\?v=[\w-]+)?/g,`/assets/brand/oath-logo.svg?v=${brandVersion}`)
  .replace(/\/(favicon\.svg|favicon\.ico|favicon-(?:16|32)\.png|apple-touch-icon\.png|icon-(?:192|512)\.png|wallet-logo\.png)(?:\?v=[\w-]+)?/g,`/$1?v=${brandVersion}`)
  .replace(/\/assets\/press\/2026-10\/oath-app-icon\.(svg|png)(?:\?v=[\w-]+)?/g,`/assets/press/2026-10/oath-app-icon.$1?v=${brandVersion}`);
}
