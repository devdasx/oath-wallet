from pathlib import Path
import json
R=Path(__file__).resolve().parents[2];app=Path('/Volumes/MacOSDisk/Oath App');D=json.loads((R/'content/help/update-2026-10-16.json').read_text());old=json.loads((R/'Reports/help-update-2026-10-12/coverage.json').read_text());old={a['slug']:a['sources'] for a in old}
base='OathAtmosphere/'
groups={
 'send':['Send/OathSendFlow.swift','Send/OathSendModel.swift','Send/OathSendRecipientPage.swift','Send/OathSendAmountPage.swift','Send/OathSendReviewPage.swift'],
 'wc':['Scanner/OathWalletConnectPage.swift','Scanner/OathWalletConnectConsent.swift','Scanner/OathWalletConnectEVMViews.swift','Scanner/OathWalletConnectCallDetails.swift','Scanner/OathWalletConnectRequestViews.swift'],
 'permissions':['Permissions/OathPermissionsPage.swift','Permissions/OathPermissionsModel.swift','Permissions/OathPermissionReview.swift','Permissions/OathPermissionBatchReview.swift','Permissions/OathPermissionBatchCoordinator.swift'],
 'assets':['Assets/OathAssetDetailScreen.swift','Assets/OathAssetInformationSheet.swift','Tokens/OathTokenNetwork.swift'],
}
new={
 'send-max-and-fees':groups['send'], 'send-tags-and-memos':groups['send']+['Send/OathSendRecipientRules.swift'],
 'bitcoin-transfer-options':groups['send']+['Send/OathSendOptionsSheet.swift'], 'send-troubleshooting':groups['send']+['Send/OathSendAccountHelp.swift'],
 'connect-dapp':groups['wc'],'dapp-disconnect':groups['wc'],'dapp-swap':groups['wc'],'dapp-transaction-data':groups['wc'],'dapp-signatures':groups['wc']+['Scanner/OathWalletConnectTypedReview.swift'],
 'walletconnect-solana':groups['wc']+['Scanner/OathWalletConnectSolanaViews.swift'], 'walletconnect-thorchain':groups['wc']+['Scanner/OathWalletConnectThorchainViews.swift'],
 'revoke-token-access':groups['permissions'],'bulk-revoke-access':groups['permissions'],'permission-coverage':groups['permissions'],
 'check-contract-access':groups['permissions']+['Permissions/OathPermissionContractPage.swift'],'permit2-access':groups['permissions'],
 'permission-removal-history':groups['permissions'],'account-control-permissions':groups['permissions'],
 'last-wallet-reset':['Wallet/OathWalletRemovalModel.swift','Wallet/OathWalletSession.swift','Home/OathWalletSheets.swift'],
 'upgrade-existing-wallets':['Wallet/OathLegacyUpgrade.swift','Wallet/OathLegacyUpgradeScreen.swift'],
 'balance-change':['Home/OathHomeScreen.swift','Wallet/OathWalletSession.swift'],
 'asset-filters':['Home/OathAssetFilterSheet.swift','Home/OathHomeScreen.swift'],
 'token-prices-and-logos':['Tokens/OathTokenSearchModel.swift','Tokens/OathTokenService.swift','Assets/OathAssetDetailModel.swift'],
 'haptic-feedback':['Home/OathWalletSheets.swift','Shared/OathAppSettings.swift'],
}
for key in ['use-thorchain','use-hyperevm','use-monad','use-unichain']:new[key]=groups['assets']+groups['send']
coverage=[]
for a in D['articles']:
 sources=old.get(a['slug'],[])+[base+s for s in new.get(a['slug'],[])]
 if a['slug']=='create-wallet':sources+=['OathApp/OathAtmosphereApp.swift']
 if a['slug']=='send-availability':sources +=[base+s for s in groups['send']]
 if a['slug']=='permissions':sources +=[base+s for s in groups['permissions']]
 sources=list(dict.fromkeys(sources));missing=[s for s in sources if not (app/s).exists()]
 coverage.append(dict(slug=a['slug'],title=a['title'],sources=sources,source_paths_missing=missing,review='Source review plus actual app-view captures with synthetic data; no live payment or cloud-backup claim.'))
(R/'Reports/help-update-2026-10-16/coverage.json').write_text(json.dumps(coverage,indent=2)+'\n')
print('Missing:',[(c['slug'],c['source_paths_missing']) for c in coverage if c['source_paths_missing']]);print('No sources:',[c['slug'] for c in coverage if not c['sources']])
