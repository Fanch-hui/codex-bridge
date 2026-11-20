package gateway

import (
	"crypto/sha256"
	"encoding/base64"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	sigKeyBytes = 12
	sigKeep     = 90 * 24 * time.Hour
)

var (
	sigDir func() string

	sigPruneMu   sync.Mutex
	sigPrunedAt  time.Time
	sigPruneTick = time.Hour
)

func sigKey(sig string) string {
	h := sha256.Sum256([]byte(sig))
	return base64.RawURLEncoding.EncodeToString(h[:sigKeyBytes])
}

func keepSignature(sig string) string {
	key, dir := sigKey(sig), sigDir()
	path := filepath.Join(dir, key)
	if b, err := os.ReadFile(path); err == nil && string(b) == sig {
		now := time.Now()
		os.Chtimes(path, now, now)
		return key
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return ""
	}
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return ""
	}
	_, werr := tmp.WriteString(sig)
	cerr := tmp.Close()
	if werr != nil || cerr != nil || os.Rename(tmp.Name(), path) != nil {
		os.Remove(tmp.Name())
		return ""
	}
	pruneSignatures(dir)
	return key
}

func keptSignature(key string) string {
	if len(key) != base64.RawURLEncoding.EncodedLen(sigKeyBytes) {
		return ""
	}
	if _, err := base64.RawURLEncoding.DecodeString(key); err != nil {
		return ""
	}
	path := filepath.Join(sigDir(), key)
	b, err := os.ReadFile(path)
	if err != nil || len(b) == 0 || sigKey(string(b)) != key {
		return ""
	}
	now := time.Now()
	os.Chtimes(path, now, now)
	return string(b)
}

func pruneSignatures(dir string) {
	sigPruneMu.Lock()
	if time.Since(sigPrunedAt) < sigPruneTick {
		sigPruneMu.Unlock()
		return
	}
	sigPrunedAt = time.Now()
	sigPruneMu.Unlock()
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		info, err := e.Info()
		if err != nil || e.IsDir() {
			continue
		}
		age := time.Since(info.ModTime())
		if age > sigKeep || (e.Name()[0] == '.' && age > time.Hour) {
			os.Remove(filepath.Join(dir, e.Name()))
		}
	}
}

const signerExt = ".by"

func signerOf(sig string) string {
	if sig == "" || sig == skipSignature {
		return ""
	}
	path := filepath.Join(sigDir(), sigKey(sig)+signerExt)
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	now := time.Now()
	os.Chtimes(path, now, now)
	return string(b)
}
