#!/usr/bin/env python3
"""Independent, standard-library ABI encoder for synthetic approval fixtures.

Only public repeated-digit addresses are used. No RPC, keys, or transactions.
Run from the repository root; the generated fixture is checked into source.
"""
import json
from pathlib import Path

def word(n):
    return n.to_bytes(32, 'big')

def address(byte):
    return bytes(12) + bytes([byte]) * 20

def blob(data):
    return word(len(data)) + data + bytes((-len(data)) % 32)

def batch(commands, inputs):
    chunks = [blob(value) for value in inputs]
    offset = 32 * len(chunks)
    offsets = []
    for chunk in chunks:
        offsets.append(word(offset))
        offset += len(chunk)
    command_data = blob(bytes(commands))
    return word(64) + word(64 + len(command_data)) + command_data + word(len(inputs)) + b''.join(offsets + chunks)

sender = word(1)
path = bytes([0x11]) * 20 + (3000).to_bytes(3, 'big') + bytes([0x33]) * 20
swap = sender + word(123456789) + word(100000000) + word(160) + word(1) + blob(path)
transfer = address(0x55) + address(0x66) + word(987654321)
rows = []
def add(name, commands, inputs):
    rows.append(dict(name=name, data='0x24856bc3' + batch(commands, inputs).hex()))

add('swap-only', [0], [swap])
for command in [2, 4, 5]:
    add(f'swap-transfer-{command}', [0, command], [swap, transfer])
add('transfer-before-swap', [2, 0], [transfer, swap])
add('nested-optional-transfer', [0, 0xa1], [swap, batch([2], [transfer])])
add('swap-balance-check', [0, 14], [swap, address(0x66) + address(0x55) + word(987654321)])
add('swap-other-recipient', [0, 2], [swap, address(0x55) + address(0x77) + word(987654321)])
add('swap-other-amount', [0, 2], [swap, address(0x55) + address(0x66) + word(987654322)])
add('swap-unknown', [0, 63], [swap, b''])
path = Path('Packages/OathAnkr/Tests/OathAnkrTests/Fixtures/WalletConnect/approval-operations.json')
path.write_text(json.dumps(rows, indent=2) + '\n')
print(f'Generated {len(rows)} synthetic ABI vectors')
