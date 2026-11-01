// Preserve the artwork and layout; deliver density-appropriate, lossless icons.
import {readFile,writeFile,readdir,mkdir} from 'node:fs/promises';
import sharp from 'sharp';
const root=new URL('../public/',import.meta.url);
const directories=['assets/networks/','assets/home-preview/'];
const widths=[56,112,168];
const variants=new Map();
for(const directory of directories){
 await mkdir(new URL(directory+'responsive/',root),{recursive:true});
 for(const name of await readdir(new URL(directory,root))){
  if(!(directory.includes('networks')?/\.webp$/:/\.png$/).test(name))continue;
  const source=new URL(directory+name,root),stem=name.replace(/\.[^.]+$/,'');
  const paths=[];
  for(const width of widths){
   const path=`/${directory}responsive/${stem}-${width}.webp`;
   await sharp(source.pathname).resize(width,width,{fit:'inside',withoutEnlargement:true}).webp({lossless:true,effort:6}).toFile(new URL('.'+path,root).pathname);
   paths.push(`${path} ${width}w`);
  }
  variants.set('/'+directory+name,paths.join(', '));
 }
}
async function files(dir){return (await Promise.all((await readdir(dir,{withFileTypes:true})).map(e=>e.isDirectory()?files(new URL(e.name+'/',dir)):[new URL(e.name,dir)]))).flat();}
for(const file of await files(root)){
 if(!file.pathname.endsWith('.html'))continue;
 const before=await readFile(file,'utf8');
 const after=before.replace(/<img\b[^>]*>/g,tag=>{
  const src=tag.match(/\bsrc="([^"]+)"/)?.[1], width=Number(tag.match(/\bwidth="(\d+)"/)?.[1]);
  if(!variants.has(src)||!width||width>56)return tag;
  // The shared footer is emitted verbatim by another builder and remains its source of truth.
  if(/class="oath-footer-/.test(tag))return tag.replace(/\s(?:srcset|sizes)="[^"]*"/g,'');
  // Larger hero marks retain the original full-resolution source.
  return tag.replace(/\s(?:srcset|sizes)="[^"]*"/g,'').replace(/\s*\/?>(?=$)/,` srcset="${variants.get(src)}" sizes="${width}px">`);
 });
 if(after!==before)await writeFile(file,after);
}
console.log(`Built responsive lossless delivery for ${variants.size} existing icons; no styles or content changed.`);
