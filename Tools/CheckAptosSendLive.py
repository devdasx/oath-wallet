#!/usr/bin/env python3
"""Explicitly opted-in, isolated Aptos TESTNET send and restart checks."""
import argparse,os,pathlib,subprocess,sys
parser=argparse.ArgumentParser()
parser.add_argument('--run',action='store_true',help='Allow transfers of isolated testnet faucet tokens')
args=parser.parse_args()
if not args.run:
    parser.print_help();sys.exit(0)
root=pathlib.Path(__file__).resolve().parents[1]
if not pathlib.Path('/tmp/oath-aptos-testnet-fixture.json').is_file():
    sys.exit('Prepare and fund the isolated Aptos testnet fixture first.')
for package,test,flag in [('OathAnkr','AptosSendLiveTests','OATH_APTOS_LIVE'),('OathDatabase','SendStatusLiveTests.testLiveAptosNativeCoinAndFungibleAsset','OATH_STATUS_LIVE')]:
    env=os.environ.copy();env[flag]='1'
    result=subprocess.run(['swift','test','--package-path',str(root/'Packages'/package),'--scratch-path','/tmp/oath-aptos-'+package.lower()+'-live','--build-system','native','--filter',test],env=env,cwd=root)
    if result.returncode:sys.exit(result.returncode)
