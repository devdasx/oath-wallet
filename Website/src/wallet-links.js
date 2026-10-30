// Public iOS association metadata. No pairing data is stored or forwarded.
export const walletAssociation = {
  applinks: { apps: [], details: [{
    appID: 'C5T44SZNQX.com.aperture.wallet',
    paths: ['/wc', '/wc/']
  }] }
};

export function handleWalletLinks(request) {
  const url = new URL(request.url);
  if (url.hostname !== 'oathwallet.org' || url.protocol !== 'https:') return null;
  const association = ['/.well-known/apple-app-site-association', '/apple-app-site-association'].includes(url.pathname);
  const landing = ['/wc', '/wc/'].includes(url.pathname);
  if (!association && !landing) return null;
  if (!['GET', 'HEAD'].includes(request.method)) return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
  if (association) return new Response(request.method === 'HEAD' ? null : JSON.stringify(walletAssociation), {
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=3600', 'X-Content-Type-Options': 'nosniff' }
  });
  // Deliberately bypass the site's analytics/newsletter injection. A WC URI
  // contains a pairing secret: never interpolate it into HTML or third-party links.
  return new Response(request.method === 'HEAD' ? null : landingHTML, { headers: {
    'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store',
    'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff',
    'X-Robots-Tag': 'noindex, nofollow',
    'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
  } });
}

const landingHTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer"><meta name="robots" content="noindex,nofollow">
<title>Open Oath Wallet</title><link rel="stylesheet" href="/wallet-open.css"><script src="/wallet-open.js" defer></script>
</head><body><main><img src="/wallet-logo.png" width="104" height="104" alt="Oath Wallet">
<h1>Open Oath Wallet</h1><p id="message">Review your connection in Oath Wallet, then return to your app.</p>
<a class="primary" id="open-wallet" href="oathwallet://">Open Oath Wallet</a>
<a class="secondary" href="https://apps.apple.com/us/app/oath-bitcoin-crypto-wallet/id6780187283" rel="noreferrer">Get Oath Wallet</a>
<p class="note">If Oath is not installed, download it first and start the connection again from your app.</p>
<noscript><p>Enable JavaScript to pass this connection to Oath Wallet, or scan the QR code from your other device.</p></noscript>
</main></body></html>`;
