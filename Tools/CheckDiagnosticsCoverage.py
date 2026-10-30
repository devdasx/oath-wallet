#!/usr/bin/env python3
"""Static guard against silently introducing unobserved failure boundaries.
Not a replacement for review or runtime tests. Exemptions are explicit below.
"""
from pathlib import Path
import re
import sys
import json
from GenerateDiagnosticSourceCatalog import DESTINATION, source_files

ROOT = Path(__file__).resolve().parents[1]
roots = [ROOT / 'OathApp', ROOT / 'OathAtmosphere'] + list((ROOT / 'Packages').glob('*/Sources'))
failures = []
observed = 0
# This is an exact source-name allowlist, never a regex exemption for anything
# resembling a filename. Keep it aligned with code as screens are added/removed.
if not DESTINATION.exists() or json.loads(DESTINATION.read_text()) != source_files():
    failures.append('Diagnostic source catalog is stale: run python3 Tools/GenerateDiagnosticSourceCatalog.py')
# Typed recovery paths: the transport/final boundary records real failures;
# these branches implement normal cancellation, feature probing or resumption.
expected = ('CancellationError', 'StoreError.staleSync', 'BitcoinError.inconsistentSnapshot',
            'SuiError.resourceExhausted', 'SuiError.cursorExpired', 'XrplError.accountMissing',
            'XrplError.rpc("invalidMarker")', 'NearError.accountMissing', 'StellarError.http(404)',
            'AptosError.http', 'AptosError.transport', 'AnkrError.http', 'TonError.paginationLoop',
            'RecoveryPassphraseError.tooLong', 'OathTokenLookupError.unavailable', 'UTXOAPIBudget.Deferred',
            'OathSendAmount.Failure', 'CocoaError.fileReadNoSuchFile', 'CocoaError.fileNoSuchFile')
for root in roots:
    for file in root.rglob('*.swift'):
        if file.name.startswith('._') or '.build' in file.parts or 'OathDiagnostics' in file.parts:
            continue  # Diagnostics internals must never report recursively.
        source = file.read_text()
        # Mask comments and literals while preserving offsets. Brace matching
        # prevents an unrelated later catch from satisfying an earlier one.
        literal = r'//[^\n]*|/\*[\s\S]*?\*/|"""[\s\S]*?"""|"(?:\\.|[^"\\])*"'
        code = re.sub(literal, lambda m: ''.join('\n' if c == '\n' else ' ' for c in m.group()), source)
        for match in re.finditer(r'\bcatch\b([^{}\n]*)\{', code):
            # Ignore comments mentioning "catch".
            prefix = source[source.rfind('\n', 0, match.start())+1:match.start()]
            if '//' in prefix:
                continue
            label = source[match.start(1):match.end(1)]
            level = 1; end = match.end()
            while end < len(code) and level:
                if code[end] == '{': level += 1
                elif code[end] == '}': level -= 1
                end += 1
            body = source[match.end():end]
            before = source[max(0,match.start()-160):match.start()]
            if 'OathDiagnostics.record(' in body or 'OathSendDiagnostics.shared.record(' in body:
                observed += 1
                continue
            if file.relative_to(ROOT).as_posix() == 'Packages/OathDatabase/Sources/OathDatabase/ArcSynchronizer.swift' and re.search(r'await self\.historyFailed\(error, ticket: ticket(?:, lane: lane)?\)', body):
                # Delegated reporting, not a blanket staleSync exclusion:
                # historyFailed checks ticket ownership, reports current-run
                # conflicts and records failure-write errors. Host regressions
                # cover both supersession and genuine cursor conflicts.
                observed += 1
                continue
            if any(kind in label for kind in expected):
                continue
            if file.relative_to(ROOT).as_posix() == 'Packages/OathDatabase/Sources/OathDatabase/XrplSynchronizer.swift' and label.strip() == 'XrplError.historyWindowExpired':
                continue  # Expected ANKR rolling-window cursor expiry; state/storage failures propagate to the reporting outer catch.
            if file.relative_to(ROOT).as_posix() == 'Packages/OathBitcoin/Sources/OathBitcoin/Electrum.swift' and label.strip() == 'is ElectrumTransactionAbsence' and 'diagnostics: optional-electrum-transaction-absence' in body:
                continue  # Exact optional lookup absence; strict reads, malformed replies and provider failures still report.
            if file.name == 'OathRecoveryPhraseScreen.swift' and 'let error as ElectrumMnemonicError' in label and 'diagnostics: electrum-form-validation' in body:
                continue
            if file.name == 'OathRecoveryPhraseScreen.swift' and label.strip() == 'let error as AezeedError' and 'diagnostics: aezeed-form-validation' in body:
                continue  # Exact local mnemonic/password/version validation; no provider or storage failures.
            if file.name == 'Permissions.swift' and 'diagnostics: permission-form-validation' in body:
                continue  # PermissionCheckInput only validates user fields locally; account/RPC failures remain outside this boundary.
            if file.relative_to(ROOT).as_posix() == 'Packages/OathBitcoin/Sources/OathBitcoin/BitcoinConnectRequest.swift' and 'diagnostics: bitcoin-connect-parameter-validation' in body and 'throw BitcoinConnectError.invalidRequest' in body:
                continue  # Rejected peer JSON only; service boundaries report provider and storage failures.
            if file.name == 'PolkadotConnectClient.swift' and 'diagnostics: polkadot-connect-permit-cleanup' in body and 'await permits.release(); throw error' in body:
                continue  # Cleanup rethrows unchanged; rpc reports the original failure.
            if file.name == 'BitcoinMultisig.swift' and 'diagnostics: multisig-form-validation' in body and label.strip() in (
                'let error as BitcoinMultisigError',
                'let error as BitcoinError where error == .invalidKey || error == .unsupportedKeyScope'):
                continue  # Exact threshold/key form validation; descriptor/signing failures report safe codes.
            if file.name == 'TronClient.swift'  and label.strip() == 'TronError.nonFungible':
                continue  # Positive ERC165 NFT classification, explicitly excluded from fungible discovery.
            if file.name == 'NearClient.swift' and label.strip() == 'NearError.metadataUnavailable' and 'diagnostics: optional-near-metadata-absence' in body:
                continue  # Exact block-validated ft_metadata MethodNotFound; required reads and malformed data still report.
            if file.name == 'MarketDataService.swift' and label.strip() == 'MarketDataError.notListed' and 'diagnostics: optional-market-absence' in body:
                continue  # Exact optional listing/empty trading window; malformed identities and provider failures still report.
            if file.name == 'MarketDataService.swift' and 'diagnostics: market-chart-recovery' in body and 'throw error' in body and 'geckoChart(for: asset' in body:
                continue  # load reports the original failure; tested recovery preserves cancellation and rejects malformed data.
            if file.name in ('OathTokenSearchModel.swift', 'OathTokenService.swift') and label.strip() == 'OathTokenLookupError.notToken' and 'diagnostics: token-search-absence' in body:
                continue  # Exact no-token discovery result; malformed responses and provider failures still report.
            if file.name == 'OathContactsModel.swift' and label.strip() == 'let error as ContactStoreError where isContactDraftValidation(error)' and 'diagnostics: contact-draft-validation' in body:
                continue  # Only rejected draft fields; SQLite, revision and network configuration failures still report.
            if file.name == 'OathPermissionReview.swift' and 'diagnostics: permission-preparation-feedback' in body and 'self.error=Self.message(error)' in body:
                continue  # PermissionPreparation reports before rethrow; the view only presents the unchanged error.
            if file.name == 'OathXrplSendModel.swift' and 'diagnostics: xrpl-preparation-feedback' in body and 'failureMessage = Self.message(error)' in body:
                continue  # XrplSendPreparation reports unexpected failures; the model presents the original error unchanged.
            if file.name == 'UTXOFeeProvider.swift' and any(marker in body for marker in (
                'diagnostics: fee-flight-propagation', 'diagnostics: fee-peer-cleanup')):
                continue  # Exact fee-flight/connection cleanup rethrows; sources/RPC already report.
            if file.name == 'PublicMarketRequests.swift' and 'diagnostics: market-flight-propagation' in body and 'result = .failure(error)' in body:
                continue  # execute reports real failures; completion forwards unchanged results to shared consumers.
            if file.name == 'PublicArtworkCatalogTransport.swift' and label.strip() in ('let limited as ArtworkRateLimit', 'ArtworkError.http(let status)') and 'diagnostics: artwork-http-envelope' in body:
                continue  # HTTP is reported by ArtworkURLTransport and restored for the catalog boundary; the pool consumes status/Retry-After for shared backpressure.
            if file.relative_to(ROOT).as_posix() == 'OathAtmosphere/Wallet/OathWalletVault.swift' and label.strip() == 'OathWalletError.wrongPasscode where authenticatedPIN' and 'diagnostics: authenticated-payload-failure' in body and 'throw OathWalletError.corruptVault' in body:
                continue  # openContents records the crypto failure; a verified PIN makes this payload corruption.
            if file.name == 'OathWalletSession.swift' and label.strip() == 'let error as OathWalletError' and 'diagnostics: seed-password-propagation' in body and 'throw error' in body:
                continue  # Unchanged typed rethrow; changeWallet reports failures and excludes expected duplicate-wallet results.
            if file.name == 'OathWalletConnectService.swift' and 'diagnostics: walletconnect-signing-propagation' in body and 'throw error' in body:
                continue  # Unchanged rethrow: sheet reports original failures and excludes PIN fallback/cancellation.
            if (file.name, label.strip()) in (('OathEVMSendService.swift', 'EVMSendError.multisigFunding'), ('OathTronSendService.swift', 'TronSendError.insufficientFunds'), ('OathSolanaSendService.swift', 'SolanaSendError.multisigFunding')) and 'diagnostics: multisig-funding-incomplete' in body:
                continue  # Expected incomplete funding state; transport and provider failures are reported by the client.
            if re.search(r'Task\.sleep\([^\n]+\)\s*\}\s*$', before):
                continue  # Cancelled debounce/timer teardown, not an app failure.
            line = source.count('\n', 0, match.start())+1
            failures.append(f'{file.relative_to(ROOT)}:{line}: unobserved catch; report or document an expected path')
        for match in re.finditer(r'try\? await ([\w?.]+)', source):
            name = match.group(1)
            after = source[match.end():match.end()+100]
            if name == 'Task.sleep' or name.endswith('.value'):
                continue  # Waiting for already-observed cancelled tasks.
            if name == 'batch' and file.name == 'TronClient.swift':
                continue  # Optional token interface probes, observed at transport.
            if name.endswith('.transitionSend') and ('to: "confirmed"' in after or 'to: "failed"' in after):
                continue  # Reconcile condition probes; invalidTransition means pending.
            line = source.count('\n', 0, match.start())+1
            failures.append(f'{file.relative_to(ROOT)}:{line}: silent async operation {name}')
        for match in re.finditer(r'async let[^\n]*=\s*try\?', code):
            line = source.count('\n', 0, match.start())+1
            failures.append(f'{file.relative_to(ROOT)}:{line}: silent parallel async operation')
# Prevent accidental resurrection of per-chain upload destinations.
for file in (ROOT/'OathAtmosphere').rglob('*.swift'):
    if file.name.startswith('._'): continue
    if re.search(r'"record_(?:transaction|bitcoin_cash|litecoin|dogecoin)_send_error"',file.read_text()):
        failures.append(f'{file.relative_to(ROOT)}: legacy per-chain upload destination')
print(f'Checked app and local-package failure boundaries: {observed} observed catch sites.')
if failures:
    print('\n'.join(failures)); sys.exit(1)
print('Diagnostics coverage guard passed (expected control-flow exclusions remain reviewable).')
