from pathlib import Path
import json
R=Path(__file__).resolve().parents[2];P=R/'content/help/update-2026-10-16.json'
d=json.loads(P.read_text());A={a['slug']:a for a in d['articles']};W=json.loads((R/'src/help/walkthroughs.json').read_text())
# Preserve collection URLs while making current actions discoverable.
for c in d['categories']:
 if c['id']=='receive':c.update(title='Send & receive',description='Choose the right network, review a transfer and share an address.')
if not any(c['id']=='dapps' for c in d['categories']):d['categories'].append(dict(id='dapps',title='dApps & permissions',description='Connect apps, understand requests and revoke supported access.',icon='arrows',sort_order=8))
for a in d['articles']:
 if a['slug'] in ['send-availability','send-max-and-fees','send-tags-and-memos','bitcoin-transfer-options','send-troubleshooting']:a['category_id']='receive'
 if a['slug'].startswith(('dapp-','walletconnect-','permission-')) or a['slug'] in ['permissions','connect-dapp','revoke-token-access','bulk-revoke-access','check-contract-access','permit2-access','account-control-permissions']:a['category_id']='dapps'
# The native Send review is distinct from a WalletConnect transaction request.
for slug in ['send-availability','send-max-and-fees','send-troubleshooting']:
 for shot in W[slug]:
  if shot['image']=='guide-wc-send':shot['image']='guide-send-review'
W['dapp-transaction-data']=[dict(image='guide-call-details'),dict(image='guide-wc-contract')]
A['dapp-transaction-data']['screenshot']='guide-call-details'
# Clarify the two confirmations are completed before any final-wallet deletion.
A['last-wallet-reset']['steps']=[
 'Confirm you can recover the final wallet and any wallets in Recently Deleted before starting.',
 'Choose remove for the last active wallet. Complete the applicable security authentication when asked.',
 'If Recently Deleted contains wallets, review the first prompt and agree to include those wallets in permanent removal only if you have their required recovery material.',
 'Read the final reset confirmation. Both confirmations must be accepted before deletion starts; cancel here if you need to preserve any wallet.',
 'Confirm the final removal and wait for the local reset to finish. Do not interpret the first confirmation alone as completed deletion.',
 'Oath returns to Welcome. To use a wallet again, import its recovery material or restore an encrypted backup.'
]
A['create-wallet']['steps']=[
 'On Welcome, choose Create a new wallet. To restore an existing wallet instead, choose Import wallet or Restore from iCloud.',
 'Create a six-digit app passcode and enter it again to confirm. Complete biometric setup if offered and desired.',
 'On Customize Wallet, enter a recognizable name and choose a color. Tap Continue to open the wallet.',
 'Check the wallet name on Home, then open Receive for the network you intend to use. Do not fund an example address from a help screenshot.',
 'Open the wallet’s settings and make a recovery backup before receiving funds. Keep the recovery phrase and any passphrase separately from the phone.',
 'Return to Home and allow balances and activity to refresh. A brand-new wallet can correctly show no activity and zero balances.'
]
A['import-recovery-phrase']['steps'] += ['After import, open Receive on the original network and compare the full public address with your previous wallet. Use a supported address/path choice if the original account requires it.','Wait for balances and history to refresh. If an address differs, check recovery language, word order, additional passphrase and supported account rules; importing a valid phrase alone does not prove it is the intended account.']
A['import-private-key']['steps'] += ['Open Receive for the chosen network and compare the full address with the original account. Do not rely only on its nickname or logo.','Keep the original key or a verified encrypted backup. Allow fresh network data to load; importing does not transfer any funds on-chain.']
extra={
 'add-another-wallet':['After adding, confirm the active wallet in Home’s toolbar before sending or sharing a receiving address. A wallet list can contain similar names with different keys.'],
 'asset-screen':['Asset actions are scoped to the displayed account, asset and network. Open Asset Information to compare the complete token identity before using Receive or Send.'],
 'copy-share-address':['Copy address supplies the full value even if another screen abbreviates it. After pasting, compare the beginning, end and complete destination with the original before the sender confirms.','The share sheet sends only after you choose a destination and finish that app’s action. Canceling it does not create a payment request or transfer.'],
 'receive-network-tokens':['A token on Ethereum and the similarly named token on another chain have separate balances. Match the actual deployment and network at the sending service.','The list is explanatory rather than an exhaustive worldwide token registry. An unknown asset can require manual discovery, and unsupported standards may not offer a send flow.'],
 'app-switcher-privacy':['This guide shows the setting screen. Its explanatory subtitle may differ between installed versions; the current privacy cover blurs the app preview.']
}
for slug,paras in extra.items():A[slug]['body']=list(dict.fromkeys(A[slug]['body']+paras))
CAP={
 '01-portfolio':('Home with a synthetic portfolio','Check the active wallet in the toolbar, then use Send, Receive, asset filters or the bottom History and Search controls. Balances are illustrative.'),
 '02-bitcoin-market':('Bitcoin asset page and market chart','The asset page separates the owned quantity, market price/chart and account activity. This example uses synthetic market values.'),
 '03-activity':('History with sample transactions','History shows activity for the selected wallet. Open a row for its status, network, identifiers and fee; these rows are illustrative.'),
 '04-transaction':('Transaction details with asset badge and ellipsis','Read the amount and status separately. The ellipsis at the top contains screenshot sharing, link sharing and the explorer action.'),
 '05-receive':('Ethereum receiving QR and address','Read the network guidance beneath the QR, then copy or share the public address using the bottom buttons. Never fund this example address.'),
 '06-send-assets':('Send asset selection','Choose the exact asset and network before entering a recipient. This selection uses synthetic holdings.'),
 '07-wallets':('Wallet switcher with three example wallets','Names, colors, balances and the active badge distinguish wallets. Choose the intended wallet before starting an action.'),
 '08-dapp-swap':('WalletConnect swap review with two assets','Read the source and destination assets, network and minimum output in this illustrative unsigned swap request.'),
 '09-security':('Passcode and Face ID settings','Security settings group passcode, biometric, locking and app-switcher privacy controls. No authentication secret is shown.'),
 '10-app-icons':('Current Oath icon choices','Signal Blue is the default icon. Choose another listed variant to change the launcher icon.'),
 'welcome':('Oath Welcome screen','Choose creation for a new wallet, import for an existing phrase, or More Options for other supported recovery routes.'),
 'passcode':('Six-digit passcode setup','Enter and confirm your own app passcode privately. The screenshot shows an empty setup screen, not a usable passcode.'),
 'help-settings':('Oath Settings list','Open the appropriate settings row for wallets, backup, security, contacts, appearance or support.'),
 'help-wallet-details':('Settings for one example wallet','Check the wallet name before choosing customization, recovery, private-key, backup or removal actions.'),
 'help-customize':('Wallet name and color customization','Use a recognizable local name and color, then finish with the displayed confirmation control.'),
 'help-appearance':('Light Dark and System appearance choices','Select the appearance you prefer. Wallet color and the app icon are separate choices.'),
 'help-currency':('Display currency selection','Choose the currency used for available valuations. This does not exchange any coins or tokens.'),
 'help-language':('Language selection','Choose the interface language. Network names, symbols, addresses and transaction IDs remain asset identifiers.'),
 'help-backup':('Backup page showing iCloud unavailable','This simulator has no iCloud account, so it shows the real unavailable state. This is not a completed backup; use an eligible signed-in device to upload.'),
 'help-backup-password':('Empty encrypted-backup password form','Set and confirm the password for the encrypted backup. Empty fields are shown deliberately; the screenshot does not demonstrate an upload.'),
 'help-restore':('Restore from iCloud unavailable state','A device without an available iCloud account cannot list and restore backups. After resolving availability, select the actual file and supply its original password.'),
 'help-import':('Empty recovery phrase import form','Enter words privately in their original order, or use Paste or the scan control. Recovery words are deliberately absent from all screenshots.'),
 'help-key-networks':('Private-key import network choices','Choose the network that matches the original key export before entering any key.'),
 'key-import':('Empty Ethereum and EVM private-key import','The import form validates the format for the selected network. No private-key value is shown.'),
 'help-passphrase':('Additional BIP-39 passphrase flow','Select the appropriate recovery-phrase wallet before creating its passphrase-derived wallet.'),
 'help-passphrase-entry':('Empty BIP-39 passphrase fields','The additional passphrase changes the derived wallet. Enter the exact value privately and keep it with your recovery plan.'),
 'help-about':('About and support links','Use the version and official support, help, privacy and terms links when reporting an issue or checking the installed release.'),
 'help-contacts':('Address book with a synthetic contact','Saved contacts hold network-specific public destinations. Verify the address even when a name is familiar.'),
 'contact-editor':('New contact form','Enter a recognizable name and add the intended public destination. Cancel if its ownership or network is uncertain.'),
 'contact-address':('Contact network and address editor','Save the destination under its correct network and label. The address in this example is demonstration data.'),
 'help-recently-deleted':('Recently Deleted with a selected example wallet','Read the deletion deadline. Restore returns retained wallets; Delete Permanently closes this local recovery route after confirmation.'),
 'help-dapps':('Connected apps list with a demonstration connection','Open a connection to inspect approved access or disconnect it. This is an offline demo session, not a live connected site.'),
 'help-permissions':('Permissions overview','Choose Token access, NFT access, Account control, Connected apps, Coverage or removal history as appropriate for the selected wallet.'),
 'help-autolock':('Auto-lock timing choices','Choose a supported delay. Sensitive actions may still require their own authentication.'),
 'asset-filters':('Home asset filters','Choose the network and supported asset filters, then return to the list to see the scoped result.'),
 'asset-info':('Ethereum asset information','Use asset information to confirm the network and asset identity before following project or explorer links.'),
 'asset-search':('Wallet asset search','Use Wallet search for an asset name or exact supported token identity. A token symbol alone does not establish its network.'),
 'token-review':('USD Coin contract review on Ethereum','Review the network, full contract reference, name and symbol before adding a token. A logo is not a security guarantee.'),
 'history-filters':('Native transaction filter sheet','Choose the desired transaction filters and review the resulting scope. Filtering hides rows; it does not remove on-chain transactions.'),
 'history-search':('History transaction search','History search is scoped to transactions. Clear the query or filters when a known entry is not visible.'),
 'receive-about':('About the receiving address','Read the network-specific receiving explanation before sharing the address or adding an unfamiliar token.'),
 'receive-bitcoin':('Bitcoin receive screen','Check the selected Bitcoin address and type before copying or sharing it. Do not fund this demonstration address.'),
 'receive-bitcoin-types':('Bitcoin address-type selector','Choose one of the address formats actually supported by this wallet. Imported keys can expose fewer choices.'),
 'receive-solana':('Solana receive screen','Use the displayed Solana address for the selected account and path, and verify the sender’s network.'),
 'receive-solana-types':('Solana derivation-path selector','Compare the Phantom and Trust Wallet account conventions where available, then verify the resulting public address.'),
 'recovery-warning':('Recovery material safety gate','The capture stops before recovery material is revealed. Authenticate and view your own secret only in a private place.'),
 'send-recipient':('Ethereum recipient entry','Paste, scan or select a public recipient, then verify its complete address and the network before continuing.'),
 'send-amount':('Native Send amount keypad','Enter the asset amount, inspect the available balance and use Max or the local-currency switch only when appropriate.'),
 'send-options':('Bitcoin transfer options','Review Replace by fee and the optional public on-chain message. A message is public and adds transaction data and possible fees.'),
 'send-review':('Native Ethereum transfer review','Review the recipient, asset amount and estimated fee before confirming. This is an unsigned mock transfer; no payment occurred.'),
 'solana-dapp':('Solana Devnet message review','The request explicitly identifies Solana Devnet. This unsigned demonstration message does not prove a testnet transaction or swap completed.'),
 'permission-list':('Token permissions grouped by network','Read the asset and approved contract within its network group. Example allowances are synthetic.'),
 'permission-select':('Permission selection with Revoke All','Select only the intended removable entries, check the count and use Revoke All to prepare a batch review.'),
 'permission-check':('Check a contract form','Choose the network and access type, then enter the token or collection reference and approved address. Empty fields are shown.'),
 'permission-review':('Token-access revocation review','Inspect the asset, approved address and fee before authorizing removal. This is an unsigned demo revocation.'),
 'wc-connect':('WalletConnect connection proposal','Inspect the site identity, wallet, requested networks and access before connecting. This proposal is an offline fixture.'),
 'wc-unverified':('Unverified WalletConnect proposal','Read verification warnings and decline a request if you cannot establish the site’s identity and purpose.'),
 'wc-connected':('Illustrative WalletConnect connection confirmation','A connection confirmation concerns approved public accounts. Each later signature or transfer needs its own review.'),
 'wc-contract':('Unknown contract interaction review','When an action cannot be fully decoded, inspect the contract and original data. Do not assume an unknown request is a harmless transfer.'),
 'call-details':('Human-readable decoded swap details','Known contract data can show the assets, network and ordered actions. Inspect the technical data when details are incomplete.'),
 'wc-approve':('dApp token approval review','Review the spender and allowance limit. This unsigned example does not grant permission on-chain.'),
 'wc-signin':('Readable dApp sign-in message','Compare the account, domain, network and message purpose before signing. This is a demonstration sign-in request.'),
 'wc-permit2':('Permit2 signature review','Read the token, spender, amount, expiry and other displayed limits. A signature can authorize later token spending.'),
 'wc-crossSwap':('THORChain cross-chain swap request','Check the source and destination networks, asset and memo. A source confirmation is not proof of the destination payout.'),
 'wc-thor':('THORChain dApp transaction review','Review the THORChain account, RUNE amount, recipient or deposit instruction and memo before authorizing.'),
 'wc-gas':('Network-fee balance guidance','Use the exact required network and native fee asset. The example guidance is not a request to fund a help-center address.'),
 'wc-pending':('Illustrative pending transaction state','Pending is not confirmed. Check the same transaction identifier before submitting another request.'),
 'wc-send':('WalletConnect transaction review','A dApp-originated transaction requires its own review. This screenshot contains an unsigned example request.'),
 'wc-simulation':('Transaction simulation failure guidance','A failed check needs investigation. Recheck the route, amount, fees and dApp request instead of assuming it is safe to retry.'),
}
names={'aptos':'Aptos','arc':'Arc','bitcoin-cash':'Bitcoin Cash','dogecoin':'Dogecoin','ethereum':'Ethereum','hyperevm':'HyperEVM','litecoin':'Litecoin','monad':'Monad','near':'NEAR Protocol','robinhood':'Robinhood Chain','solana':'Solana','stellar':'Stellar','sui':'Sui Network','thorchain':'THORChain','ton':'Gram','tron':'TRON','unichain':'Unichain','xrpl':'XRP Ledger'}
for key,name in names.items():CAP['chain-'+key]=(name+' asset screen',f'Open the {name} asset and verify its network before using Send or Receive. Displayed holdings and activity are illustrative; missing market data is not a zero asset balance.')
for slug,items in W.items():
 for shot in items:
  mode=shot['image'].removeprefix('guide-');shot['alt'],shot['caption']=CAP[mode]
 # Link the entry image back to the beginning of the actual steps, without inventing a one-image-per-tap sequence.
 items[0]['step']=1
 A[slug]['screenshot']=items[0]['image']
P.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n');(R/'src/help/walkthroughs.json').write_text(json.dumps(W,ensure_ascii=False,indent=2)+'\n')
(R/'Reports/help-update-2026-10-16/captions.json').write_text(json.dumps(CAP,ensure_ascii=False,indent=2)+'\n')
print(len(A),'guides;',len(d['categories']),'collections;',len({x['image'] for v in W.values() for x in v}),'screenshot states')
