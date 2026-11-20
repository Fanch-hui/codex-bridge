package redact

import (
	"regexp"
	"strings"
	"unicode"

	"codexbridge/modelprotocol/internal/lazyre"
)

func fieldAt(s string, a, b int) bool {
	if !notCode(s, a, b) {
		return false
	}
	v := s[a:b]
	if v[0] == '=' {
		return false
	}
	return !fileField(s, a) && !lineRef(v) && !pathValue(v) && !namesASecret(v) && !skillName(s, a, b) && !versionValue(v) && !timestampValue(v)
}

var versionRangeRe = lazyre.New(`^(?:[~^]|[<>=!~]=?|==)?[vV]?\d+(?:\.\d+)+` +
	`(?:[-+._]?(?:(?i:alpha|beta|rc|pre|preview|post|dev|canary|next|nightly|snapshot|release|final|ga|stable|build|incubating)\d*|[abcmABCM]\d+|\d+))*$`)

func versionValue(v string) bool { return versionRangeRe.MatchString(v) }

var stampRe = lazyre.New(`^\d{4}-\d{1,2}-\d{1,2}[Tt]\d{1,2}(?::\d{1,2}){0,2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:?\d{2})?$`)

func timestampValue(v string) bool { return stampRe.MatchString(v) }

func skillName(s string, a, b int) bool {
	if a < 2 || s[a-1] != ':' || !skillSlugRe.MatchString(s[a:b]) || notASlug(s[a:b]) {
		return false
	}
	i := a - 1
	for i > 0 && strings.IndexByte("abcdefghijklmnopqrstuvwxyz0123456789-", s[i-1]) >= 0 {
		i--
	}
	return i < a-1 && (i == 0 || strings.IndexByte(alnum+"_.", s[i-1]) < 0) && skillSlugRe.MatchString(s[i:a-1])
}

var skillSlugRe = lazyre.New(`^[a-z0-9]+(?:-[a-z0-9]+)+$`)

var lineRefRe = lazyre.New(`^L?\d+(?:[-–:]L?\d+)*[.,;:]?$`)

func lineRef(v string) bool { return lineRefRe.MatchString(v) }

func fileField(s string, a int) bool {
	i := a
	for i > 0 && strings.IndexByte(" \t\"'\\", s[i-1]) >= 0 {
		i--
	}
	if i == 0 || s[i-1] != ':' && s[i-1] != '=' {
		return false
	}
	i--
	for i > 0 && strings.IndexByte(" \t\"'\\", s[i-1]) >= 0 {
		i--
	}
	end := i
	for i > 0 && strings.IndexByte(alnum+"_.-", s[i-1]) >= 0 {
		i--
	}
	name := s[i:end]
	if name == "" {
		return false
	}
	if i > 0 && (s[i-1] == '/' || s[i-1] == '\\') {
		return true
	}
	dot := strings.LastIndexByte(name, '.')
	return dot > 0 && sourceExt[strings.ToLower(name[dot+1:])]
}

var sourceExt = map[string]bool{
	"go": true, "ts": true, "tsx": true, "mts": true, "cts": true, "js": true, "jsx": true, "mjs": true, "cjs": true,
	"py": true, "pyi": true, "rb": true, "rs": true, "java": true, "kt": true, "kts": true, "swift": true,
	"c": true, "h": true, "cc": true, "cpp": true, "cxx": true, "hpp": true, "hh": true, "m": true, "mm": true,
	"cs": true, "fs": true, "php": true, "scala": true, "dart": true, "lua": true, "zig": true, "nim": true,
	"ex": true, "exs": true, "erl": true, "hs": true, "ml": true, "clj": true, "r": true, "jl": true,
	"sh": true, "bash": true, "zsh": true, "fish": true, "ps1": true, "vue": true, "svelte": true, "astro": true,
	"md": true, "mdx": true, "rst": true, "sql": true, "proto": true, "graphql": true, "gradle": true,
	"html": true, "css": true, "scss": true, "less": true, "json": true, "jsonc": true, "yaml": true, "yml": true,
	"toml": true, "xml": true, "tf": true, "ipynb": true,
}

var pathRoots = []string{
	"Users", "home", "tmp", "private", "var", "etc", "run", "opt", "usr", "mnt", "Volumes", "root", "srv",
	"data", "workspace", "workspaces", "app", "Applications", "Library", "System", "proc", "dev", "sys", "nix",
}

func pathValue(v string) bool {
	if strings.ContainsAny(v, "+=") {
		return false
	}
	for _, p := range []string{"~/", "./", "../"} {
		if strings.HasPrefix(v, p) && len(v) > len(p) {
			return true
		}
	}
	if !strings.HasPrefix(v, "/") {
		return false
	}
	first, rest, ok := strings.Cut(v[1:], "/")
	if !ok || rest == "" {
		return false
	}
	for _, r := range pathRoots {
		if first == r {
			return true
		}
	}
	return false
}

var secretWords = map[string]bool{
	"token": true, "tokens": true, "secret": true, "secrets": true, "password": true, "passwords": true,
	"passwd": true, "pwd": true, "key": true, "keys": true, "apikey": true, "credential": true, "credentials": true,
}

var identRe = lazyre.New(`^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$`)

func namesASecret(v string) bool {
	if !identRe.MatchString(v) {
		return false
	}
	if !unicode.IsLower(rune(v[0])) && !strings.ContainsAny(v, "_.") {
		return false
	}
	words, named := 0, false
	for _, w := range identWords(v) {
		if strings.IndexFunc(w, unicode.IsLetter) < 0 {
			continue
		}
		words++
		if i := strings.IndexAny(w, digits); i >= 0 {
			w = w[:i]
		}
		if secretWords[strings.ToLower(w)] {
			named = true
		}
	}
	return words >= 2 && named
}

func identWords(v string) []string {
	var out []string
	for _, part := range strings.FieldsFunc(v, func(r rune) bool { return r == '_' || r == '.' }) {
		start := 0
		for i := 1; i < len(part); i++ {
			if part[i] >= 'A' && part[i] <= 'Z' && part[i-1] >= 'a' && part[i-1] <= 'z' {
				out = append(out, part[start:i])
				start = i
			}
		}
		out = append(out, part[start:])
	}
	return out
}

var nextFieldRe = lazyre.New(`^(?:[A-Z_][A-Z0-9_]*|[a-z_][a-z0-9_-]*|--?[A-Za-z][A-Za-z0-9_-]*)=[^=]`)

func nextField(s string, a, b int) bool {
	return a > 0 && (s[a-1] == ' ' || s[a-1] == '\t') && nextFieldRe.MatchString(s[a:b])
}

func fieldMatches(re *regexp.Regexp, s string) [][]int {
	var out [][]int
	for at := 0; ; {
		again := -1
		for _, m := range re.FindAllStringSubmatchIndex(s[at:], -1) {
			for x := range m {
				if m[x] >= 0 {
					m[x] += at
				}
			}
			if len(m) > 3 && m[2] > at && nextField(s, m[2], m[3]) {
				again = m[2]
				break
			}
			out = append(out, m)
		}
		if again < 0 {
			return out
		}
		at = again
	}
}
