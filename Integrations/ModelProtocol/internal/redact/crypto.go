package redact

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	_ "embed"
	"encoding/base32"
	"math/big"
	"strconv"
	"strings"
	"sync"

	"codexbridge/modelprotocol/internal/lazyre"
)

var cryptoRules = []rule{

	{kind: "WALLET_KEY", fold: walletKeyCues, back: 64, ahead: 160, bound: alnum, at: walletKeyAt,
		re: lazyre.New(`(?i)0x[0-9a-f]{56,64}|[0-9a-f]{64}`)},

	{kind: "WIF_KEY", bound: alnum, ok: wifKey, may: b58Run(51),
		re: lazyre.New(`[1-9A-HJ-NP-Za-km-z]{51,}`)},

	{kind: "BIP32_KEY", markers: []string{"prv"}, bound: alnum, ok: bip32Key,
		re: lazyre.New(`[xyztuvYZUV]prv[1-9A-HJ-NP-Za-km-z]{107}`)},

	{kind: "SOLANA_KEY", bound: alnum, ok: solanaKey, may: b58Run(85),
		re: lazyre.New(`[1-9A-HJ-NP-Za-km-z]{85,}`)},

	{kind: "SOLANA_KEYPAIR", markers: []string{"["}, ok: solanaKeypair,
		re: lazyre.New(`\[\s*\d{1,3}(?:\s*,\s*\d{1,3}){63}\s*\]`)},

	{kind: "NEAR_KEY", markers: []string{"ed25519:"}, bound: alnum,
		re: lazyre.New(`ed25519:[1-9A-HJ-NP-Za-km-z]{86,88}`)},

	{kind: "SUI_KEY", markers: []string{"suiprivkey1"}, bound: alnum,
		re: lazyre.New(`suiprivkey1[0-9a-z]{58}`)},

	{kind: "APTOS_KEY", markers: []string{"-priv-0x"}, bound: alnum,
		re: lazyre.New(`(?:ed25519|secp256k1)-priv-0x[0-9a-fA-F]{64}`)},

	{kind: "STELLAR_KEY", bound: alnum, ok: stellarSeed, may: base32Run(56),
		re: lazyre.New(`S[A-Z2-7]{55}`)},

	{kind: "NOSTR_KEY", markers: []string{"nsec1"}, bound: alnum,
		re: lazyre.New(`nsec1[02-9ac-hj-np-z]{58}`)},

	{kind: "AGE_KEY", markers: []string{"AGE-SECRET-KEY-"}, bound: alnum,
		re: lazyre.New(`AGE-SECRET-KEY-1[0-9A-Z]{58}`)},

	{kind: "ZCASH_KEY", markers: []string{"secret-extended-key-"}, bound: alnum,
		re: lazyre.New(`secret-extended-key-(?:main|test)1[0-9a-z]{150,320}`)},

	{kind: "SEED_PHRASE", fold: seedCues, back: 32, ahead: 400, fix: seedPhraseAt,
		re: lazyre.New(`(?i)(?:seed|mnemonic|phrase|recovery|助记词|助記詞|シード|ニーモニック|시드|니모닉)[^.\n]{0,24}?(?:\n[ \t]*)?\b([a-z]{3,8}(?:[ \t]+[a-z]{3,8}){11,40})\b`)},
}

var walletKeyCues = []string{"priv", "secret", "signer", "signing", "deployer", "wallet", "pk", "私钥", "私鑰", "秘密鍵", "개인키", "비밀키"}

var notKeyWords = []string{"hash", "sha", "digest", "sum", "pub", "addr", "tx", "fingerprint", "id"}

func walletKeyAt(s string, a, b int) bool {
	start := max(0, a-48)
	if nl := strings.LastIndexByte(s[start:a], '\n'); nl >= 0 {
		start += nl + 1
	}
	before := lowerASCII(s[start:a])
	cue, end := -1, 0
	for _, c := range walletKeyCues {
		for i := 0; ; {
			j := strings.Index(before[i:], c)
			if j < 0 {
				break
			}
			at := i + j
			i = at + len(c)

			if c == "pk" && (at > 0 && isLetter(before[at-1]) || i < len(before) && isLetter(before[i])) {
				continue
			}
			if at > cue {
				cue, end = at, i
			}
		}
	}
	if cue < 0 {
		return false
	}
	between := before[end:]
	for _, w := range notKeyWords {
		if w == "id" {

			if t := strings.TrimLeft(between, "_- "); strings.HasPrefix(t, "id") && (len(t) == 2 || !isLetter(t[2])) {
				return false
			}
			continue
		}
		if strings.Contains(between, w) {
			return false
		}
	}
	return true
}

func isLetter(c byte) bool { return 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' }

const b58Alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

var b58Index = func() (t [256]int8) {
	for i := range t {
		t[i] = -1
	}
	for i := 0; i < len(b58Alphabet); i++ {
		t[b58Alphabet[i]] = int8(i)
	}
	return t
}()

func base58(s string) []byte {
	n := new(big.Int)
	radix := big.NewInt(58)
	for i := 0; i < len(s); i++ {
		d := b58Index[s[i]]
		if d < 0 {
			return nil
		}
		n.Mul(n, radix)
		n.Add(n, big.NewInt(int64(d)))
	}
	zeros := 0
	for zeros < len(s) && s[zeros] == '1' {
		zeros++
	}
	return append(make([]byte, zeros), n.Bytes()...)
}

func base58check(s string) []byte {
	b := base58(s)
	if len(b) < 5 {
		return nil
	}
	p, sum := b[:len(b)-4], b[len(b)-4:]
	h := sha256.Sum256(p)
	h = sha256.Sum256(h[:])
	if !bytes.Equal(h[:4], sum) {
		return nil
	}
	return p
}

func wifKey(v string) bool {
	if len(v) != 51 && len(v) != 52 {
		return false
	}
	p := base58check(v)
	return len(p) == 33 || len(p) == 34 && p[33] == 1
}

func bip32Key(v string) bool {
	return len(base58check(v)) == 78
}

func solanaKey(v string) bool {
	if len(v) < 85 || len(v) > 88 {
		return false
	}
	return seedAndPublic(base58(v))
}

func seedAndPublic(b []byte) bool {
	if len(b) != ed25519.PrivateKeySize {
		return false
	}
	return bytes.Equal(ed25519.NewKeyFromSeed(b[:ed25519.SeedSize]), b)
}

func solanaKeypair(v string) bool {
	parts := strings.Split(strings.Trim(v, "[] \t\r\n"), ",")
	if len(parts) != ed25519.PrivateKeySize {
		return false
	}
	b := make([]byte, len(parts))
	for i, p := range parts {
		n, err := strconv.Atoi(strings.TrimSpace(p))
		if err != nil || n > 255 {
			return false
		}
		b[i] = byte(n)
	}
	return seedAndPublic(b)
}

func stellarSeed(v string) bool {
	b, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(v)
	if err != nil || len(b) != 35 || b[0] != 18<<3 {
		return false
	}
	c := crc16XModem(b[:33])
	return b[33] == byte(c) && b[34] == byte(c>>8)
}

func crc16XModem(b []byte) uint16 {
	var c uint16
	for _, x := range b {
		c ^= uint16(x) << 8
		for range 8 {
			if c&0x8000 != 0 {
				c = c<<1 ^ 0x1021
			} else {
				c <<= 1
			}
		}
	}
	return c
}

var seedCues = []string{"seed", "mnemonic", "phrase", "recovery", "助记词", "助記詞", "シード", "ニーモニック", "시드", "니모닉"}

var bip39EnglishText string

var bip39English = sync.OnceValue(func() map[string]bool {
	m := make(map[string]bool, 2048)
	for _, w := range strings.Fields(bip39EnglishText) {
		m[w] = true
	}
	return m
})

var phraseLengths = []int{25, 24, 21, 18, 15, 12}

func seedPhraseAt(s string, a, b int) (int, int, bool) {
	list := bip39English()
	bestA, bestN, bestEnd := 0, 0, 0
	runA, runN := -1, 0
	ends := []int{}
	for i := a; i < b; {
		for i < b && (s[i] == ' ' || s[i] == '\t') {
			i++
		}
		j := i
		for j < b && s[j] != ' ' && s[j] != '\t' {
			j++
		}
		if i == j {
			break
		}
		if list[strings.ToLower(s[i:j])] {
			if runA < 0 {
				runA, runN, ends = i, 0, ends[:0]
			}
			runN++
			ends = append(ends, j)
			if runN > bestN {
				bestA, bestN, bestEnd = runA, runN, j
				for _, l := range phraseLengths {
					if runN >= l {
						bestEnd = ends[l-1]
						break
					}
				}
			}
		} else {
			runA = -1
		}
		i = j
	}
	if bestN < 12 {
		return 0, 0, false
	}
	return bestA, bestEnd, true
}

func b58Run(n int) func(string) bool {
	return func(s string) bool {
		run := 0
		for i := 0; i < len(s); i++ {
			if b58Index[s[i]] >= 0 {
				if run++; run >= n {
					return true
				}
			} else {
				run = 0
			}
		}
		return false
	}
}

func base32Run(n int) func(string) bool {
	return func(s string) bool {
		run := 0
		for i := 0; i < len(s); i++ {
			if c := s[i]; c >= 'A' && c <= 'Z' || c >= '2' && c <= '7' {
				if run++; run >= n {
					return true
				}
			} else {
				run = 0
			}
		}
		return false
	}
}
