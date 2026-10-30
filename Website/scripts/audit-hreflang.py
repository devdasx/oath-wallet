"""Check live sitemap language alternates, canonical targets and return links."""
import concurrent.futures
import datetime
import json
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path

BASE = "https://oathwallet.org"


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.canonical = []
        self.alternates = {}
        self.duplicates = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "link" and a.get("rel") == "canonical":
            self.canonical.append(a.get("href"))
        if tag == "link" and a.get("rel") == "alternate" and a.get("hreflang"):
            lang = a["hreflang"]
            if lang in self.alternates:
                self.duplicates.append(lang)
            self.alternates[lang] = a.get("href")


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "OathSearchAudit/1.0 (+https://oathwallet.org/about)"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.status, response.geturl(), response.read().decode("utf-8")


def inspect(url):
    status, final, body = fetch(url)
    page = Links()
    page.feed(body)
    return url, {"status": status, "final": final, "canonical": page.canonical,
                 "alternates": page.alternates, "duplicateLanguages": page.duplicates}


def main():
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/oath-hreflang-audit.json")
    sitemap = ET.fromstring(fetch(BASE + "/sitemap.xml")[2])
    urls = [element.text for element in sitemap.iter() if element.tag.endswith("}loc")]
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        pages = dict(pool.map(inspect, urls))
    issues = []
    clusters = set()
    for url, page in pages.items():
        alternates = page["alternates"]
        if not alternates:
            continue
        if url not in alternates.values():
            issues.append({"url": url, "issue": "missing_self_reference"})
        if page["duplicateLanguages"]:
            issues.append({"url": url, "issue": "duplicate_language", "languages": page["duplicateLanguages"]})
        if len(set(alternates.values())) > 1:
            clusters.add(tuple(sorted(alternates.items())))
        for language, target in alternates.items():
            # The site's valid BCP 47 forms include language-script (zh-Hans)
            # and language-region (pt-BR), as well as Google's x-default.
            if language != "x-default" and not re.fullmatch(r"[a-z]{2,3}(?:-[A-Z][a-z]{3})?(?:-[A-Z]{2})?", language):
                issues.append({"url": url, "issue": "invalid_language_form", "language": language})
            destination = pages.get(target)
            if destination is None:
                issues.append({"url": url, "issue": "target_not_in_sitemap", "target": target})
            elif destination["status"] != 200 or destination["final"] != target or destination["canonical"] != [target]:
                issues.append({"url": url, "issue": "noncanonical_target", "target": target})
            elif destination["alternates"] != alternates:
                issues.append({"url": url, "issue": "nonreciprocal_cluster", "target": target})
    result = {"checkedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "sitemapPages": len(pages), "pagesWithHreflang": sum(bool(p["alternates"]) for p in pages.values()),
              "multilingualClusters": len(clusters), "issues": issues, "pages": pages}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "pages"}, indent=2))
    raise SystemExit(bool(issues))


if __name__ == "__main__":
    main()
