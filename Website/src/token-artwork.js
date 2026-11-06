const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function tokenArtwork(asset, size = 40, eager = false) {
  const initials = Array.from(asset.symbol || '').slice(0, 2).join('');
  const valid = /^\/token-artwork\/[a-f0-9]{16}\/[a-f0-9]{32}$/.test(asset.artwork || '');
  return `<span class="token-artwork" aria-hidden="true" style="--token-artwork-size:${size}px"><span>${escape(initials)}</span>${valid ? `<img src="${asset.artwork}" alt="" width="${size}" height="${size}" loading="${eager ? 'eager' : 'lazy'}" decoding="async">` : ''}</span>`;
}

// Decorative initials must not be concatenated into Markdown link labels.
export const stripTokenArtwork = html => html.replace(/<span class="token-artwork"[^>]*><span>[\s\S]*?<\/span>(?:<img\b[^>]*>)?<\/span>/g, '');

export function artworkCandidates(source) {
  if (!permittedArtworkURL(source)) return [source];
  const url = new URL(source);
  // Match OathArtworkSource: prefer CoinGecko's larger rendition, keeping the
  // catalog's original URL as a fallback and preserving encoded path segments.
  if (['assets.coingecko.com','coin-images.coingecko.com'].includes(url.hostname)) {
    url.pathname = url.pathname.replace('/thumb/','/large/').replace('/small/','/large/');
    if (url.href !== source) return [url.href, source];
  }
  return [source];
}

export function permittedArtworkURL(value) {
  try {
    const url = new URL(value);
    return value.length <= 2048 && url.protocol === 'https:' && !url.username && !url.password && !url.port &&
      ['assets.coingecko.com','coin-images.coingecko.com','raw.githubusercontent.com','static.debank.com'].includes(url.hostname);
  } catch { return false; }
}
