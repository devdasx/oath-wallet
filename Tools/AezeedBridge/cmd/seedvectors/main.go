// Deterministic PUBLIC fixtures using LND's production scrypt settings.
// LND's own unit-test mnemonics use N=16 and are not production seeds.
package main
import (
 "bytes"
 "encoding/hex"
 "encoding/json"
 "os"
 "strings"
 "time"
 "github.com/lightningnetwork/lnd/aezeed"
)
func main() {
 data,_:=hex.DecodeString("81b637d86359e6960de795e41e0b4cfd")
 var entropy [16]byte;copy(entropy[:],data)
 type V struct { Phrase string `json:"phrase"`; Password string `json:"password"`; Version uint8 `json:"version"`; Birthday uint16 `json:"birthday"` }
 var rows []V
 for _,v:=range []V{{Password:"",Version:0},{Password:"!very_safe_55345_password*",Version:0},{Password:" \u00e9\x00\u0645\u0631\u0648\u0631 ",Version:1},{Password:"",Version:2}} {
   seed,err:=aezeed.New(v.Version,&entropy,time.Unix(1521799345,0),aezeed.WithRandomnessSource(bytes.NewReader([]byte("salt1")))); if err!=nil{panic("fixture seed failed")}
   words,err:=seed.ToMnemonic([]byte(v.Password));if err!=nil{panic("fixture encode failed")}
   decoded,err:=words.ToCipherSeed([]byte(v.Password));if err!=nil||decoded.Entropy!=entropy{panic("fixture verification failed")}
   v.Phrase=strings.Join(words[:]," ");v.Birthday=decoded.Birthday;rows=append(rows,v)
 }
 if json.NewEncoder(os.Stdout).Encode(rows)!=nil{panic("fixture output failed")}
}
