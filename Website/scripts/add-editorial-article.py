#!/usr/bin/env python3
"""Idempotently add a reviewed content directory to Oath's static article archive."""
import html,json,re,shutil,sys
from pathlib import Path
from datetime import datetime
ROOT=Path(__file__).resolve().parents[1]; P=ROOT/'public'; folder=Path(sys.argv[1]).resolve()
a=json.loads((folder/'metadata.json').read_text());base='https://oathwallet.org'
path='/articles/'+a['slug'];url=base+path;cover='/assets/articles/'+a['slug']+'.png'
esc=lambda x:html.escape(str(x),quote=True)
dump=lambda x:json.dumps(x,ensure_ascii=False).replace('<','\\u003c')
body=(folder/'body.html').read_text().strip();headings=[]
def heading(m):
 i='section-'+str(len(headings)+1);headings.append((i,m[1]));return '<h2 id="'+i+'">'+m[1]+'</h2>'
body=re.sub(r'<h2>(.*?)</h2>',heading,body)
body=re.sub(r'<a href="(https://[^"]+)"',r'<a href="\1" rel="noopener noreferrer"',body)
data=json.loads((P/'oath-data.json').read_text());old=[x for x in data['articles'] if x['url']!=url]
sample=(P/'articles/what-never-leaves-iphone-oath-self-custody-security-model.html').read_text()
header=re.search(r'<a class="skip".*?</header>',sample,re.S)[0];footer=re.search(r'<footer class="site-footer">.*?</footer>',sample,re.S)[0]
toc='<details class="toc"><summary>In this article</summary><ol>'+''.join('<li><a href="#'+i+'">'+t+'</a></li>' for i,t in headings)+'</ol></details>'
related=[x for x in old if x['locale']=='en' and x['category']==a['category']][:3]
related_html=''.join('<a href="'+x['url'].replace(base,'')+'"><img src="'+x['cover_image_url'].replace(base,'')+'" alt="" loading="lazy"><span>'+esc(x['category'])+'</span><h3>'+esc(x['title'])+'</h3></a>' for x in related)
date=datetime.fromisoformat(a['published_at'].replace('Z','+00:00')).strftime('%B %-d, %Y')
schema={'@context':'https://schema.org','@type':'BlogPosting','headline':a['title'],'description':a['excerpt'],'datePublished':a['published_at'],'dateModified':a['updated_at'],'inLanguage':'en','mainEntityOfPage':url,'image':base+cover,'author':{'@type':'Organization','name':'Oath Wallet','url':base+'/about#editorial'},'publisher':{'@type':'Organization','name':'Oath Wallet','url':base,'logo':{'@type':'ImageObject','url':base+'/apple-touch-icon.png'}}}
if a.get('x_url'):schema['sameAs']=a['x_url']
page=f'''<!doctype html><html lang="en" dir="ltr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(a['title'])} — Oath Wallet</title><meta name="description" content="{esc(a['excerpt'])}">
<link rel="canonical" href="{url}"><link rel="alternate" hreflang="en" href="{url}"><link rel="alternate" hreflang="x-default" href="{url}"><link rel="alternate" type="text/markdown" href="{path}.md">
<link rel="icon" href="/favicon.svg" type="image/svg+xml"><link rel="apple-touch-icon" href="/apple-touch-icon.png"><meta name="theme-color" content="#0A0A0B">
<meta property="og:type" content="article"><meta property="og:site_name" content="Oath Wallet"><meta property="og:title" content="{esc(a['title'])}"><meta property="og:description" content="{esc(a['excerpt'])}"><meta property="og:url" content="{url}"><meta property="og:image" content="{base+cover}"><meta property="og:image:alt" content="{esc(a['cover_image_alt'])}"><meta property="og:image:width" content="1200"><meta property="og:image:height" content="630"><meta property="article:published_time" content="{a['published_at']}"><meta name="twitter:card" content="summary_large_image"><meta name="twitter:site" content="@OathWallet">
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&family=Instrument+Sans:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500&display=swap" rel="stylesheet"><link rel="stylesheet" href="/article.css"><script type="application/ld+json">{dump(schema)}</script>
</head><body>{header}<main id="content"><article>
<div class="article-hero"><a class="back" href="/articles">← All articles</a><div class="eyebrow">{esc(a['category'])} <span>·</span> <time datetime="{a['published_at']}">{date}</time></div><h1>{esc(a['title'])}</h1><p class="dek">{esc(a['excerpt'])}</p><div class="byline"><span>Oath Wallet <span>·</span> {a['reading_minutes']} min read</span></div></div>
<div class="cover"><img src="{cover}" alt="{esc(a['cover_image_alt'])}" fetchpriority="high" width="1200" height="630"></div>
<div class="reading-layout"><aside>{toc}</aside><div class="article-body">{body}<div class="article-end"><a href="/articles">← Explore all articles</a><a href="mailto:care@oathwallet.org">Questions? Contact Oath</a></div></div></div>
</article><section class="related"><div class="section-heading"><span class="eyebrow">Keep reading</span><h2>More to <em>keep.</em></h2></div><div class="related-grid">{related_html}</div></section></main>{footer}</body></html>'''
(P/(path.lstrip('/')+'.html')).write_text(page);(P/(path.lstrip('/')+'.md')).write_text((folder/'article.md').read_text());shutil.copy2(folder/'cover.png',P/cover.lstrip('/'))
routes_file=ROOT/'src/article-routes.js';routes=json.loads(routes_file.read_text().split(' = ',1)[1].rstrip().removesuffix(';'));routes[path]=path+'.html'
routes_file.write_text('// Generated from the migrated archive and reviewed editorial articles.\nexport const articleRoutes = '+json.dumps(routes,indent=2)+';\n')
row={k:a[k] for k in ['title','excerpt','category','author_name','published_at','updated_at','locale','language_name','reading_minutes']};row.update(url=url,cover_image_url=base+cover,markdown_url=url+'.md');data['articles']=[row]+old
(P/'oath-data.json').write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
index=(P/'articles.html').read_text();m=re.search(r'ARTICLES = (\[.*?\]);',index,re.S);assert m
cards=[c for c in json.loads(m[1]) if c['href']!=path]
card=dict(title=a['title'],excerpt=a['excerpt'],category=a['category'],date=datetime.fromisoformat(a['published_at'].replace('Z','+00:00')).strftime('%b %-d, %Y'),read=str(a['reading_minutes'])+' min read',href=path,cover=cover,alt=a['cover_image_alt'])
index=index[:m.start(1)]+dump([card]+cards)+index[m.end(1):]
def ld(m):
 v=json.loads(m[1])
 for obj in v.get('@graph',[]):
  if obj.get('@type')=='Blog':obj['blogPost']=[{'@type':'BlogPosting','headline':a['title'],'url':url,'datePublished':a['published_at']}]+[b for b in obj['blogPost'] if b['url']!=url]
 return '<script type="application/ld+json">'+dump(v)+'</script>'
index=re.sub(r'<script type="application/ld\+json">(.*?)</script>',ld,index,flags=re.S)
index=re.sub(r'<li><a href="'+re.escape(path)+r'">.*?</li>','',index,flags=re.S)
marker='<h1>Oath articles</h1><p>Guides, security notes and stories from the people building Oath.</p><ul>';assert marker in index
index=index.replace(marker,marker+'<li><a href="'+path+'">'+esc(a['title'])+'</a><p>'+esc(a['excerpt'])+'</p></li>',1);(P/'articles.html').write_text(index)
feed=json.loads((P/'articles/feed.json').read_text());feed['items']=[dict(id=url,url=url,title=a['title'],summary=a['excerpt'],content_html=body,date_published=a['published_at'],image=base+cover)]+[x for x in feed['items'] if x['url']!=url]
(P/'articles/feed.json').write_text(json.dumps(feed,ensure_ascii=False,indent=2))
rss=(P/'articles/feed.xml').read_text();rss=re.sub(r'<item>(?:(?!<item>).)*?<link>'+re.escape(url)+r'</link>.*?</item>','',rss,flags=re.S)
item='<item><title>'+esc(a['title'])+'</title><link>'+url+'</link><guid>'+url+'</guid><description>'+esc(a['excerpt'])+'</description></item>';pos=rss.index('<item>') if '<item>' in rss else rss.index('</channel>')
(P/'articles/feed.xml').write_text(rss[:pos]+item+rss[pos:])
entry='  <url><loc>'+url+'</loc><lastmod>'+a['updated_at'][:10]+'</lastmod></url>\n'
for name in ['sitemap.xml','articles/sitemap.xml']:
 s=(P/name).read_text();s=re.sub(r'\s*<url><loc>'+re.escape(url)+r'</loc>.*?</url>\s*','\n',s,flags=re.S);(P/name).write_text(s.replace('</urlset>',entry+'</urlset>'))
oldmd=(P/'articles.md').read_text();mdentry=f'## [{a["title"]}]({url})\n\n{a["excerpt"]}\n\nEnglish · {a["published_at"][:10]} · {a["reading_minutes"]} min read\n\n'
md=re.sub(r'## \[[^\n]+\]\('+re.escape(url)+r'\).*?(?=\n## |\Z)','',oldmd,flags=re.S);pos=md.index('## ');md=md[:pos]+mdentry+md[pos:];(P/'articles.md').write_text(md)
full=(P/'llms-full.txt').read_text();assert oldmd.strip() in full;(P/'llms-full.txt').write_text(full.replace(oldmd.strip(),md.strip()))
print(json.dumps({'url':url,'articles':len([x for x in data['articles'] if x['locale']=='en']),'editions':len(data['articles'])}))

# Preserve reviewed cover replacements when this article is regenerated.
import subprocess
subprocess.run([sys.executable, str(ROOT/'scripts/apply-article-covers.py')], check=True)
