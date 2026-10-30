// Render the website's canonical exported components at build time. The Help
// Center stays server-rendered, with no client template evaluator or inline CSS.
import {readFile, writeFile} from 'node:fs/promises';
import {runInNewContext} from 'node:vm';
import {fileURLToPath} from 'node:url';

const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function value(expression, scope) {
  if (!/^[\w.]+$/.test(expression)) throw Error('Unsupported template expression: '+expression);
  return expression.split('.').reduce((item,key) => item?.[key], scope);
}
function render(template, scope) {
  // sc-for is the only structural directive in the two shared components.
  const start = template.indexOf('<sc-for ');
  if (start !== -1) {
    const headEnd = template.indexOf('>',start);
    const head = template.slice(start,headEnd+1);
    const list = /list="{{\s*([\w.]+)\s*}}"/.exec(head)?.[1];
    const name = /as="(\w+)"/.exec(head)?.[1];
    if (!list || !name) throw Error('Invalid shared component loop');
    let depth = 1, end;
    const tags = /<sc-for\b[^>]*>|<\/sc-for>/g;
    tags.lastIndex = headEnd+1;
    for (let match; (match=tags.exec(template));) {
      depth += match[0].startsWith('</') ? -1 : 1;
      if (!depth) { end=match.index; break; }
    }
    if (end===undefined) throw Error('Unclosed shared component loop');
    return render(template.slice(0,start),scope)
      + value(list,scope).map(item=>render(template.slice(headEnd+1,end),{...scope,[name]:item})).join('')
      + render(template.slice(end+9),scope);
  }
  return template.replace(/\s+onClick="{{\s*(\w+)\s*}}"/g,(_,action)=>{
    if (!['toggle','close'].includes(action)) throw Error('Unsupported shared navigation action');
    return ` data-oath-${action}`;
  }).replace(/{{\s*([^{}]+?)\s*}}/g,(_,expression)=>escape(value(expression,scope)));
}
function component(source,width,open=false) {
  const template=/<x-dc>([\s\S]*?)<\/x-dc>/.exec(source)?.[1].replace(/<helmet>[\s\S]*?<\/helmet>/,'').trim();
  const script=/<script\b[^>]*data-dc-script[^>]*>([\s\S]*?)<\/script>/.exec(source)?.[1];
  if (!template || !script) throw Error('Shared website component is missing its template or logic');
  // Only trusted repository code is evaluated, during the build, never content
  // from Supabase or a request. Lifecycle effects are not run.
  const values=runInNewContext(script+`;const instance=new Component(); instance.state.open=${open}; instance.renderVals();`, {
    DCLogic: class { constructor(){this.props={active:'Help Center'};} },
    window:{innerWidth:width,OathIcons:{}},
  },{timeout:1000});
  return render(template,values);
}
function lightFooter(html) {
  const colors={'#0A0A0B':'#FFFFFF','#F2F0EA':'#0A0A0B','#8E8C86':'#62605A','#D6D4CD':'#383735','#6E6C67':'#D6D4CD','#FFFFFF':'#000000','rgba(242,240,234,.12)':'rgba(10,10,11,.12)'};
  return html.replace(/#(?:0A0A0B|F2F0EA|8E8C86|D6D4CD|6E6C67|FFFFFF)|rgba\(242,240,234,\.12\)/g,c=>colors[c])
    .replace('/assets/brand/oath-mark-dark.svg','/assets/brand/oath-mark-light.svg');
}
function lightHeader(html) {
  const colors={
    '#F2F0EA':'#0A0A0B','#0A0A0B':'#F2F0EA','#FFFFFF':'#000000',
    '#B9B7B0':'#62605A','#D6D4CD':'#383735','#8E8C86':'#6E6C67','#6E6C67':'#92908B',
    'rgba(10,10,11,.94)':'rgba(248,249,252,.96)',
    'rgba(20,20,22,.72)':'rgba(255,255,255,.88)',
    'rgba(20,20,22,.4)':'rgba(255,255,255,.9)',
    'rgba(242,240,234,.1)':'rgba(10,10,11,.1)',
    'rgba(242,240,234,.08)':'rgba(10,10,11,.06)',
    'rgba(242,240,234,.16)':'rgba(10,10,11,.12)',
  };
  return html.replace(/#[\dA-F]{6}|rgba\([\d,.]+\)/g,color=>colors[color]??color)
    .replace('/assets/brand/oath-mark-dark.svg','/assets/brand/oath-mark-light.svg');
}
function extractStyles(html,part) {
  const styles=[];
  html=html.replace(/<[a-z][^>]*>/gi,tag=>{
    const style=/\sstyle="([^"]*)"/.exec(tag)?.[1];
    const hover=/\sstyle-hover="([^"]*)"/.exec(tag)?.[1];
    if (style===undefined && hover===undefined) return tag;
    const name=`oath-${part}-${styles.length}`;
    styles.push({name,style:style||'',hover});
    return tag.replace(/\sstyle(?:-hover)?="[^"]*"/g,'').replace(/>$/,` class="${name}">`);
  });
  return {html,styles};
}
function rules(part,styles,previous=[],state='') {
  return styles.map((entry,i)=>{
    const selector=`.oath-site-${part}${state} .${entry.name}`;
    return (entry.style!==previous[i]?.style ? `${selector}{${entry.style}}\n` : '')
      +(entry.hover!==previous[i]?.hover && entry.hover ? `${selector}:hover{${entry.hover}}\n` : '');
  }).join('');
}
export async function buildHelpChrome() {
  const sources=await Promise.all(['Header','Footer'].map(name=>readFile(new URL(`../public/Oath ${name}.dc.html`,import.meta.url),'utf8')));
  const header=(width,open)=>extractStyles(lightHeader(component(sources[0],width,open)),'header');
  const footer=width=>extractStyles(lightFooter(component(sources[1],width)),'footer');
  const desktop=header(1200,false), mobile=header(390,false), narrow=header(320,false), expanded=header(390,true);
  const wideFooter=footer(1200),smallFooter=footer(390);
  let headerHTML=desktop.html.replace(/^<div aria-hidden="true"/, '<div id="oath-site-menu" inert aria-hidden="true"')
    .replace('data-oath-toggle','data-oath-toggle aria-controls="oath-site-menu"')
    .replace('<nav ', '<nav aria-label="Mobile navigation" ')
    .replace(/<nav (?!aria-label)/,'<nav aria-label="Main navigation" ');
  const html=`export const siteHeader = ${JSON.stringify('<div class="oath-site-header">'+headerHTML+'</div>')};\nexport const siteFooter = ${JSON.stringify('<div class="oath-site-footer">'+wideFooter.html+'</div>')};\n`;
  const css=rules('header',desktop.styles)+rules('footer',wideFooter.styles)
    +'@media(max-width:1023px){\n'+rules('header',mobile.styles,desktop.styles)+'}\n'
    +'@media(max-width:359px){\n'+rules('header',narrow.styles,mobile.styles)+'}\n'
    +'@media(max-width:759px){\n'+rules('footer',smallFooter.styles,wideFooter.styles)+'}\n'
    +rules('header',expanded.styles,mobile.styles,'[data-menu-open]')
    +'.oath-site-header + main{margin-top:96px}\n'
    +'.oath-site-header a:focus-visible,.oath-site-header button:focus-visible{outline:2px solid #0A0A0B;outline-offset:4px}\n'
    +'@media(prefers-reduced-motion:reduce){.oath-site-header *{transition:none!important}}\n'
    +'@media print{.oath-site-header,.oath-site-footer{display:none}.oath-site-header + main{margin-top:0}}\n';
  const note='// Generated from public/Oath Header.dc.html and public/Oath Footer.dc.html. Run npm run build:help-chrome.\n';
  return {module:note+html,css:'/* Generated from the main website components. Do not edit directly. */\n'+css};
}
if(process.argv[1]===fileURLToPath(import.meta.url)){
  const output=await buildHelpChrome();
  await writeFile(new URL('../src/help/site-chrome.js',import.meta.url),output.module);
  await writeFile(new URL('../public/help/site-chrome.css',import.meta.url),output.css);
  console.log('Built Help Center navigation and light footer from the main website components.');
}
