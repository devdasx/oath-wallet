#!/usr/bin/env python3
"""Mainnet-only Sui provider verification. Never signs or broadcasts valid data.
Reads a public wallet's confirmed transaction and submits deliberately invalid
BCS with no valid signature to verify execution access. Secrets are optional,
read from a file, and never printed or written to the report.
"""
import argparse
import json
import struct
import urllib.error
import urllib.request
from pathlib import Path

CHAIN = '4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S'
OWNER = '0xdfc88cd008c89a4a4a60199b27e503cd5e248b5191be8e953856b43e87ae3393'
GRAPHQL = 'https://graphql.mainnet.sui.io/graphql'
PROXY = 'https://aperture-notifications.devdas98x.workers.dev/v1/provider/ankr/sui/grpc'


def varint(number):
    out = bytearray()
    while number >= 128:
        out.append(number & 127 | 128)
        number >>= 7
    out.append(number)
    return bytes(out)


def field(number, data):
    return varint(number * 8 + 2) + varint(len(data)) + data


def decode(data):
    offset = 0
    result = {}

    def integer():
        nonlocal offset
        value = 0
        for shift in range(0, 64, 7):
            byte = data[offset]
            offset += 1
            value |= (byte & 127) << shift
            if byte < 128:
                return value
        raise ValueError('malformed_varint')

    while offset < len(data):
        tag = integer()
        if tag % 8 == 0:
            value = integer()
        elif tag % 8 == 2:
            length = integer()
            value = data[offset:offset + length]
            assert len(value) == length
            offset += length
        else:
            raise ValueError('unsupported_fixture_field')
        result[tag >> 3] = value
    return result


def post(url, data, headers):
    request = urllib.request.Request(url, data=data, headers={
        'User-Agent': 'Aperture-iOS-Sui/1.0', **headers
    })
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status, response.headers, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.headers, error.read()


def grpc(base, method, payload=b'', key=None):
    headers = {'Content-Type': 'application/grpc-web+proto', 'X-Grpc-Web': '1'}
    if key:
        headers['x-token'] = key
    status, headers, body = post(base + '/sui.rpc.v2.' + method,
                                 b'\0' + struct.pack('>I', len(payload)) + payload, headers)
    assert status == 200, f'HTTP {status}'
    grpc_status = headers.get('grpc-status')
    message = None
    while body:
        assert len(body) >= 5
        flags, size = body[0], struct.unpack('>I', body[1:5])[0]
        payload, body = body[5:5 + size], body[5 + size:]
        assert len(payload) == size
        if flags == 128:
            for line in payload.decode().split('\r\n'):
                if line.lower().startswith('grpc-status:'):
                    grpc_status = line.split(':', 1)[1].strip()
        elif flags == 0:
            assert message is None
            message = payload
        else:
            raise ValueError('unsupported_grpc_frame')
    return int(grpc_status) if grpc_status is not None else None, message


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ankr-key-file', type=Path)
    parser.add_argument('--include-proxy', action='store_true')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    query = '''{ chainIdentifier epoch { referenceGasPrice }
      address(address: "%s") { transactions(last:1) { nodes { digest effects { status } } } }
    }''' % OWNER
    status, _, raw = post(GRAPHQL, json.dumps({'query': query}).encode(), {'Content-Type': 'application/json'})
    assert status == 200
    response = json.loads(raw)
    assert not response.get('errors'), 'graphql_errors'
    result = response['data']
    assert result['chainIdentifier'] == CHAIN
    assert isinstance(result['epoch']['referenceGasPrice'], str)
    tx = result['address']['transactions']['nodes'][0]
    report = {'public_wallet': OWNER, 'transaction': tx['digest'], 'graphql_status': tx['effects']['status'], 'providers': []}
    providers = [('Sui Foundation', 'https://fullnode.mainnet.sui.io', None),
                 ('NodeInfra', 'https://sui-mainnet.nodeinfra.com', None)]
    if args.ankr_key_file:
        key = args.ankr_key_file.read_text().strip()
        assert len(key) == 64 and all(c in '0123456789abcdefABCDEF' for c in key), 'invalid_key_file'
        providers.append(('ANKR authenticated gRPC', 'https://sui.grpc.ankr.com', key))
    if args.include_proxy:
        providers.append(('Deployed ANKR app proxy', PROXY, None))
    # Deliberately invalid one-byte BCS and one-byte signature: cannot move funds.
    invalid = field(1, field(1, field(2, b'\0'))) + field(2, field(1, field(2, b'\0')))
    mask = field(1, b'digest') + field(1, b'effects.status')
    invalid += field(3, mask)
    for name, base, key in providers:
        info_status, info = grpc(base, 'LedgerService/GetServiceInfo', key=key)
        assert info_status in (None, 0) and info is not None
        info = decode(info)
        assert info[1].decode() == CHAIN and info[2] == b'mainnet'
        row = {'name': name, 'mainnet': True, 'checkpoint': str(info[4])}
        if base != PROXY:  # Proxy intentionally exposes only info and execution.
            code, receipt = grpc(base, 'LedgerService/GetTransaction', field(1, tx['digest'].encode()) + field(2, mask), key)
            assert code in (None, 0)
            executed = decode(decode(receipt)[1])
            assert executed[1].decode() == tx['digest']
            success = decode(decode(executed[4])[4])[1]
            assert success == (1 if tx['effects']['status'] == 'SUCCESS' else 0)
            row['transaction_matches_graphql'] = True
        rejected, _ = grpc(base, 'TransactionExecutionService/ExecuteTransaction', invalid, key)
        assert rejected == 3, f'{name}: invalid BCS must reach validation; got {rejected}'
        row['invalid_unsigned_execution_status'] = rejected
        report['providers'].append(row)
    output = json.dumps(report, indent=2) + '\n'
    if args.output:
        args.output.write_text(output)
    print(output)


if __name__ == '__main__':
    # Exceptions intentionally omit URL/request details that could expose secrets.
    try:
        main()
    except Exception as error:
        print('Sui verification failed:', type(error).__name__)
        raise SystemExit(1)
