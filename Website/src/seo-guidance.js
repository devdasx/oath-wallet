import guidance from '../content/priority-guidance.json' with {type:'json'};
const h=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function priorityHTML(path){
 const p=guidance.pages[path];if(!p)return '';
 return `<section class="oath-guidance" aria-labelledby="transfer-guidance"><div><p class="guidance-kicker">Practical next steps</p><h2 id="transfer-guidance">${h(p.title)}</h2>${p.questions.map(q=>`<details><summary>${h(q.q)}</summary><p>${h(q.a)}</p></details>`).join('')}<nav aria-label="Related practical guides"><ul>${p.links.map(l=>`<li><a href="${h(l.url)}">${h(l.label)}</a></li>`).join('')}</ul></nav><p class="guidance-source">Product guidance for Oath ${guidance.version} (${guidance.build}) · Updated ${guidance.updated}. <a href="https://oathwallet.org/about#editorial">How we review guides</a>.</p></div>${p.image?`<figure><img src="${p.image.path}" alt="${h(p.image.alt)}" width="1320" height="2868" loading="lazy" decoding="async"><figcaption><strong>${h(p.image.version)} · App screenshot.</strong> ${h(p.image.caption)}</figcaption></figure>`:''}</section>`;
}
export function priorityMarkdown(path){
 const p=guidance.pages[path];if(!p)return '';
 return `\n\n## ${p.title}\n\n${p.questions.map(q=>`### ${q.q}\n\n${q.a}`).join('\n\n')}\n\n${p.links.map(l=>`- [${l.label}](${l.url.startsWith('/')?'https://oathwallet.org':''}${l.url})`).join('\n')}${p.image?`\n\n![${p.image.alt}](https://oathwallet.org${p.image.path})\n\n${p.image.version}. ${p.image.caption}`:''}\n\nProduct guidance for Oath ${guidance.version} (${guidance.build}); updated ${guidance.updated}. [How we review guides](https://oathwallet.org/about#editorial).\n`;
}
