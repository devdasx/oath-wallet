#!/usr/bin/env python3
"""Read public token catalogs for representative artwork. No wallet/RPC secrets.
Writes a manifest consumed by the production Swift image/resolver host test.
A missing catalog is reported as unavailable, never counted as a passing test.
"""
import argparse
import concurrent.futures
import json
import re
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'output/token-logo-validation'
OUT.mkdir(parents=True, exist_ok=True)
networks = re.findall(r'chain: \.(\w+), chainID: ([^,]+), ankrPath: "[^"]+", artworkDirectory: "([^"]+)"',
                     (ROOT / 'OathAtmosphere/Tokens/OathTokenNetwork.swift').read_text())
platforms = {'arbitrum':'arbitrum-one','bnb':'binance-smart-chain','flare':'flare-network','gnosis':'xdai',
             'optimism':'optimistic-ethereum','polygon':'polygon-pos','xlayer':'x-layer','near':'near-protocol'}
all_networks = networks + [(n, 'nil', n) for n in ['aptos','sui','ton','near','stellar','xrpl','thorchain']]

def read(url):
    req = urllib.request.Request(url, headers={'User-Agent':'Oath-ReadOnly-Artwork-Validation/1.0'})
    with urllib.request.urlopen(req, timeout=25) as response:
        return json.load(response)

def probe(row):
    network, chain, directory = row
    url = f'https://tokens.coingecko.com/{platforms.get(network,network)}/all.json'
    try:
        listing = read(url)
        tokens = [t for t in listing.get('tokens',[]) if t.get('address') and t.get('logoURI') and isinstance(t.get('decimals'),int)]
        if chain != 'nil' and network != 'tron': tokens = [t for t in tokens if t.get('chainId') == int(chain)]
        priority = {'USDC':0,'USDT':1,'WETH':2}
        tokens.sort(key=lambda t:(priority.get(t.get('symbol'),3), t.get('address','')))
        selected=[]
        for t in tokens:
            if any(s['reference']==t['address'] for s in selected): continue
            selected.append({'networkID':network, 'reference':t['address'], 'decimals':t['decimals'],
                'name': t.get('name',''), 'symbol':t.get('symbol',''), 'source':t['logoURI'], 'catalog':url,
                'storedSource':f"https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/{directory}/assets/{t['address']}/logo.png"})
            if len(selected)==3: break
        return network, selected, None if selected else 'No token artwork published by this catalog'
    except Exception as error:
        return network, [], str(error)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--supplement', type=Path, help='Previously verified public samples to retain when a catalog is unavailable')
args = parser.parse_args()
supplement = json.loads(args.supplement.read_text()) if args.supplement else []
samples=[]; unavailable=[]
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    for network, found, error in pool.map(probe,all_networks):
        samples.extend(found)
        if error:
            unavailable.append({'networkID':network,'reason':error})
            # Preserve provenance. This is retained evidence, not a fresh catalog
            # request success; the Swift live test still downloads each image.
            samples.extend(t for t in supplement if t['networkID'] == network)
        print(network, len(found), error or 'public identity-linked artwork found', flush=True)
(OUT/'public-token-samples.json').write_text(json.dumps(samples,indent=2))
(OUT/'catalog-coverage.json').write_text(json.dumps({'networks':len(all_networks),'samples':len(samples),'unavailable':unavailable,'retainedSupplement':str(args.supplement) if args.supplement else None},indent=2))
