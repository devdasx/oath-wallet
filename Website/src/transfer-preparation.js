// Shared by the static guide build and the Worker's exact-asset deep links.
// All values come from the accepted catalog; no live provider or wallet access.
export const transferPath = '/networks/choose-token-network';
const h = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export const transferKey = asset => asset.path.split('/')[3];
export const transferSlug = asset => asset.path.split('/')[2];
export const transferURL = asset => `${transferPath}?token=${encodeURIComponent(transferSlug(asset))}&network=${encodeURIComponent(transferKey(asset))}#prepare-transfer`;
export const identifierLabel = network => ({solana:'Token mint',ton:'Jetton master',stellar:'Contract or asset and issuer',xrpl:'Currency and issuer',near:'Token account',aptos:'Coin type or fungible asset',sui:'Coin type',polkadot:'Asset reference',thorchain:'Asset denomination'}[network] || 'Token contract');

export function preparationMarkdown(html) {
  return html.replace(/<div class="decision-controls[\s\S]*?<\/div><noscript>/g, '<noscript>')
    .replace(/<fieldset[\s\S]*?<\/fieldset>|<noscript>[\s\S]*?<\/noscript>/g, '')
    .replace(/<a\b[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/g, (_,u,t) => `[${t}](${u.startsWith('/') ? 'https://oathwallet.org' : ''}${u})`)
    .replace(/<h([1-6])[^>]*>(.*?)<\/h\1>/g, (_,n,t) => '\n\n'+'#'.repeat(+n)+' '+t+'\n\n')
    .replace(/<li[^>]*>/g, '\n- ').replace(/<dt>/g, '\n**').replace(/<\/dt>/g, '**\n\n')
    .replace(/<code[^>]*>(.*?)<\/code>/g, '`$1`').replace(/<\/(?:p|article|section|header|nav|div|dl|dd|ol|ul)>/g, '\n\n')
    .replace(/<[^>]+>/g, '').replace(/&(?:amp|lt|gt|quot|#39);/g, s => ({'&amp;':'&','&lt;':'<','&gt;':'>','&quot;':'"','&#39;':"'"}[s]))
    .replace(/\n{3,}/g,'\n\n').trim();
}

export function renderTransferPreparation(assets, networks, selectedPath = '') {
  const selected = assets.find(a => a.path === selectedPath);
  if (selectedPath && !selected) throw Error('Selection is outside the accepted catalog');
  const groups = [...new Map(assets.map(a => [transferSlug(a), a])).values()];
  const catalogIntro = groups.length === 1
    ? 'This checklist covers one catalog asset group. To prepare a different token, <a href="/tokens">find it in the catalog</a> and use its “Prepare a transfer” link.'
    : 'Start with USDT or USDC here, or <a href="/tokens">find another token</a> and use its “Prepare a transfer” link.';
  const controls = `<div class="decision-controls transfer-controls" hidden><div><label for="transfer-token">1. Token</label><select id="transfer-token"><option value="">Choose a token</option>${groups.map(a => `<option value="${h(transferSlug(a))}"${selected && transferSlug(a) === transferSlug(selected) ? ' selected' : ''}>${h(a.name)} (${h(a.symbol)})</option>`).join('')}</select></div><div><label for="transfer-network">2. Network and token version</label><select id="transfer-network"${selected ? '' : ' disabled'}><option value="">Choose the sender’s network</option>${assets.map(a => {const n = networks[a.network], duplicate = assets.filter(b => transferSlug(b) === transferSlug(a) && b.network === a.network).length > 1; return `<option value="${h(a.path)}" data-token="${h(transferSlug(a))}"${a.path === selectedPath ? ' selected' : ''}>${h(n.name)}${duplicate ? ' · ' + h(a.reference) : ''}</option>`;}).join('')}</select></div><button type="button" data-transfer-reset>Clear selection</button><p class="transfer-status" data-transfer-count role="status" aria-live="polite"></p></div>`;
  const cards = assets.map(a => {
    const n = networks[a.network];
    if (!n) throw Error('Unknown transfer network');
    return `<article class="decision-card transfer-card" data-transfer-token="${h(transferSlug(a))}" data-transfer-path="${h(a.path)}"${selected && a.path !== selectedPath ? ' hidden' : ''}><p class="decision-label">${h(n.name)} · ${h(a.symbol)}</p><h3>${h(a.name)} on ${h(n.name)}</h3><dl class="transfer-identity"><dt>${identifierLabel(a.network)}</dt><dd><code dir="ltr">${h(a.reference)}</code></dd><dt>Catalog asset ID</dt><dd>${h(a.coinID)}</dd><dt>Fee asset on this network</dt><dd><strong>${h(n.symbol)} on ${h(n.name)}</strong></dd></dl><p class="transfer-notice"><strong>This token identifier is not your receiving address.</strong> Copy your own receiving address from Oath. Never send funds to the contract, mint or issuer above.</p><h4>Receive in Oath</h4><ol><li>Open your wallet in Oath and choose Receive.</li><li>Select ${h(n.name)} and find ${h(a.name)} (${h(a.symbol)}). Match the full identifier, not just the symbol.</li><li>Copy the receiving address or show its QR code. Include any required memo or tag, and confirm that the sender supports this exact network and asset.</li></ol><p>${h(n.receive)}</p><h4>Prepare for a later send</h4><p>${h(n.send)}</p><p>Review Oath’s final fee and account requirements before confirming. This page does not quote live fees or check your balance. Catalog inclusion does not establish that every token can be sent; account type, token restrictions and extensions can limit transfers.</p><p><a href="${h(a.path)}">Full ${h(a.symbol)} identity and receiving guide</a> · <a href="/networks/fees#${h(n.slug)}">${h(n.name)} fee requirements</a></p></article>`;
  }).join('');
  return `<!-- oath-transfer-tool:start --><section id="prepare-transfer" class="transfer-tool${selected ? ' transfer-selected' : ''}" aria-labelledby="transfer-title"><p class="decision-label">Before you send</p><h2 id="transfer-title">Prepare your transfer.</h2><p>Choose the token and the network offered by the sender. Compare its exact identity, get your receiving address in Oath, and plan for network fees.</p><p>${catalogIntro} A matching symbol or address alone does not establish compatibility.</p>${controls}<noscript><p>${selected ? 'Your selected token and network are shown below. Open the full token catalog to choose another asset.' : 'All entries are listed below. Each includes its exact identity, receiving steps and fee requirements.'}</p></noscript><div class="decision-grid transfer-grid">${cards}</div><fieldset class="transfer-review" hidden><legend>3. Review at the sender</legend><p>These are your own checks. Oath’s website cannot verify the sender, receiving address or a transfer.</p><label><input type="checkbox"> The sender offers this exact network and token identifier.</label><label><input type="checkbox"> I copied the receiving address from Oath on this network and checked any memo or tag.</label><label><input type="checkbox"> I reviewed the sender’s withdrawal terms and my network fee requirements.</label><p data-transfer-review-status role="status" aria-live="polite">Complete each check before confirming in the sending app.</p></fieldset></section><!-- oath-transfer-tool:end -->`;
}
