#!/usr/bin/env python3
"""Explicit opt-in isolated devnet/testnet only. Swift production protocol + RPC;
JS SDK builds requests and independently verifies signature and balance effects.
Does not launch the app, simulator or device. --relay also exercises isolated
WalletConnect JS peers with the production Swift signer and devnet RPC.
"""
import argparse, json, os, plistlib, shutil, subprocess, tempfile
from pathlib import Path
args=argparse.ArgumentParser(); args.add_argument('--relay', action='store_true'); options=args.parse_args()
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='oath-wc-solana-bridge-') as folder:
    work=Path(folder); src=work/'Sources/Bridge'; src.mkdir(parents=True)
    shutil.copyfile(root/'Tools/WalletConnectSolanaLiveBridge.swift',src/'Bridge.swift')
    (work/'Package.swift').write_text('// swift-tools-version: 6.1\nimport PackageDescription\nlet package = Package(name:"Bridge", platforms:[.macOS(.v14)], dependencies:[.package(path:'+json.dumps(str(root/'Packages/OathAnkr'))+')], targets:[.executableTarget(name:"Bridge",dependencies:["OathAnkr"])])\n')
    scratch='/tmp/oath-wc-solana-live-build'
    subprocess.run(['swift','build','--package-path',str(work),'--scratch-path',scratch],check=True)
    binary=Path(subprocess.check_output(['swift','build','--package-path',str(work),'--scratch-path',scratch,'--show-bin-path'],text=True).strip())/'Bridge'
    env=os.environ.copy();env['OATH_WC_SOLANA_BRIDGE']=str(binary)
    if options.relay:
        with (root/'OathApp/Private/TokenRPC.plist').open('rb') as source:
            env['OATH_WC_PROJECT_ID']=plistlib.load(source)['WalletConnectProjectID']
    script='CheckWalletConnectSolanaRelay.cjs' if options.relay else 'CheckWalletConnectSolanaLive.cjs'
    subprocess.run(['node',str(root/'Tools'/script)],env=env,check=True)
