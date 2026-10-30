(() => {
  const url = new URL(window.location.href);
  // Keep any pairing secret only in this page's memory, not browser history or referrers.
  window.history.replaceState(null, '', url.pathname);
  const button = document.getElementById('open-wallet');
  const message = document.getElementById('message');
  if (!url.search) return;
  const items = [...url.searchParams];
  let uri = url.searchParams.get('uri');
  const keys = new Set(['symKey', 'relay-protocol', 'relay-data', 'expiryTimestamp']);
  const unique = new Set(items.map(([name]) => name)).size === items.length;
  if (items.length > 1 && items[0]?.[0] === 'uri' && uri?.startsWith('wc:') && uri.includes('?') &&
      unique && items.slice(1).every(([name]) => keys.has(name))) {
    try { uri = decodeURIComponent(url.search.slice(5)); } catch { uri = null; }
  } else if (items.length !== 1 || items[0]?.[0] !== 'uri') { uri = null; }
  // Full protocol validation happens again inside the wallet before pairing.
  if (!uri || url.hash || uri.length > 8192 || !/^wc:[a-fA-F0-9-]+@2(?:\?|$)/.test(uri) || /[\u0000-\u0020]/.test(uri)) {
    button.removeAttribute('href'); button.setAttribute('aria-disabled', 'true');
    message.textContent = 'This connection link is invalid. Return to your app and start a new connection.';
    return;
  }
  button.href = 'oathwallet://wc?uri=' + encodeURIComponent(uri);
})();
