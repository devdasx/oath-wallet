import {articleURL, ARTICLE_ORIGIN} from '../src/article-host.js';

// One edition per article and language. Keep the source records unchanged for
// feeds and translated article routes; only normalize the archive's view model.
export function articleCards(records) {
  const key = record => new URL(record.url).pathname.split('/').filter(Boolean).at(-1);
  const english = new Map(records.filter(a => a.locale === 'en').map(a => [key(a), a]));
  const seen = new Set();
  return records.map(a => {
    const id = key(a), locale = a.locale || 'en', edition = `${id}:${locale}`;
    if (seen.has(edition)) throw new Error(`Duplicate article edition: ${edition}`);
    seen.add(edition);
    const url = new URL(a.url);
    const href = url.hostname === 'articles.oathwallet.org' ? url.href : articleURL(url.pathname);
    const cover = new URL(a.cover_image_url);
    if (!['oathwallet.org','articles.oathwallet.org'].includes(cover.hostname) || !cover.pathname.startsWith('/assets/articles/')) throw new Error(`Unexpected article cover: ${id}`);
    if (!english.has(id)) throw new Error(`Missing English edition: ${id}`);
    return {...a, id, locale, href, cover: ARTICLE_ORIGIN + cover.pathname,
      alt: a.title, category: english.get(id).category,
      date: new Intl.DateTimeFormat('en', {month:'short', day:'numeric', year:'numeric', timeZone:'UTC'}).format(new Date(a.published_at)),
      read: `${a.reading_minutes} min read`, dir: ['ar','ur'].includes(locale) ? 'rtl' : 'ltr'};
  });
}
export function articleLanguages(cards) {
  return [...new Map(cards.map(a => [a.locale, {code:a.locale, label:a.language_name || 'English'}])).values()]
    .sort((a,b) => a.code === 'en' ? -1 : b.code === 'en' ? 1 : a.label.localeCompare(b.label));
}
const esc = value => String(value).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
export function articleFallback(cards) {
  const english = cards.filter(a => a.locale === 'en');
  return `<h1>Notes on keeping it.</h1><p>Guides, security notes and stories from the people building Oath.</p><p>Articles in English. Enable JavaScript to search, filter and choose from ${articleLanguages(cards).length} languages.</p><div class="article-readable-grid">${english.map(a => `<article><a href="${esc(a.href)}"><img src="${esc(a.cover)}" alt="${esc(a.alt)}" width="1200" height="630" loading="lazy"><h2>${esc(a.title)}</h2></a><p>${esc(a.excerpt)}</p><p>${esc(a.category)} · ${esc(a.date)} · ${esc(a.read)}</p></article>`).join('')}</div>`;
}
