#!/usr/bin/env python3
"""Explicit, funded isolated Sepolia tests. Never touches app wallets or mainnet.
Requires ethers/solc in NODE_PATH. This host bridge verifies production parsing,
quotes, signing and broadcast; it does not replace native relay/UI testing.
"""
import json, os, shutil, subprocess, tempfile, sys
from pathlib import Path
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='oath-wc-tx-bridge-') as folder:
    work = Path(folder)
    sources = work/'Sources/Bridge'
    sources.mkdir(parents=True)
    shutil.copyfile(root/'Tools/WalletConnectTransactionLiveBridge.swift', sources/'main.swift')
    (work/'Package.swift').write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name:"Bridge", platforms:[.macOS(.v14)], dependencies:[.package(path:'+json.dumps(str(root/'Packages/OathAnkr'))+')], targets:[.executableTarget(name:"Bridge", dependencies:[.product(name:"OathAnkr",package:"OathAnkr")])])\n')
    scratch = '/tmp/oath-wc-live-build'
    subprocess.run(['swift','build','--package-path',str(work),'--scratch-path',scratch],check=True)
    binary = Path(subprocess.check_output(['swift','build','--package-path',str(work),'--scratch-path',scratch,'--show-bin-path'],text=True).strip())/'Bridge'
    env = os.environ.copy()
    env['OATH_WC_TX_BRIDGE'] = str(binary)
    if '--approval-edit-only' in sys.argv:
        env['OATH_WC_EDIT_APPROVAL'] = '1'
    if '--status-only' in sys.argv:
        report = []
        for journal in sorted(Path('/tmp/oath-walletconnect-sepolia').glob('*.journal.json')):
            receipt = json.loads(subprocess.check_output([str(binary)], input=json.dumps({'journal':str(journal),'statusOnly':True}), text=True))
            report.append({'check':journal.stem, **receipt})
        Path('/tmp/oath-walletconnect-sepolia/finality-evidence.json').write_text(json.dumps(report,indent=2))
        print(json.dumps(report,indent=2))
    elif '--dex' in sys.argv:
        subprocess.run(['node',str(root/'Tools/CheckWalletConnectDEXLive.cjs')],check=True,env=env)
    else:
        subprocess.run(['node',str(root/'Tools/CheckWalletConnectTransactionsLive.cjs')],check=True,env=env)
