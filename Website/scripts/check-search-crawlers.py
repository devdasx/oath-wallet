"""Read-only search access smoke check; does not impersonate a verified bot IP."""
import concurrent.futures
import json
import re
import urllib.request
import urllib.robotparser
import xml.etree.ElementTree as ET

HOSTS = ['oathwallet.org', 'help.oathwallet.org', 'articles.oathwallet.org']
AGENTS = ['OAI-SearchBot', 'ChatGPT-User', 'Mozilla/5.0']


def get(url, agent):
    request = urllib.request.Request(url, headers={'User-Agent': agent})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.status, response.headers, response.read().decode('utf-8'), response.url


def check(host):
    origin = 'https://' + host
    checked = 0
    for agent in AGENTS:
        status, headers, text, final = get(origin + '/robots.txt', agent)
        assert status == 200 and final == origin + '/robots.txt'
        assert 'text/plain' in headers.get('Content-Type', '')
        for named_agent in ['OAI-SearchBot', 'ChatGPT-User']:
            assert f'User-agent: {named_agent}\nAllow: /\n' in text, host + ': missing explicit search permission'
        robots = urllib.robotparser.RobotFileParser()
        robots.parse(text.splitlines())
        assert origin + '/sitemap.xml' in robots.site_maps()
        status, headers, xml, final = get(origin + '/sitemap.xml', agent)
        urls = [node.text for node in ET.fromstring(xml).iter('{http://www.sitemaps.org/schemas/sitemap/0.9}loc')]
        assert urls, host + ': empty sitemap'
        for url in urls:
            assert url.startswith(origin + '/'), 'Unexpected sitemap host'
            assert robots.can_fetch(agent, url), agent + ': blocked ' + url
        # Sample first, middle and final documents; all sitemap URLs are checked
        # against robots. Full content/link coverage remains audit-search.py.
        for url in dict.fromkeys([urls[0], urls[len(urls)//2], urls[-1]]):
            status, headers, html, final = get(url, agent)
            assert status == 200 and 'text/html' in headers.get('Content-Type', '')
            assert headers.get('cf-mitigated') != 'challenge', url
            assert 'noindex' not in headers.get('X-Robots-Tag', '').lower(), url
            assert not re.search(r'<meta\b[^>]*name=["\'](?:robots|OAI-SearchBot)["\'][^>]*content=["\'][^"\']*noindex', html, re.I), url
            assert re.search(r'<h1[\s>]', html, re.I), url
            checked += 1
    return {'host': host, 'page_requests_passed': checked, 'sitemap_urls_allowed': len(urls)}


if __name__ == '__main__':
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(check, HOSTS))
    print(json.dumps({'results': results, 'scope': 'Requests originate from this runner, not OpenAI IPs. This does not prove verified-bot WAF access or indexing.'}, indent=2))
