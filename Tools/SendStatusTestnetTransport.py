#!/usr/bin/env python3
"""Public testnet-only RPC bridge for SendStatusUTXOLiveTests.
No private keys. Existing Litecoin test certificate pins remain mandatory.
Never accepts a caller-supplied endpoint or mainnet chain.
"""
import hashlib,json,socket,ssl,sys,urllib.request
from pathlib import Path
chain,request_path=sys.argv[1:3]
assert chain in ('bitcoin','bitcoincash','litecoin','dogecoin')
q=json.loads(Path(request_path).read_text());method=q['method'];params=q['params']
assert method in ('query','transactions','times','broadcast','funding')
def sha(b):return hashlib.sha256(hashlib.sha256(b).digest()).digest()
def execute(rpc):
 if method=='query':return [[{'txid':x['tx_hash'],'height':x['height']} for x in rpc('blockchain.scripthash.get_history',[s])] for s in params]
 if method=='transactions':return {h:rpc('blockchain.transaction.get',[h]) for h in params}
 if method=='times':return {str(h):int.from_bytes(bytes.fromhex(rpc('blockchain.block.header',[h]))[68:72],'little') for h in params}
 if method=='broadcast':return rpc('blockchain.transaction.broadcast',params)
 return [dict(x,raw=rpc('blockchain.transaction.get',[x['tx_hash']]),address=a) for a in params for x in rpc('blockchain.scripthash.listunspent',[a['scriptHash']]+(['exclude_tokens'] if chain=='bitcoincash' else []))]
def electrum():
 peers= [('chipnet.imaginary.cash',50002),('chipnet.c3-soft.com',64002),('chipnet.bch.ninja',50002)] if chain=='bitcoincash' else [('electrum-ltc.bysh.me',51002),('electrum.ltc.xurious.com',51002)]
 pins=json.loads(Path('/tmp/oath-ltc-public/testnet-peer-pins.json').read_text()) if chain=='litecoin' else {}
 for host,port in peers:
  try:
   ctx=ssl.create_default_context()
   pin=pins.get(host)
   if pin and pin!='certificate-authority':
    ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT);ctx.check_hostname=False;ctx.verify_mode=ssl.CERT_NONE
   with ctx.wrap_socket(socket.create_connection((host,port),timeout=8),server_hostname=host) as c:
    c.settimeout(15)
    if pin and pin!='certificate-authority':assert hashlib.sha256(c.getpeercert(binary_form=True)).hexdigest()==pin
    stream=c.makefile('rwb');seq=0
    def rpc(m,p):
     nonlocal seq
     seq+=1;stream.write((json.dumps({'id':seq,'method':m,'params':p})+'\n').encode());stream.flush()
     for _ in range(100):
      j=json.loads(stream.readline())
      if j.get('id')==seq:
       if j.get('error'):raise ValueError('testnet RPC rejected')
       return j['result']
     raise ValueError('testnet response limit')
    rpc('server.version',['Oath status test','1.4'])
    if chain=='bitcoincash':assert sha(bytes.fromhex(rpc('blockchain.block.header',[121957])))[::-1].hex()=='0000000056087dee73fb66178ca70da89dfd0be098b1a63cf6fe93934cd04c78'
    else:assert rpc('server.features',[])['genesis_hash']=='4966625a4b2851d9fdee139e56211a0d88575f59ed816ff5e6a63deb4e3e29a0'
    return execute(rpc)
  except Exception:continue # Test-only provider failover; final failure is explicit below.
 raise ValueError('verified testnet peers unavailable')
def esplora():
 base='https://mempool.space/testnet4/api' if chain=='bitcoin' else 'https://doge-electrs-testnet-demo.qed.me'
 def get(path,body=None):
  r=urllib.request.urlopen(urllib.request.Request(base+path,data=body,headers={'Content-Type':'text/plain'}),timeout=15)
  return r.read().decode().strip()
 def js(path):return json.loads(get(path))
 expected='00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043' if chain=='bitcoin' else 'bb0a78264637406b6360aad926284d544d7049f45189db5664f3c4d07350559e'
 assert get('/block-height/0')==expected
 if method=='broadcast':return get('/tx',params[0].encode())
 if method=='transactions':return {h:get('/tx/'+h+'/hex') for h in params}
 if method=='times':return {str(h):js('/block/'+get('/block-height/'+str(h)))['timestamp'] for h in params}
 if method=='funding':return [dict(tx_hash=x['txid'],tx_pos=x['vout'],value=x['value'],raw=get('/tx/'+x['txid']+'/hex'),address=a) for a in params for x in js('/address/'+a['address']+'/utxo')]
 result=[]
 for s in params:
  rows=js('/scripthash/'+s+'/txs');allrows=list(rows)
  while len([x for x in rows if x['status']['confirmed']])>=25:
   rows=js('/scripthash/'+s+'/txs/chain/'+rows[-1]['txid']);allrows+=rows
  result.append([dict(txid=x['txid'],height=x['status'].get('block_height',0)) for x in allrows])
 return result
try:
 result=electrum() if chain in ('bitcoincash','litecoin') else esplora()
 Path(request_path+'.response').write_text(json.dumps(result))
except Exception as e:
 print('Testnet transport failed: '+type(e).__name__,file=sys.stderr);sys.exit(1)
