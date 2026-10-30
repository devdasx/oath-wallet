#!/usr/bin/env python3
"""Apply the reviewed cover manifest without rebuilding or rewriting article bodies."""
import html
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PUBLIC = ROOT / 'public'
MANIFEST = ROOT / 'content/article-covers.json'
if not MANIFEST.exists():
    raise SystemExit(0)
covers = json.loads(MANIFEST.read_text())
routes = json.loads((ROOT/'src/article-routes.js').read_text().split(' = ', 1)[1].strip().removesuffix(';'))
pages = {PUBLIC/value.lstrip('/') for value in routes.values() if isinstance(value, str)}
files = pages | {PUBLIC/'articles.html', PUBLIC/'oath-data.json', PUBLIC/'articles/feed.json'}

def body(text):
    start = re.search(r'<div class="article-body">', text)
    if start is None:
        return None
    depth = 1
    for tag in re.finditer(r'<div\b[^>]*>|</div\s*>', text[start.end():]):
        depth += -1 if tag[0].startswith('</') else 1
        if depth == 0:
            return text[start.end():start.end()+tag.start()]
    raise ValueError('Unclosed article body')

changed = 0
for file in sorted(files):
    text = original = file.read_text()
    before_body = body(text)
    language = re.search(r'<html[^>]*lang="([^"]+)"', text)
    locale = language[1] if language else 'en'
    for cover in covers:
        for old, new in [(cover['old_url'], 'https://oathwallet.org'+cover['path']), (cover['url'], 'https://oathwallet.org'+cover['path']), (cover['old_path'], cover['path'])]:
            text = text.replace(old, new)
        alt = cover['localized_alts'].get(locale, cover['alt'])
        for old_alt in cover['old_alts']:
            # Handle HTML attributes and JSON strings independently.
            text = text.replace(html.escape(old_alt, quote=True), html.escape(alt, quote=True))
            text = text.replace(json.dumps(old_alt, ensure_ascii=False), json.dumps(alt, ensure_ascii=False))
    # Keep intrinsic image dimensions in sync to avoid a layout jump while loading.
    def cover_dimensions(match):
        tag = match[0]
        if '/assets/articles/oath-blue-2026-10-18/' not in tag:
            return tag
        tag = re.sub(r'\s(?:width|height)="[^"]*"', '', tag)
        return tag[:-1] + ' width="1200" height="630">'
    text = re.sub(r'<img\b[^>]*>', cover_dimensions, text)
    if file == PUBLIC/'articles.html':
        # Covers are designed as full landscape previews, never cropped thumbnails.
        text = text.replace('aspect-ratio:16/10', 'aspect-ratio:1200/630')
        text = text.replace('aspect-ratio:4/3', 'aspect-ratio:1200/630')
        text = text.replace('object-fit:cover', 'object-fit:contain')
    cover = next((c for c in covers if file.stem == c['slug']), None)
    if file in pages and cover:
        alt = cover['localized_alts'].get(locale, cover['alt'])
        text = re.sub(r'(<meta property="og:image:alt" content=")[^"]*(">)', lambda m:m[1]+html.escape(alt,quote=True)+m[2], text)
        # Explicit social metadata, in addition to the existing Open Graph fallback.
        text = re.sub(r'<meta (?:name="twitter:image(?:\:alt)?"|property="og:image:(?:width|height)") content="[^"]*">', '', text)
        social = (f'<meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">'
                  f'<meta name="twitter:image" content="https://oathwallet.org{cover["path"]}">'
                  f'<meta name="twitter:image:alt" content="{html.escape(alt,quote=True)}">')
        text = text.replace('</head>', social+'</head>', 1)
    assert body(text) == before_body, f'Article body changed: {file}'
    if text != original:
        file.write_text(text)
        changed += 1

style = PUBLIC/'article.css'
css = style.read_text()
rule = '\n/* Oath blue covers: show the full artwork in hero and related cards. */\n.cover img,.related-grid img{aspect-ratio:1200/630;object-fit:contain;max-height:none}\n'
if rule not in css:
    style.write_text(css+rule)

for file in pages:
    text = file.read_text()
    cover = next((c for c in covers if file.stem == c['slug']), None)
    if cover is None:
        continue
    assert f'<meta property="og:image" content="https://oathwallet.org{cover["path"]}">' in text, file
    assert f'<meta name="twitter:image" content="https://oathwallet.org{cover["path"]}">' in text, file
    assert (PUBLIC/cover['path'].lstrip('/')).exists(), cover['path']
print(f'Cover manifest applied to {len(pages)} article editions; {changed} page/data files updated.')
