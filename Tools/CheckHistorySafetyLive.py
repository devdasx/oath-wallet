#!/usr/bin/env python3
"""Read-only public fixtures. Credentials and provider error messages are never printed.
Compare Ankr's documented whitelist with transfer responses and keyless lists.
"""
import concurrent.futures, json, plistlib, urllib.request, urllib.error, time, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHAINS = {'eth':'ethereum','arbitrum':'arbitrum-one','avalanche':'avalanche','base':'base','bsc':'binance-smart-chain','fantom':'fantom','flare':'flare-network','gnosis':'xdai','linea':'linea','optimism':'optimistic-ethereum','polygon':'polygon-pos','scroll':'scroll','somnia_mainnet':'somnia','story_mainnet':'story','taiko':'taiko','telos':'telos','xlayer':'x-layer'}
OWNER = '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045'

def run():
    with (ROOT/'OathApp/Private/TokenRPC.plist').open('rb') as file:
        key = plistlib.load(file).get('AnkrAPIKey')
    if not key: raise SystemExit('Local Ankr configuration missing')
    output = Path('/tmp/oath-history-safety-live'); output.mkdir(exist_ok=True)
    def read(url, payload=None):
        request = urllib.request.Request(url, data=json.dumps(payload).encode() if payload else None,
                                        headers={'Content-Type':'application/json', 'Accept':'application/json', 'User-Agent':'OathWallet/1.0'})
        for attempt in range(3):
            try:
                with urllib.request.urlopen(request,timeout=30) as response:
                    data = response.read(64*1024*1024+1)
                break
            except urllib.error.HTTPError as error:
                if error.code not in (429,500,502,503,504) or attempt == 2: raise
                time.sleep(1+attempt*2)
        if len(data)>64*1024*1024: raise ValueError('response size')
        return json.loads(data)
    def capture_receipts(values, refs):
        chosen=[x for x in values if x['token_info']['address'] in refs][:5]+[x for x in values if x['token_info']['address'] not in refs][:5]
        def receipt(x):
            txid=x['transaction_id']; base='https://rpc.ankr.com/premium-http/tron/'+key
            return txid,dict(body=read(base+'/wallet/gettransactionbyid',{'value':txid}),receipt=read(base+'/wallet/gettransactioninfobyid',{'value':txid}))
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            receipts=dict(pool.map(receipt,chosen))
        (output/'tron-receipts.json').write_text(json.dumps(receipts))
        return len(receipts)
    if '--tron-receipts' in sys.argv:
        tokens=json.loads((output/'tron-catalog.json').read_text())['tokens']
        values=json.loads((output/'tron-transfers.json').read_text())
        try: print('TRON real ANKR receipts captured:',capture_receipts(values,{x['address'] for x in tokens}))
        except urllib.error.HTTPError as error: print('TRON receipt HTTP status:',error.code)
        except Exception as error: print('TRON receipt error:',type(error).__name__)
        return
    def rpc(method, params):
        return read('https://rpc.ankr.com/multichain/'+key,dict(jsonrpc='2.0',id=1,method=method,params=params))
    def probe(item):
        chain, platform = item; report={'chain':chain}
        try:
            if chain == 'taiko':
                coins=read('https://api.coingecko.com/api/v3/coins/list?include_platform=true')
                catalog=coins
                tokens=[dict(address=x['platforms']['taiko'],chainId=167000) for x in coins if x.get('platforms',{}).get('taiko')]
            else:
                catalog=read('https://tokens.coingecko.com/'+platform+'/all.json')
                tokens=catalog.get('tokens',[])
            (output/(chain+'-catalog.json')).write_text(json.dumps(catalog))
            refs={x['address'].lower() for x in tokens}
            report.update(catalogCount=len(tokens),catalogChainIDs=sorted({str(x.get('chainId')) for x in tokens}))
        except Exception as error: report['catalogError']=type(error).__name__; refs=set()
        try:
            balances=rpc('ankr_getAccountBalance',dict(blockchain=[chain],walletAddress=OWNER,onlyWhitelisted=True,pageSize=100))
            result=balances.get('result',{}); listed=result.get('assets',[])
            (output/(chain+'-balances.json')).write_text(json.dumps(balances))
            report.update(balanceError=balances.get('error',{}).get('code'),whitelistedAssets=len(listed))
            for x in listed: refs.add(x.get('contractAddress','').lower())
            transfers=rpc('ankr_getTokenTransfers',dict(blockchain=[chain],address=[OWNER],descOrder=True,pageSize=25))
            (output/(chain+'-transfers.json')).write_text(json.dumps(transfers))
            values=transfers.get('result',{}).get('transfers',[])
            report.update(historyError=transfers.get('error',{}).get('code'),transfers=len(values),unlistedTransfers=sum(x.get('contractAddress','').lower() not in refs for x in values),zeroTransfers=sum(x.get('valueRawInteger')=='0' for x in values))
            if chain=='eth':
                attempted=rpc('ankr_getTokenTransfers',dict(blockchain=[chain],address=[OWNER],descOrder=True,pageSize=25,onlyWhitelisted=True))
                vals=attempted.get('result',{}).get('transfers',[])
                report.update(undocumentedFlagError=attempted.get('error',{}).get('code'),undocumentedFlagUnlisted=sum(x.get('contractAddress','').lower() not in refs for x in vals))
        except Exception as error: report['rpcFailure']=type(error).__name__
        return report
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results=list(pool.map(probe,CHAINS.items()))
    # Ordinary chain RPC support does not imply Advanced API history support.
    for chain in ['tron','solana','ton','aptos','sui','near','xrp','stellar','arc','robinhood']:
        try:
            response=rpc('ankr_getTokenTransfers',dict(blockchain=[chain],address=[OWNER],pageSize=1))
            results.append({'chain':chain,'advancedHistoryError':response.get('error',{}).get('code'), 'resultFields':list(response.get('result',{}))})
        except Exception as error: results.append({'chain':chain,'rpcFailure':type(error).__name__})
    try:
        tokens=read('https://tokens.coingecko.com/tron/all.json')['tokens']
        values=read('https://api.trongrid.io/v1/accounts/TJmmqjb1DK9TTZbQXzRQ2AuA94z4gKAPFh/transactions/trc20?limit=50&only_confirmed=true').get('data',[])
        refs={x['address'] for x in tokens}
        (output/'tron-transfers.json').write_text(json.dumps(values))
        (output/'tron-catalog.json').write_text(json.dumps({'tokens':tokens}))
        # Decode a bounded mix of listed and unlisted transfers against real receipts.
        receipt_count=capture_receipts(values,refs)
        results.append({'chain':'tron','checkedReceipts':receipt_count,'publicTransfers':len(values),'unlistedTransfers':sum(x.get('token_info',{}).get('address') not in refs for x in values),'zeroTransfers':sum(x.get('value')=='0' for x in values)})
    except Exception as error: results.append({'chain':'tron','comparisonFailure':type(error).__name__})
    (output/'summary.json').write_text(json.dumps(results,indent=2))
    for result in results: print(json.dumps(result),flush=True)

if __name__=='__main__': run()
