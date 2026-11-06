"""Bounded, same-origin traversal shared by production search audits."""
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET

def collect_sitemaps(url, fetch_text):
    origin = urlsplit(url).netloc
    seen, pages, reports = set(), [], []
    def visit(location, depth=0):
        if depth > 2 or len(seen) >= 20 or location in seen:
            raise ValueError('Sitemap cycle or traversal limit')
        if urlsplit(location).scheme != 'https' or urlsplit(location).netloc != origin:
            raise ValueError('Unexpected sitemap host')
        seen.add(location)
        xml = ET.fromstring(fetch_text(location))
        entries = [x.text for x in xml.iter() if x.tag.endswith('}loc')]
        if not entries or any(not x for x in entries):
            raise ValueError('Empty sitemap')
        index = xml.tag.endswith('}sitemapindex')
        reports.append({'url': location, 'status': 200, 'kind': 'index' if index else 'urls', 'entries': len(entries)})
        if index:
            for entry in entries: visit(entry, depth+1)
        else:
            if not xml.tag.endswith('}urlset') or len(entries)>10000:
                raise ValueError('Invalid or oversized sitemap')
            for entry in entries:
                if urlsplit(entry).scheme!='https' or urlsplit(entry).netloc!=origin:
                    raise ValueError('Unexpected page host')
            pages.extend(entries)
        if len(pages)>100000: raise ValueError('Page limit exceeded')
    visit(url)
    if len(set(pages))!=len(pages): raise ValueError('Duplicate canonical sitemap URL')
    return pages, reports
