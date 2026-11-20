package gateway

import (
	"bytes"
	"strings"
	"unsafe"
)

func bodyHas(b []byte, sep string) bool { return bodyIndex(b, sep) >= 0 }

func bodyIndex(b []byte, sep string) int {
	if len(sep) < 2 || len(b) < 1024 {
		return indexStr(b, sep)
	}
	k := rarestByte(sep)
	c := sep[k]
	misses := 0
	for i := k; i < len(b); {
		j := bytes.IndexByte(b[i:], c)
		if j < 0 {
			return -1
		}
		at := i + j - k
		if at+len(sep) > len(b) {
			return -1
		}
		if string(b[at:at+len(sep)]) == sep {
			return at
		}
		i += j + 1

		if misses++; misses > 64 && misses*64 > i {
			if n := indexStr(b[at+1:], sep); n >= 0 {
				return at + 1 + n
			}
			return -1
		}
	}
	return -1
}

func indexStr(b []byte, sep string) int {
	return strings.Index(unsafe.String(unsafe.SliceData(b), len(b)), sep)
}

const commonBytes = " \"etaoinsrhldcu:,mpf{}gy_wb.\nv/k-x0123456789TISACE\\"

var byteRank = func() (r [256]uint8) {
	for i := range len(commonBytes) {
		r[commonBytes[i]] = uint8(len(commonBytes) - i)
	}
	return r
}()

func rarestByte(sep string) int {
	k := 0
	for i := 1; i < len(sep); i++ {
		if byteRank[sep[i]] <= byteRank[sep[k]] {
			k = i
		}
	}
	return k
}

func bodyHasBytes(b, sep []byte) bool { return bodyIndex(b, bytesStr(sep)) >= 0 }

func bytesStr(b []byte) string { return unsafe.String(unsafe.SliceData(b), len(b)) }
