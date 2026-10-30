"""Read-only audit of all three production sitemaps, HTML and internal resources.
Uses Python's standard library and curl (no browser sessions or credentials).
"""
import concurrent.futures
import datetime
from html.parser import HTMLParser
import json
from pathlib import Path
import subprocess
import sys
from urllib.parse import urljoin, urlsplit
import xml.etree.ElementTree as ET

HOSTS = ('oathwallet.org', 'articles.oathwallet.org', 'help.oathwallet.org')
class Page(HTMLParser):
    def __init__(self):
        super().__init__(); self.canonical=[]; self.lang=None; self.h1=[]; self.links=[]; self.images=[]; self.alternates=[]; self.meta={}; self.schemas=[]; self.title=''; self.active=None; self.template=0; self.script=None
    def handle_starttag(self, tag, attrs):
        a=dict(attrs)
        if tag=='template': self.template+=1
        if self.template: return
        if tag=='html': self.lang=a.get('lang')
        if tag=='meta': self.meta[a.get('name',a.get('property',''))]=a.get('content','')
        if tag=='link' and a.get('rel')=='canonical': self.canonical.append(a.get('href'))
        if tag=='link' and a.get('hreflang'): self.alternates.append(a)
        if tag=='a' and a.get('href'): self.links.append(a['href'])
        if tag=='img' and a.get('src'): self.images.append(a)
        if tag in ('title','h1'): self.active=tag
        if tag=='h1': self.h1.append('')
        if tag=='script': self.script='' if a.get('type')=='application/ld+json' else False
    def handle_endtag(self,tag):
        if tag=='template': self.template=max(0,self.template-1)
        if self.template: return
        if tag==self.active: self.active=None
        if tag=='script':
            if isinstance(self.script,str):
                try: self.schemas.append(json.loads(self.script))
                except ValueError: self.schemas.append({'invalid':True})
            self.script=None
    def handle_data(self,data):
        if self.template: return
        if self.script is not None:
            if isinstance(self.script,str): self.script+=data
            return
        if self.active=='title': self.title+=data
        if self.active=='h1': self.h1[-1]+=data

def fetch(url, head=False):
    command=['curl','--silent','--show-error','--location','--max-time','30']
    if head: command+=['--head','--output','/dev/null']
    command+=['--write-out','\n%{http_code}\n%{url_effective}\n%header{x-robots-tag}\n%header{content-type}',url]
    result=subprocess.run(command,text=True,capture_output=True)
    if result.returncode: raise RuntimeError('Fetch failed: '+url+' '+result.stderr[:120])
    body,status,final,robots,content_type=result.stdout.rsplit('\n',4)
    return int(status),final,robots,content_type,body

def audit(url):
    try:
        status,final,robots,content_type,body=fetch(url); page=Page();page.feed(body);issues=[]
        if status!=200: issues.append('HTTP '+str(status))
        if final!=url: issues.append('sitemap URL redirects')
        if page.canonical!=[url]: issues.append('canonical mismatch')
        if 'text/html' not in content_type: issues.append('not HTML')
        if 'noindex' in (robots+' '+page.meta.get('robots','')).lower(): issues.append('noindex')
        if not page.lang: issues.append('missing language')
        if not page.title: issues.append('missing title')
        if not page.meta.get('description'): issues.append('missing description')
        if len(page.h1)!=1: issues.append('H1 count '+str(len(page.h1)))
        if any(isinstance(s,dict) and s.get('invalid') for s in page.schemas): issues.append('invalid JSON-LD')
        return {'url':url,'status':status,'canonical':page.canonical,'language':page.lang,'title':page.title,'description':page.meta.get('description'),'h1':page.h1,'issues':issues,'schemas':page.schemas,'alternates':page.alternates,'links':page.links,'images':page.images,'social_image':page.meta.get('og:image')}
    except Exception as error: return {'url':url,'issues':[str(error)]}

def main():
    output=Path(sys.argv[1]) if len(sys.argv)>1 else Path('/tmp/oath-production-search-audit.json')
    sitemaps=[];urls=[]
    for host in HOSTS:
        url='https://'+host+'/sitemap.xml';status,_,_,_,body=fetch(url)
        if status!=200: raise SystemExit('Sitemap failed: '+url)
        entries=[x.text for x in ET.fromstring(body).iter() if x.tag.endswith('}loc')]
        sitemaps.append({'url':url,'status':status,'pages':len(entries)})
        urls+=entries
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool: pages=list(pool.map(audit,dict.fromkeys(urls)))
    known={p['url'] for p in pages};by_url={p['url']:p for p in pages}; targets=set()
    for page in pages:
        for alternate in page.get('alternates',[]):
            target=alternate['href']
            if target not in by_url: page['issues'].append('hreflang target outside sitemap: '+target)
            elif page['url'] not in [x['href'] for x in by_url[target].get('alternates',[])]: page['issues'].append('nonreciprocal hreflang: '+target)
        resources=page.get('links',[])+[i['src'] for i in page.get('images',[])]+[page.get('social_image')]
        for link in filter(None,resources):
            target=urljoin(page['url'],link).split('#')[0]
            if urlsplit(target).hostname in HOSTS and target not in known: targets.add(target)
    def check(url):
        try: status,final,*_=fetch(url,True);return {'url':url,'status':status,'final':final}
        except Exception as error:return {'url':url,'status':0,'error':str(error)}
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool: resources=list(pool.map(check,sorted(targets)))
    bad_pages=[p for p in pages if p['issues']];bad_resources=[r for r in resources if r['status']!=200]
    result={'checked_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'sitemaps':sitemaps,'sitemap_entries':len(urls),'unique_pages':len(known),'pages':pages,'resources':resources}
    output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
    print(json.dumps({'sitemaps':sitemaps,'unique_pages':len(known),'duplicate_sitemap_entries':len(urls)-len(known),'page_issues':[{k:p[k] for k in ('url','issues')} for p in bad_pages],'resource_checks':len(resources),'resource_issues':bad_resources,'output':str(output)},indent=2))
    raise SystemExit(bool(bad_pages or bad_resources or len(urls)!=len(known)))
if __name__=='__main__': main()
