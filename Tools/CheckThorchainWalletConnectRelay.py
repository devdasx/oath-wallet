#!/usr/bin/env python3
"""Build a host bridge and test public fixture signatures over the live relay.
Requires @walletconnect/sign-client in NODE_PATH; reads only the local project
ID, never wallet data. No app/simulator/device launch and no on-chain spending.
"""
import json, os, plistlib, shutil, subprocess, tempfile
from pathlib import Path
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='oath-thor-wc-relay-') as folder:
    work=Path(folder); sources=work/'Sources/RelayBridge'; sources.mkdir(parents=True)
    shutil.copyfile(root/'Tools/ThorchainWalletConnectRelayBridge.swift',sources/'Bridge.swift')
    (work/'Package.swift').write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name:"RelayBridge", platforms:[.macOS(.v14)], dependencies:[.package(path:'+json.dumps(str(root/'Packages/OathAnkr'))+')], targets:[.executableTarget(name:"RelayBridge", dependencies:[.product(name:"OathAnkr",package:"OathAnkr")])])\n')
    scratch='/tmp/oath-thor-wc-relay-build'
    subprocess.run(['swift','build','--package-path',str(work),'--scratch-path',scratch],check=True)
    binary=Path(subprocess.check_output(['swift','build','--package-path',str(work),'--scratch-path',scratch,'--show-bin-path'],text=True).strip())/'RelayBridge'
    env=os.environ.copy()
    with (root/'OathApp/Private/TokenRPC.plist').open('rb') as source:
        env['OATH_WC_PROJECT_ID']=plistlib.load(source)['WalletConnectProjectID']
    env['OATH_THORCHAIN_WC_BRIDGE']=str(binary)
    subprocess.run(['node',str(root/'Tools/CheckThorchainWalletConnectRelay.cjs')],check=True,env=env)
