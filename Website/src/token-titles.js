// Shared by the published pages, catalog build and deployment verification.
// Preserve the released name, including wrapped/bridged qualifiers. The title
// describes the page's transfer guidance, not individually verified sending.
export function tokenLabel(asset) {
  const name=asset.name.trim(),symbol=asset.symbol.trim();
  const lower=name.toLocaleLowerCase('en'),ticker=symbol.toLocaleLowerCase('en');
  return lower===ticker||lower.endsWith(`(${ticker})`)?name:`${name} (${symbol})`;
}

export function tokenPageTitle(asset,network) {
  const subject=tokenLabel(asset),location=network?` on ${network.name}`:'';
  const qualifier=asset.titleQualifier?` [${asset.titleQualifier}]`:'';
  const candidates=[
    `${subject} Wallet${location}${qualifier}: Send & Receive on iPhone | Oath`,
    `${subject} Wallet${location}${qualifier}: Send & Receive | Oath`,
    `${subject}${location}${qualifier}: Send & Receive | Oath`,
    `${subject}${location}${qualifier} | Oath`
  ];
  // An editorial target, not a Google character limit. Shorten the surrounding
  // wording before considering a long name; never truncate the asset identity.
  return candidates.find(title=>Array.from(title).length<=100)||candidates.at(-1);
}
