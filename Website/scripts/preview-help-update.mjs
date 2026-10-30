import http from 'node:http';
import {readFile} from 'node:fs/promises';
import {resolve,extname} from 'node:path';
import data from '../src/help/content.json' with {type:'json'};
import {home,article,collection,searchResults} from '../src/help/render.js';
const publicRoot=resolve('public');
const server=http.createServer(async(req,res)=>{
 try{
  const url=new URL(req.url,'http://127.0.0.1:8898');let html;
  if(url.pathname==='/')html=home(data);
  else if(url.pathname==='/search')html=searchResults(data,url.searchParams.get('q')||'');
  else if(url.pathname.startsWith('/articles/')){const a=data.articles.find(a=>'/articles/'+a.slug===url.pathname);if(a)html=article(data,a);}
  else if(url.pathname.startsWith('/collections/')){const c=data.categories.find(c=>'/collections/'+c.id===url.pathname);if(c)html=collection(data,c);}
  if(html){res.writeHead(200,{'content-type':'text/html; charset=utf-8'});res.end(html);return;}
  const path=resolve(publicRoot,'.'+decodeURIComponent(url.pathname));if(!path.startsWith(publicRoot+'/'))throw Error('path');
  const raw=await readFile(path);res.writeHead(200,{'content-type':({'.css':'text/css','.js':'text/javascript','.webp':'image/webp','.svg':'image/svg+xml','.png':'image/png'})[extname(path)]||'application/octet-stream'});res.end(raw);
 }catch{res.writeHead(404);res.end('Not found');}
});server.listen(8898,'127.0.0.1',()=>console.log('Local reviewed Help Center preview ready.'));
