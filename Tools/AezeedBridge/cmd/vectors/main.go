// Public deterministic LND test-vector derivatives. Never pass real seeds here.
package main
import (
 "encoding/hex"
 "encoding/json"
 "fmt"
 "os"
 "github.com/btcsuite/btcd/btcutil"
 "github.com/btcsuite/btcd/btcutil/hdkeychain"
 "github.com/btcsuite/btcd/chaincfg"
 "github.com/btcsuite/btcd/txscript"
 "github.com/btcsuite/btcd/btcec/v2/schnorr"
)
type Vector struct { Path string `json:"path"`; Address string `json:"address"`; PublicKey string `json:"publicKey"` }
func main() {
 entropy,_:=hex.DecodeString("81b637d86359e6960de795e41e0b4cfd")
 root,err:=hdkeychain.NewMaster(entropy,&chaincfg.MainNetParams);must(err)
 var vectors []Vector
 for _,account:=range []uint32{0,1} { for _,purpose:=range []uint32{44,49,84,86} { for _,change:=range []uint32{0,1} { for _,index:=range []uint32{0,1,19,20} {
  key:=root
  for _,i:=range []uint32{purpose+hdkeychain.HardenedKeyStart,hdkeychain.HardenedKeyStart,account+hdkeychain.HardenedKeyStart,change,index} { key,err=key.Derive(i);must(err) }
  pub,err:=key.ECPubKey();must(err)
  hash:=btcutil.Hash160(pub.SerializeCompressed())
  var address btcutil.Address
  switch {
  case purpose==44: address,err=btcutil.NewAddressPubKeyHash(hash,&chaincfg.MainNetParams)
  case purpose==49 && change==0:
   var witness *btcutil.AddressWitnessPubKeyHash
   witness,err=btcutil.NewAddressWitnessPubKeyHash(hash,&chaincfg.MainNetParams);must(err)
   var script []byte;script,err=txscript.PayToAddrScript(witness);must(err)
   address,err=btcutil.NewAddressScriptHash(script,&chaincfg.MainNetParams)
  case purpose==86: address,err=btcutil.NewAddressTaproot(schnorr.SerializePubKey(txscript.ComputeTaprootKeyNoScript(pub)),&chaincfg.MainNetParams)
  default: address,err=btcutil.NewAddressWitnessPubKeyHash(hash,&chaincfg.MainNetParams)
  };must(err)
  vectors=append(vectors,Vector{fmt.Sprintf("m/%d'/0'/%d'/%d/%d",purpose,account,change,index),address.EncodeAddress(),hex.EncodeToString(pub.SerializeCompressed())})
 }}}}
 must(json.NewEncoder(os.Stdout).Encode(vectors))
}
func must(err error) { if err!=nil { panic("public vector generation failed") } }
