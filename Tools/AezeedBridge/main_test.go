package main

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/lightningnetwork/lnd/aezeed"
)

// These are public LND-derived vectors, never live wallet credentials.
func TestProductionVectorsAndRejection(t *testing.T) {
	data, err := os.ReadFile("../../Packages/OathAezeed/Tests/OathAezeedTests/Fixtures/lnd-production.json")
	if err != nil {
		t.Fatal(err)
	}
	var rows []struct {
		Phrase, Password string
		Version          uint8
		Birthday         uint16
	}
	if err := json.Unmarshal(data, &rows); err != nil {
		t.Fatal(err)
	}
	want, _ := hex.DecodeString("81b637d86359e6960de795e41e0b4cfd")
	for i, row := range rows {
		encoded := packWords(t, row.Phrase)
		plain, status := decode(encoded, []byte(row.Password))
		if row.Version > 1 {
			if status != 2 {
				t.Fatalf("vector %d: unsupported version accepted", i)
			}
			continue
		}
		if status != 0 || plain[0] != row.Version || uint16(plain[1])<<8|uint16(plain[2]) != row.Birthday || string(plain[3:]) != string(want) {
			t.Fatalf("vector %d mismatch", i)
		}
		if _, status := decode(encoded, []byte("wrong public fixture password")); status == 0 {
			t.Fatal("wrong password accepted")
		}
		for j := range encoded {
			corrupt := append([]byte(nil), encoded...)
			corrupt[j] ^= 1
			if _, status := decode(corrupt, []byte(row.Password)); status == 0 {
				t.Fatalf("tampered byte %d accepted", j)
			}
		}
	}
	for _, n := range []int{0, 1, 32, 34, 4096} {
		if _, status := decode(make([]byte, n), nil); status != 1 {
			t.Fatalf("length %d accepted", n)
		}
	}
	if _, status := decode(make([]byte, 33), make([]byte, 4097)); status != 1 {
		t.Fatal("oversized password accepted")
	}
}

func packWords(t *testing.T, phrase string) []byte {
	t.Helper()
	words := strings.Fields(phrase)
	if len(words) != 24 {
		t.Fatal("invalid fixture")
	}
	index := make(map[string]int)
	for i, word := range aezeed.DefaultWordList {
		index[word] = i
	}
	encoded := make([]byte, 33)
	for n, word := range words {
		value, ok := index[word]
		if !ok {
			t.Fatal("unknown fixture word")
		}
		for bit := 0; bit < 11; bit++ {
			position := n*11 + bit
			encoded[position/8] |= byte((value>>(10-bit))&1) << (7 - position%8)
		}
	}
	return encoded
}
