#!/usr/bin/env python3
"""Build a host bridge and test public fixture signatures over the live relay.
Requires @walletconnect/sign-client in NODE_PATH; reads only the local project
ID, never app wallet data. No app/simulator/device launch. An explicitly supplied
OATH_THORCHAIN_SEND_FIXTURE also tests real local-chain transactions through the
relay; COSMJS_NODE_MODULE must point to the independent CosmJS dependencies and
TCSWAP_NODE_MODULE to the website's @tcswap/toolboxes and @tcswap/helpers packages.
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
    public_env=env.copy()
    public_env.pop('OATH_THORCHAIN_SEND_FIXTURE',None)
    subprocess.run(['node',str(root/'Tools/CheckThorchainWalletConnectRelay.cjs')],check=True,env=public_env)
    if env.get('OATH_THORCHAIN_SEND_FIXTURE'):
        subprocess.run(['node',str(root/'Tools/CheckThorchainWalletConnectNodeRelay.cjs')],check=True,env=env)
