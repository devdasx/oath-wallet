#!/usr/bin/env python3
"""Regenerate unfunded rawtr/tr mainnet vectors with Bitcoin Core 28.3.
Usage: python3 Scripts/generate_bitcoin_rawtr_fixtures.py CORE_BIN_DIRECTORY
A new temporary data directory is used with networking disabled. Never fund these public keys.
"""
import subprocess,tempfile,json,time,hashlib,sys
from pathlib import Path
root=Path(tempfile.mkdtemp(prefix='rawtr-core-'))
binary=Path(sys.argv[1]).resolve()
args=['-datadir='+str(root),'-rpcport=18449']
daemon=subprocess.Popen([str(binary/'bitcoind')]+args+['-connect=0','-listen=0','-dnsseed=0','-discover=0','-networkactive=0'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
def rpc(method,*a):
 p=subprocess.run([str(binary/'bitcoin-cli')]+args+[method]+list(a),capture_output=True,text=True)
 if p.returncode: raise RuntimeError(method)
 return json.loads(p.stdout)
def wif(n):
 b=b'\x80'+n.to_bytes(32,'big')+b'\x01'; b+=hashlib.sha256(hashlib.sha256(b).digest()).digest()[:4]
 n=int.from_bytes(b,'big');s='';alpha='123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
 while n:n,r=divmod(n,58);s=alpha[r]+s
 return s
try:
 for i in range(100):
  try:rpc('getblockchaininfo');break
  except RuntimeError:time.sleep(.1)
 assert rpc('getblockchaininfo')['chain']=='main'
 assert not rpc('getnetworkinfo')['networkactive']
 assert rpc('getnetworkinfo')['version'] == 280300
 fixtures=[]
 for n in range(1,9):
  key=int.from_bytes(hashlib.sha256(b'Aperture rawtr public fixture '+bytes([n])).digest(),'big')
  body='rawtr('+wif(key)+')'; info=rpc('getdescriptorinfo',body);desc=body+'#'+info['checksum']
  address=rpc('deriveaddresses',desc)[0]; tr='tr('+wif(key)+')';trinfo=rpc('getdescriptorinfo',tr)
  fixtures.append(dict(index=n,descriptor=desc,address=address,script=rpc('validateaddress',address)['scriptPubKey'],bip86=rpc('deriveaddresses',tr+'#'+trinfo['checksum'])[0]))
 Path('EVMWalletTests/Fixtures/BitcoinImport/rawtr-core-28.3.json').write_text(json.dumps(fixtures,indent=2)+'\n')
 print('Bitcoin Core 28.3 independently derived 8 rawtr and 8 tr addresses (mainnet format, unfunded keys, networking disabled).')
finally:
 subprocess.run([str(binary/'bitcoin-cli')]+args+['stop'],capture_output=True)
 daemon.wait(timeout=15)
