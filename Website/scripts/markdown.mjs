export const escape = value => value.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
function inline(value) {
  // Only authored HTTP(S), mailto and same-site destinations become links.
  return value.split(/(\[[^\]]+\]\([^)]+\))/g).map(part => {
    const match = part.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
    if (match && /^(https?:\/\/|mailto:|\/(?!\/)|#)/.test(match[2])) return `<a href="${escape(match[2])}">${escape(match[1])}</a>`;
    return escape(part).replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>').replace(/`([^`]+)`/g,'<code>$1</code>').replace(/(?<!\w)_([^_]+)_(?!\w)/g,'<em>$1</em>');
  }).join('');
}
export function renderMarkdown(markdown, renderImage) {
  return markdown.replace(/<!--[\s\S]*?-->/g,'').trim().split(/\n\s*\n/).map(block => {
    const image = renderImage && block.match(/^!\[([^\]]+)\]\(([^)]+)\)$/);
    if (image) return renderImage(image[1], image[2]);
    const heading = block.match(/^(#{1,4}) ([^\n]+)$/);
    if (heading) return `<h${heading[1].length}>${inline(heading[2])}</h${heading[1].length}>`;
    if (/^[-*] /.test(block)) return '<ul>'+block.split('\n').map(row=>'<li>'+inline(row.replace(/^[-*] /,''))+'</li>').join('')+'</ul>';
    if (/^\d+\. /.test(block)) return '<ol>'+block.split('\n').map(row=>'<li>'+inline(row.replace(/^\d+\. /,''))+'</li>').join('')+'</ol>';
    if (block.startsWith('|')) {
      const rows=block.split('\n').filter(row=>!/^\|[\s:|-]+\|$/.test(row));
      return '<div class="oath-readable-table"><table>'+rows.map((row,i)=>'<tr>'+row.replace(/^\||\|$/g,'').split('|').map(cell=>`<${i?'td':'th'}>${inline(cell.trim())}</${i?'td':'th'}>`).join('')+'</tr>').join('')+'</table></div>';
    }
    return '<p>'+inline(block.replace(/\n/g,' '))+'</p>';
  }).join('\n');
}
