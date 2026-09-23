#!/usr/bin/env python3
"""Read-only Robinhood mainnet readiness probe. Never signs or sends transactions."""
import concurrent.futures
import datetime
import decimal
import json
import pathlib
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/RobinhoodValidation/live-results.json'
RPC = 'https://rpc.mainnet.chain.robinhood.com'
FALLBACK = 'https://robinhood-rpc.publicnode.com'
TRANSFER = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'
results = []


def request(name, url, body=None):
    request = urllib.request.Request(url, data=json.dumps(body).encode() if body else None,
        headers={'Content-Type': 'application/json', 'User-Agent': 'ApertureNetworkValidation/1.0'})
    started = datetime.datetime.now(datetime.timezone.utc)
    row = {'check': name, 'url': url, 'request': body}
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            row['httpStatus'] = response.status
            row['response'] = json.load(response)
    except urllib.error.HTTPError as error:
        row['httpStatus'] = error.code
        row['error'] = error.read().decode(errors='replace')[:300]
    except Exception as error:
        row['error'] = str(error)
    row['elapsedMs'] = round((datetime.datetime.now(datetime.timezone.utc) - started).total_seconds() * 1000)
    results.append(row)
    print(name, row.get('httpStatus'), row.get('response', {}).get('error', row.get('error', 'OK')), flush=True)
    return row.get('response', {})


def rpc(name, method, params, url=RPC):
    return request(name, url, {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).get('result')


def main():
    rpc('mainnet identity', 'eth_chainId', [])
    rpc('fallback identity', 'eth_chainId', [], FALLBACK)
    rpc('Triport advertised public identity', 'eth_chainId', [], 'https://triport.io/rpc/robinhood/public')
    block = rpc('public recent block', 'eth_getBlockByNumber', ['latest', True])
    if not block:
        return
    height = block['number']
    transactions = [t for t in block['transactions'] if t['from'] != '0x00000000000000000000000000000000000a4b05']
    # Include a known, publicly observed funded account even if latest block is empty.
    addresses = list(dict.fromkeys([t['from'] for t in transactions[:2]] + ['0x2c895c6677d6dd72c39bd892e484a77e1d496fbc']))
    for address in addresses:
        rpc('PublicNode latest balance ' + address, 'eth_getBalance', [address, 'latest'], FALLBACK)
        native = rpc('native balance ' + address, 'eth_getBalance', [address, height])
        fallback = rpc('fallback native balance ' + address, 'eth_getBalance', [address, height], FALLBACK)
        results.append({'check': 'cross-provider exact balance ' + address, 'block': height,
                        'matches': native is not None and native == fallback,
                        'ETH': str(decimal.Decimal(int(native, 16)) / decimal.Decimal(10**18)) if native else None})
    if transactions:
        rpc('transaction lookup', 'eth_getTransactionByHash', [transactions[0]['hash']])
        rpc('transaction receipt', 'eth_getTransactionReceipt', [transactions[0]['hash']])
    logs = rpc('recent ERC20 transfer logs', 'eth_getLogs', [{'fromBlock': hex(int(height, 16)-100), 'toBlock': height, 'topics': [TRANSFER]}])
    if logs:
        # Read token identity and balance of a real recipient discovered from public chain logs.
        log = next((log for log in logs if len(log['topics']) == 3 and len(log['data']) == 66), None)
        if log:
            token, recipient = log['address'], '0x' + log['topics'][2][-40:]
            for name, data in [('decimals', '0x313ce567'), ('symbol', '0x95d89b41'), ('balanceOf', '0x70a08231'+recipient[2:].rjust(64,'0'))]:
                rpc('observed token '+name, 'eth_call', [{'to':token,'data':data},height])
            request('exact token DEX price', 'https://api.dexscreener.com/latest/dex/tokens/'+token)
    for token in ['0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73', '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168']:
        rpc('canonical token code '+token, 'eth_getCode', [token,height])
        for name, data in [('decimals','0x313ce567'),('symbol','0x95d89b41'),('balanceOf','0x70a08231'+addresses[0][2:].rjust(64,'0'))]:
            rpc('canonical token '+name+' '+token, 'eth_call',[{'to':token,'data':data},height])
    address = addresses[0]
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        jobs = [
          ('explorer history','https://robinhoodchain.blockscout.com/api/v2/addresses/'+address+'/transactions'),
          ('explorer token inventory','https://robinhoodchain.blockscout.com/api/v2/addresses/'+address+'/token-balances'),
          ('explorer legacy history','https://robinhoodchain.blockscout.com/api?module=account&action=txlist&address='+address),
          ('Blockscout gateway history','https://api.blockscout.com/4663/api/v2/addresses/'+address+'/transactions'),
          ('stock registry','https://api.robinhood.com/rhj/assets'),
          ('stock AAPL price','https://api.robinhood.com/rhj/prices/AAPL'),
          ('native ETH USD price','https://api.coinbase.com/v2/prices/ETH-USD/spot'),
        ]
        list(pool.map(lambda job: request(*job), jobs))


if __name__ == '__main__':
    try:
        main()
    finally:
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(json.dumps({'checkedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'note': 'Public read-only samples; no wallet secrets or submitted transactions. Sample success is not proof of full history coverage.',
            'checks': results}, indent=2)+'\n')
        print('Saved', OUT)
