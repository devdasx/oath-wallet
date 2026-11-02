import {readFile, writeFile} from 'node:fs/promises';
const root=new URL('../public/',import.meta.url);
const esc=s=>s.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');
const demos=[
  {
    "slug": "bitcoin-settings-oath-address-types-indexes-complete-guide",
    "title": "Bitcoin: know the address and recovery scope",
    "steps": [
      [
        "Match the address family",
        "Use the Bitcoin address types offered for the imported material. Compatible wallets include Native SegWit, Taproot, nested SegWit and Legacy.",
        "8c0eb4d1197a-oath-bitcoin-bip84-account.webp",
        "Historical example account view, not a screenshot of the current 5.0.0 interface."
      ],
      [
        "Understand receiving addresses",
        "A fresh HD receiving address can belong to the same wallet. A single key or scoped extended key has narrower recovery scope.",
        "e0d625b2de16-oath-bitcoin-receive-address-chain.webp",
        "Historical receive inventory. Never fund demonstration addresses."
      ],
      [
        "Recognize change",
        "Change returns unspent value to an address controlled by the wallet. Generated addresses are not evidence of received funds.",
        "2a8518258f36-oath-bitcoin-change-address-chain.webp",
        "Historical change inventory from an empty demonstration wallet."
      ],
      [
        "Check current limits",
        "Silent Payments receiving and discovery are not supported in 5.0.0. Preserve the original format, account information and any required passphrase.",
        null,
        "Correct network \u2192 Your own address \u2192 Supported recovery."
      ]
    ]
  }
];
for (const d of demos) {
  const steps=d.steps.map(([title,text,img,caption],i)=>`<div class="walkthrough-step" data-step><div class="walkthrough-copy"><p class="walkthrough-kicker">${i+1} / ${d.steps.length}</p><h3>${esc(title)}</h3><p>${esc(text)}</p></div>${img?`<figure><img src="/assets/articles/${img}" alt="${esc(caption)}" width="${img.includes('e9fe')?1320:1206}" height="${img.includes('e9fe')?2868:2622}" loading="lazy" decoding="async"><figcaption>${esc(caption)}</figcaption></figure>`:`<p class="walkthrough-check">${esc(caption)}</p>`}</div>`).join('');
  const demo=`<!-- oath-walkthrough:start --><section class="oath-walkthrough" id="visual-walkthrough" aria-labelledby="walkthrough-title"><p class="walkthrough-kicker">Four-step visual walkthrough</p><h2 id="walkthrough-title">${esc(d.title)}</h2><p class="walkthrough-scope">Guidance checked against 5.0.0 (102) source on November 2, 2026. Any included app screenshots are historical examples. This is an illustrated guide, not a recording of a current App Store test. No wallet is connected.</p>${steps}<nav class="walkthrough-controls" aria-label="Walkthrough steps" hidden><button type="button" data-prev>Previous</button><span data-progress role="status" aria-live="polite" aria-atomic="true">Step 1 of 4</span><button type="button" data-next>Next step</button></nav><p class="walkthrough-source"><a href="/security">Security and release limitations</a> · <a href="/articles/backup-restore-oath-wallet">Recovery requirements</a></p></section><!-- oath-walkthrough:end -->`;
  const file=new URL('articles/'+d.slug+'.html',root);
  let html=await readFile(file,'utf8');
  html=html.replace(/<!-- oath-walkthrough:start -->[\s\S]*?<!-- oath-walkthrough:end -->/,'');
  const update=html.match(/<section class="guide-update"[\s\S]*?<\/section>/);
  if(!update)throw new Error('Guide update section missing: '+d.slug);
  html=html.replace(update[0],update[0]+demo);
  if(!html.includes('href="/walkthrough.css"'))html=html.replace('</head>','<link rel="stylesheet" href="/walkthrough.css"><script src="/walkthrough.js" defer></script></head>');
  if(!html.includes('<a href="#visual-walkthrough">'))html=html.replace('<ol><li><a href="#current-guidance">','<ol><li><a href="#visual-walkthrough">Visual walkthrough</a></li><li><a href="#current-guidance">');
  await writeFile(file,html);
  const mdfile=new URL('articles/'+d.slug+'.md',root);
  let md=await readFile(mdfile,'utf8');
  md=md.replace(/\n<!-- oath-walkthrough:start -->[\s\S]*?<!-- oath-walkthrough:end -->\n/,'\n');
  md=md.trimEnd()+'\n\n<!-- oath-walkthrough:start -->\n## '+d.title+' — visual walkthrough transcript\n\nGuidance checked against 5.0.0 (102) source on November 2, 2026. Included screenshots are historical examples. This is an illustrated guide, not a recording of a current App Store test.\n\n'+d.steps.map(([title,text],i)=>`### ${i+1}. ${title}\n\n${text}`).join('\n\n')+'\n\n[Open the visual walkthrough](https://oathwallet.org/articles/'+d.slug+'#visual-walkthrough)\n<!-- oath-walkthrough:end -->\n';
  await writeFile(mdfile,md);
}
console.log('Built supported illustrated walkthroughs with readable transcripts.');
