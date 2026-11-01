package main

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"encoding"
	"fmt"
	"testing"

	"gitlab.com/yawning/bsaes.git/ct32"
	"gitlab.com/yawning/bsaes.git/ct64"
	"golang.org/x/crypto/blake2b"
)

// Only public synthetic inputs. These tests must run against the prepared
// vendor tree; unchanged tests also demonstrate the original dependency defects.
func didPanic(f func()) (panicked bool) {
	defer func() { panicked = recover() != nil }()
	f()
	return
}

func TestCBCRejectsPartialBlocksWithoutMutation(t *testing.T) {
	for name, factory := range map[string]func([]byte) cipher.Block{"ct32": ct32.NewCipher, "ct64": ct64.NewCipher} {
		for _, length := range []int{1, 15, 17, 31, 33, 63, 65, 129} {
			t.Run(fmt.Sprintf("%s/%d", name, length), func(t *testing.T) {
				key, iv := make([]byte, 16), bytes.Repeat([]byte{0x42}, 16)
				mode := cipher.NewCBCDecrypter(factory(key), iv)
				out := bytes.Repeat([]byte{0x55}, length)
				if !didPanic(func() { mode.CryptBlocks(out, make([]byte, length)) }) {
					t.Fatal("partial final block accepted")
				}
				if !bytes.Equal(out, bytes.Repeat([]byte{0x55}, length)) {
					t.Fatal("rejected input changed output")
				}
				got, want := make([]byte, 16), make([]byte, 16)
				standard, _ := aes.NewCipher(key)
				cipher.NewCBCDecrypter(standard, iv).CryptBlocks(want, make([]byte, 16))
				mode.CryptBlocks(got, make([]byte, 16))
				if !bytes.Equal(got, want) {
					t.Fatal("rejected input changed chaining state")
				}
			})
		}
	}
}

func TestCBCRejectsShortOutputWithoutMutation(t *testing.T) {
	for _, factory := range []func([]byte) cipher.Block{ct32.NewCipher, ct64.NewCipher} {
		mode := cipher.NewCBCDecrypter(factory(make([]byte, 16)), make([]byte, 16))
		out := bytes.Repeat([]byte{0x55}, 31)
		if !didPanic(func() { mode.CryptBlocks(out, make([]byte, 32)) }) {
			t.Fatal("short output accepted")
		}
		if !bytes.Equal(out, bytes.Repeat([]byte{0x55}, 31)) {
			t.Fatal("short output modified before rejection")
		}
	}
}

func TestBlakeRejectsInvalidStateWithoutMutation(t *testing.T) {
	for _, parameter := range []struct{ position, value int }{
		{83, 0}, {83, 65}, {83, 255}, {212, 129}, {212, 255},
	} {
		t.Run(fmt.Sprintf("%d/%d", parameter.position, parameter.value), func(t *testing.T) {
			h, _ := blake2b.New(48, nil)
			h.Write([]byte("public state preservation fixture"))
			original, _ := h.(encoding.BinaryMarshaler).MarshalBinary()
			corrupt := append([]byte(nil), original...)
			corrupt[parameter.position] = byte(parameter.value)
			if h.(encoding.BinaryUnmarshaler).UnmarshalBinary(corrupt) == nil {
				t.Fatal("invalid parameters accepted")
			}
			after, _ := h.(encoding.BinaryMarshaler).MarshalBinary()
			if !bytes.Equal(original, after) {
				t.Fatal("invalid state changed receiver")
			}
		})
	}
}

func TestBlakeValidStateRoundTrips(t *testing.T) {
	for _, size := range []int{1, 32, 48, 64} {
		for _, length := range []int{0, 1, 127, 128, 129, 255, 256} {
			h, _ := blake2b.New(size, nil)
			h.Write(bytes.Repeat([]byte{0x42}, length))
			state, _ := h.(encoding.BinaryMarshaler).MarshalBinary()
			copyHash, _ := blake2b.New(64, nil)
			if err := copyHash.(encoding.BinaryUnmarshaler).UnmarshalBinary(state); err != nil {
				t.Fatal(err)
			}
			h.Write([]byte("continuation"))
			copyHash.Write([]byte("continuation"))
			if !bytes.Equal(h.Sum(nil), copyHash.Sum(nil)) {
				t.Fatal("valid state round trip changed digest")
			}
		}
	}
}

func TestGCMLargeLengthEncoding(t *testing.T) {
	// 512 MiB is the first 32-bit *bit*-length overflow. Test each of the three
	// encoded length fields using the actual implementation and standard GCM.
	large := make([]byte, 1<<29)
	for _, kind := range []string{"aad-ct32", "aad-ct64", "nonce-ct64", "plaintext-ct64"} {
		t.Run(kind, func(t *testing.T) {
			var ad, plain []byte
			nonce := make([]byte, 12)
			factory := ct64.NewCipher
			switch kind {
			case "aad-ct32":
				ad = large
				factory = ct32.NewCipher
			case "aad-ct64":
				ad = large
			case "nonce-ct64":
				nonce = large
			case "plaintext-ct64":
				plain = large
			}
			key := make([]byte, 16)
			standard, _ := aes.NewCipher(key)
			reference, err := cipher.NewGCMWithNonceSize(standard, len(nonce))
			if err != nil {
				t.Fatal(err)
			}
			candidate, err := factory(key).(interface {
				NewGCM(int) (cipher.AEAD, error)
			}).NewGCM(len(nonce))
			if err != nil {
				t.Fatal(err)
			}
			want := reference.Seal(nil, nonce, plain, ad)
			got := candidate.Seal(nil, nonce, plain, ad)
			if !bytes.Equal(got, want) {
				t.Fatal("full-width length tag differs from standard GCM")
			}
			decoded, err := candidate.Open(nil, nonce, want, ad)
			if err != nil || !bytes.Equal(decoded, plain) {
				t.Fatal("standard GCM ciphertext did not open")
			}
			got[len(got)-1] ^= 1
			if _, err = candidate.Open(nil, nonce, got, ad); err == nil {
				t.Fatal("tampered large-input tag accepted")
			}
		})
	}
}
