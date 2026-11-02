import catalog from '../public/oath-data.json' with {type:'json'};
// Published articles and supported legacy aliases.
export const archiveRoutes = {
  "/articles/open-source-wallets-verifiable-builds": "/articles/open-source-wallets-verifiable-builds.html",
  "/articles/bitcoin-settings-oath-address-types-indexes-complete-guide": "/articles/bitcoin-settings-oath-address-types-indexes-complete-guide.html",
  "/articles/why-oath-has-no-swaps-perps-web3-walletconnect": "/articles/why-oath-has-no-swaps-perps-web3-walletconnect.html",
  "/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security": "/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security.html",
  "/articles/add-custom-token-without-trusting-name-symbol": "/articles/add-custom-token-without-trusting-name-symbol.html",
  "/articles/lock-oath-down-passcode-face-id-auto-lock-app-switcher-privacy": "/articles/lock-oath-down-passcode-face-id-auto-lock-app-switcher-privacy.html",
  "/articles/what-never-leaves-iphone-oath-self-custody-security-model": "/articles/what-never-leaves-iphone-oath-self-custody-security-model.html",
  "/articles/receive-crypto-safely-network-address-qr-requested-amounts": "/articles/receive-crypto-safely-network-address-qr-requested-amounts.html",
  "/articles/why-bitcoin-wallets-generate-fresh-receiving-addresses": "/articles/why-bitcoin-wallets-generate-fresh-receiving-addresses.html",
  "/articles/one-wallet-many-mainnets-accounts-networks-separate": "/articles/one-wallet-many-mainnets-accounts-networks-separate.html",
  "/articles/recovery-phrase-private-key-icloud-iphone-transfer-import": "/articles/recovery-phrase-private-key-icloud-iphone-transfer-import.html",
  "/articles/where-crypto-network-fees-actually-go": "/articles/where-crypto-network-fees-actually-go.html",
  "/articles/backup-restore-oath-wallet": "/articles/backup-restore-oath-wallet.html",
  "/articles/add-bip39-passphrase-oath-wallet": "/articles/add-bip39-passphrase-oath-wallet.html",
  "/bn/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security": "/bn/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security.html",
  "/ru/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security": "/ru/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security.html",
  "/es/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security": "/es/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security.html",
  "/ja/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security": "/ja/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security.html",
  "/ur/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security": "/ur/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security.html",
  "/zh-Hans/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security": "/zh-Hans/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security.html",
  "/id/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security": "/id/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security.html",
  "/de/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security": "/de/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security.html",
  "/fr/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security": "/fr/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security.html",
  "/hi/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security": "/hi/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security.html",
  "/ko/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security": "/ko/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security.html",
  "/pt-BR/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security": "/pt-BR/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security.html",
  "/tr/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security": "/tr/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security.html",
  "/ar/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security": "/ar/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security.html",
  "/vi/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security": "/vi/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security.html",
  "/articles/bitget-388-million-hack-self-custody": "/articles/bitget-388-million-hack-self-custody.html"
};

export const articleRoutes = {...archiveRoutes};
for (const article of catalog.articles.filter(a => a.github_editorial)) {
  const route = '/articles' + new URL(article.url).pathname;
  articleRoutes[route] = route + '.html';
}
