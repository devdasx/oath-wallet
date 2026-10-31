// The bridge deliberately exposes no network, file, logging or wallet RPC API.
// LND's pinned aezeed implementation owns AEZ and scrypt; do not reimplement
// either cipher in the app. Input/output lengths are fixed except the bounded
// passphrase, whose bytes are passed unchanged (including whitespace/Unicode).
package main

/*
#include <stdint.h>
#include <stddef.h>
*/
import "C"

import (
	"errors"
	"unsafe"
 "sync"

	"github.com/lightningnetwork/lnd/aezeed"
)

var decodeLock sync.Mutex

func decode(encoded []byte, passphrase []byte) (plain [19]byte, status int) {
	if len(encoded) != aezeed.EncipheredCipherSeedSize || len(passphrase) > 4096 {
		return plain, 1
	}
	decodeLock.Lock()
 defer decodeLock.Unlock()
 var mnemonic aezeed.Mnemonic
	for word := range mnemonic {
		index := 0
		for bit := 0; bit < 11; bit++ {
			position := word*11 + bit
			index = (index << 1) | int((encoded[position/8] >> (7 - position%8)) & 1)
		}
		mnemonic[word] = aezeed.DefaultWordList[index]
	}
	seed, err := mnemonic.ToCipherSeed(passphrase)
	if err != nil {
		switch {
		case errors.Is(err, aezeed.ErrInvalidPass):
			return plain, 3
		case errors.Is(err, aezeed.ErrIncorrectVersion):
			return plain, 2
		default:
			return plain, 1
		}
	}
	defer clear(seed.Entropy[:])
	// LND currently knows legacy (0) and taproot (1) seed versions. Unknown
	// versions must never silently recover an apparently empty wallet.
	if seed.InternalVersion > 1 {
		return plain, 2
	}
	plain[0] = seed.InternalVersion
	plain[1] = byte(seed.Birthday >> 8)
	plain[2] = byte(seed.Birthday)
	copy(plain[3:], seed.Entropy[:])
	return plain, 0
}

//export OathAezeedDecode
func OathAezeedDecode(encoded *C.uint8_t, encodedLength C.size_t, pass *C.uint8_t, passLength C.size_t, output *C.uint8_t, outputLength C.size_t) (status C.int) {
	if output == nil || outputLength != 19 {
		return 1
	}
	out := unsafe.Slice((*byte)(unsafe.Pointer(output)), 19)
	clear(out)
	// No Go error text crosses the ABI: unknown-word errors contain input.
	defer func() {
		if recover() != nil {
			clear(out)
			status = 1
		}
	}()
	if encoded == nil || encodedLength != 33 || passLength > 4096 || (pass == nil && passLength != 0) {
		return 1
	}
	bytes := C.GoBytes(unsafe.Pointer(encoded), C.int(encodedLength))
	password := C.GoBytes(unsafe.Pointer(pass), C.int(passLength))
	defer clear(bytes)
	defer clear(password)
	plain, code := decode(bytes, password)
	defer clear(plain[:])
	if code == 0 {
		copy(out, plain[:])
	}
	return C.int(code)
}

func main() {}
