package redact

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"

	"golang.org/x/net/publicsuffix"

	"codexbridge/modelprotocol/internal/lazyre"
)

type Options struct {
	Secrets  bool
	Personal bool
	Words    []string

	WordsAnyCase bool

	WordsWhole bool
	Rules      []Rule

	Kinds map[string]bool

	Model Model

	Route string

	MinScore float64

	NamesByModel bool

	Shape bool

	Actions map[string]string

	Allow []string

	Seen func(Hit)

	found map[string][]Found

	args bool

	sent bool
}

func (o Options) covers(cat string) bool {
	switch cat {
	case "":
		return o.Secrets
	case catPersonal:
		return o.Personal
	}
	if !o.Personal {
		return false
	}
	if on, ok := o.Kinds[cat]; ok {
		return on
	}
	return categoryOn[cat]
}

type rule struct {
	kind    string
	re      *lazyre.RE
	markers []string

	fold  []string
	bound string
	ok    func(string) bool

	at func(s string, a, b int) bool

	fix func(s string, a, b int) (int, int, bool)

	back, ahead int

	cat string

	field bool

	yours bool

	anyGroup bool

	groups  []string
	groupOK []func(string) bool

	may func(string) bool
}

const (
	alnum   = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
	tokenCh = alnum + "_-"
	digits  = "0123456789"
)

var rules = append([]rule{
	{kind: "PRIVATE_KEY", re: lazyre.New(`-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----[\s\S]+?-----END (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----`), markers: []string{"PRIVATE KEY"}},
	{kind: "API_KEY", re: lazyre.New(`sk-(?:ant-|proj-|or-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}`), markers: []string{"sk-"}, bound: tokenCh, ok: notASlug},

	{kind: "API_KEY", re: lazyre.New(`[a-z]{2,4}_sk_[A-Za-z0-9_-]{20,}`), markers: []string{"_sk_"}, bound: tokenCh, ok: secretValue},

	{kind: "API_KEY", re: lazyre.New(`ark-[A-Za-z0-9][A-Za-z0-9_-]{15,}`), markers: []string{"ark-"}, bound: tokenCh, ok: secretValue},
	{kind: "API_KEY", re: lazyre.New(`(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|glpat-[A-Za-z0-9_-]{20,})`), markers: []string{"gh", "github_pat_", "glpat-"}, bound: tokenCh},
	{kind: "API_KEY", re: lazyre.New(`AIza[0-9A-Za-z_-]{35}`), markers: []string{"AIza"}, bound: tokenCh},
	{kind: "API_KEY", re: lazyre.New(`xox[abposr]-[0-9A-Za-z-]{10,}`), markers: []string{"xox"}, bound: tokenCh},
	{kind: "API_KEY", re: lazyre.New(`(?:sk|rk)_live_[0-9A-Za-z]{20,}`), markers: []string{"_live_"}, bound: tokenCh},
	{kind: "API_KEY", re: lazyre.New(`(?:AKIA|ASIA)[0-9A-Z]{16}`), markers: []string{"AKIA", "ASIA"}, bound: alnum},
	{kind: "API_KEY", re: lazyre.New(`(?:hf_[A-Za-z0-9]{30,}|gsk_[A-Za-z0-9]{40,}|xai-[A-Za-z0-9]{40,}|npm_[A-Za-z0-9]{36}|pypi-[A-Za-z0-9_-]{50,}|dop_v1_[a-f0-9]{64}|SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43})`),
		markers: []string{"hf_", "gsk_", "xai-", "npm_", "pypi-", "dop_v1_", "SG."}, bound: tokenCh},

	{kind: "API_KEY", re: lazyre.New(`cf(?:ut|at|k|oat)_[A-Za-z0-9_-]{40,}`), markers: []string{"cfut_", "cfat_", "cfk_", "cfoat_"}, bound: tokenCh},
	{kind: "API_KEY", re: lazyre.New(`v1\.0-[A-Za-z0-9]{16,}-[A-Za-z0-9]{40,}`), markers: []string{"v1.0-"}, bound: tokenCh},
	{kind: "TOKEN", re: lazyre.New(`eyJhIjoi[A-Za-z0-9+/_-]{40,}={0,2}`), markers: []string{"eyJhIjoi"}, bound: tokenCh},

	{kind: "SECRET", re: lazyre.New(`(?i)x-auth-(?:user-service-)?key["']?[ \t]*[:=][ \t]*["']?([A-Za-z0-9._-]{16,})`),
		fold: []string{"x-auth-"}, ahead: 120, ok: notAVariable},

	{kind: "TOKEN", re: lazyre.New(`eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}`), markers: []string{"eyJ"}, bound: tokenCh},

	{kind: "PASSWORD", re: lazyre.New(`[A-Za-z][A-Za-z0-9+.-]*://[^\s:@/?#"'<>]*:([^\s@/?#"'<>]{3,})@`), markers: []string{"://"}, ok: notAVariable, at: hiddenInURL},

	{kind: "SECRET", re: lazyre.New(`(?i)[A-Za-z0-9_.-]*(?:` + secretNames.pattern() + `)[A-Za-z0-9_.-]*` + quote + `[ \t]*[:=][ \t]*` + quote + `(` + secretCh + `{8,})`),
		markers: secretNames.markers(), ok: secretValue, at: fieldAt, field: true},

	{kind: "SECRET", re: lazyre.New(`(?:^|[^A-Za-z0-9_.-])[A-Za-z0-9_.-]*_(?:KEY|PASS)` + quote + `[ \t]*[:=][ \t]*` + quote + `(` + secretCh + `{8,})`),
		markers: fieldNames{{"key", "key"}, {"pass", "pass"}}.markers(), ok: secretValue, at: namedSecretAt, field: true},

	{kind: "SECRET", re: lazyre.New(`(?im)^[ \t]*(?:authorization|cookie)[ \t]*:[ \t]*(\S[^\r\n]{7,})`),
		markers: fieldNames{{"authorization", "authorization"}, {"cookie", "cookie"}}.markers(), ok: headerValue},

	{kind: "SECRET", re: lazyre.New(`(?i)(?:^|[^A-Za-z0-9_.-])` + quote + `key` + quote + `[ \t]*[:=][ \t]*` + quote + `(` + secretCh + `{16,})`),
		markers: fieldNames{{"key", "key"}}.markers(), ok: secretValue, at: fieldAt, field: true},

	{kind: "PASSWORD", re: cjkNamed(cjkPasswordNames), fold: lowerAll(cjkPasswordNames), back: 64, ahead: 100, ok: notAVariable, field: true},

	{kind: "SECRET", re: cjkNamed(cjkKeyNames), fold: lowerAll(cjkKeyNames), back: 64, ahead: 100, at: keyAt, field: true},

	{kind: "SECRET", re: lazyre.New(`(?i)(?:` + secretNames.pattern() + `|pwd|api[ ]key|access[ ]key|secret[ ]key|key|\bpin(?:[ ]?code)?)` + quote +
		`[ \t]*(?:[为為是][ \t]*[:：]?|：)[ \t]*(?:\\?["'“「])?(` + secretCh + `{3,}[A-Za-z0-9_\-/+=~!@#%^&*])`),
		fold: cjkCopulas, back: 24, ahead: 260, at: keyAt, field: true},

	{kind: "EMAIL", re: lazyre.New(`[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}`), markers: []string{"@"}, bound: alnum + "_%+-", ok: realEmail, at: emailAt, cat: catPersonal},
	{kind: "ID_CARD", re: lazyre.New(`[1-9]\d{5}(?:18|19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx]`), bound: alnum, ok: chineseID, cat: catPersonal},
	{kind: "PHONE", re: lazyre.New(`(?:\+?86[- ]?)?1[3-9]\d{9}`), bound: alnum, at: phoneAt, cat: catPersonal},
	{kind: "BANK_CARD", re: lazyre.New(`[3-6]\d{3}(?:[ -]?\d{4}){2,3}(?:[ -]?\d{1,3})?`), bound: alnum, ok: luhn, cat: catPersonal},
}, append(moreRules, cryptoRules...)...)

var cjkPasswordNames = []string{"密码", "密碼", "口令", "PIN码", "PIN碼", "PIN 码", "安全码", "安全碼", "パスワード", "暗証番号", "비밀번호", "암호", "비번"}

var cjkKeyNames = []string{
	"密钥", "密鑰", "秘钥", "秘鑰", "私钥", "私鑰", "金钥", "金鑰", "令牌", "权杖", "權杖", "授权码", "授權碼",
	"秘密鍵", "トークン", "シークレット", "APIキー", "アクセスキー",
	"토큰", "비밀키", "API 키", "API키",
}

var cjkCopulas = []string{"为", "為", "是", "："}

func lowerAll(names []string) []string {
	out := make([]string, len(names))
	for i, n := range names {
		out[i] = strings.ToLower(n)
	}
	return out
}

func cjkNamed(names []string) *lazyre.RE {
	return lazyre.New(`(?i)(?:` + strings.Join(names, "|") + `)[ \t]*(?:[:：=][ \t]*|[为為是][ \t]*[:：]?[ \t]*|は[ \t]*|는[ \t]*)?(?:\\?["'“「])?(` + secretCh + `{3,63}[A-Za-z0-9_\-/+=~!@#%^&*])`)
}

type fieldNames []struct{ re, marker string }

var secretNames = fieldNames{
	{"password", "pass"}, {"passwd", "pass"},

	{"passphrase", "pass"},
	{"secret", "secret"},
	{"token", "token"},
	{`api[_-]?key`, "key"}, {`access[_-]?key`, "key"}, {`private[_-]?key`, "key"}, {`priv[_-]?key`, "key"},
	{"credential", "credential"},
}

func (f fieldNames) pattern() string {
	res := make([]string, len(f))
	for i, n := range f {
		res[i] = n.re
	}
	return strings.Join(res, "|")
}

func (f fieldNames) markers() []string {
	var out []string
	for _, n := range f {
		for _, m := range []string{n.marker, strings.ToUpper(n.marker), strings.ToUpper(n.marker[:1]) + n.marker[1:]} {
			if !slices.Contains(out, m) {
				out = append(out, m)
			}
		}
	}
	return out
}

const (
	quote = `(?:\\?["'])?`

	secretCh = `[A-Za-z0-9_\-./+=~!@#%^&*]`
)

var placeholderRe = lazyre.New(`\{\{[A-Z][A-Z0-9_]*_[a-z2-7]{8}\}\}`)

func notAVariable(v string) bool {
	if strings.ContainsAny(v[:1], "$%{<[*") {
		return false
	}
	return strings.Trim(v, "*xX.") != ""
}

func keyValue(v string) bool {
	if !notAVariable(v) {
		return false
	}
	letter := strings.IndexFunc(v, func(r rune) bool { return r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' }) >= 0
	return letter && (strings.ContainsAny(v, digits) || len(v) >= 16)
}

func keyAt(s string, a, b int) bool {
	v := s[a:b]
	if pathValue(v) || versionValue(v) || timestampValue(v) {

		return false
	}
	if keyValue(v) {
		return true
	}
	if len(v) < 6 || strings.Trim(v, digits) != "" {
		return false
	}
	before := strings.TrimRight(s[:a], " \t\"'“「\\")
	after := strings.TrimLeft(s[b:], " \t")
	return slices.ContainsFunc(keySeparators, func(c string) bool { return strings.HasSuffix(before, c) }) &&
		!slices.ContainsFunc(quantityUnits, func(u string) bool { return strings.HasPrefix(after, u) })
}

var keySeparators = []string{"为", "為", "是", "：", ":", "=", "は", "는"}

var quantityUnits = []string{"位", "比特", "字节", "字節", "个", "個", "次", "秒", "毫秒", "分钟", "分鐘", "小时", "小時", "天", "年", "bit", "byte", "ms", "sec", "min", "ビット", "バイト", "비트", "바이트"}

func secretValue(v string) bool {
	if !notAVariable(v) || strings.HasPrefix(v, "process.env") || strings.HasPrefix(v, "os.") {
		return false
	}
	return strings.ContainsAny(v, digits) && strings.IndexFunc(v, func(r rune) bool { return r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' }) >= 0
}

var identPath = lazyre.New(`^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*$`)

func notCode(s string, a, b int) bool {
	if !identPath.MatchString(s[a:b]) {
		return true
	}
	rest := strings.TrimLeft(s[b:], " \t")
	if strings.HasPrefix(rest, "(") {
		return false
	}
	if a > 0 && (s[a-1] == '"' || s[a-1] == '\'') || !strings.HasSuffix(strings.TrimRight(s[:a], " \t"), ":") {
		return true
	}
	return rest == "" || !strings.ContainsRune(";,)}]|?&<>", rune(rest[0]))
}

func notUserinfo(s string, a, _ int) bool {
	return !inUserinfo(s, a)
}

func emailAt(s string, a, b int) bool {
	if a > 0 && s[a-1] == '.' {
		return false
	}
	if b+1 < len(s) && s[b] == '.' && strings.IndexByte(tokenCh, s[b+1]) >= 0 {
		return false
	}
	return notUserinfo(s, a, b)
}

func inUserinfo(s string, a int) bool {
	i := a
	for i > 0 && !strings.ContainsRune(" \t\r\n/?#\"'<>@`", rune(s[i-1])) {
		i--
	}
	if i < 3 || s[i-1] != '/' || s[i-2] != '/' || s[i-3] != ':' {
		return false
	}
	j := i - 3
	k := j
	for k > 0 && (s[k-1] >= 'a' && s[k-1] <= 'z' || s[k-1] >= 'A' && s[k-1] <= 'Z' || s[k-1] >= '0' && s[k-1] <= '9' || strings.IndexByte("+.-", s[k-1]) >= 0) {
		k--
	}
	for k < j && !(s[k] >= 'a' && s[k] <= 'z' || s[k] >= 'A' && s[k] <= 'Z') {
		k++
	}
	return k < j
}

func hiddenInURL(s string, a, b int) bool {
	pw := s[a:b]
	i := strings.LastIndex(s[:a], "//")
	if i < 0 || s[a-1] != ':' {
		return true
	}
	if s[i+2:a-1] == pw {
		return false
	}

	end := b + 1
	for end < len(s) && !strings.ContainsRune(" \t\r\n\"'<>`\\)]}", rune(s[end])) {
		end++
	}
	if b+1 > end {
		return true
	}
	for _, part := range strings.FieldsFunc(s[b+1:end], func(r rune) bool { return strings.ContainsRune("/:.?#&=;,@", r) }) {
		if part == pw {
			return false
		}
	}
	return true
}

func notASlug(v string) bool {
	if strings.ContainsFunc(v, func(r rune) bool { return r >= 'A' && r <= 'Z' }) {
		return true
	}
	if !strings.ContainsFunc(strings.TrimPrefix(v, "sk-"), func(r rune) bool {
		return r != '-' && r != '_' && (r < '0' || r > '9') && (r < 'a' || r > 'f')
	}) {
		return true
	}
	for _, w := range strings.FieldsFunc(v, func(r rune) bool { return r == '-' || r == '_' }) {
		if len(w) >= 16 {
			return true
		}
	}
	return false
}

func headerValue(v string) bool {
	v = strings.TrimSpace(v)
	if v == "" || !notAVariable(v) {
		return false
	}
	notLetter := func(r rune) bool { return !(r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z') }
	f := strings.Fields(v)
	if len(f) == 1 || len(f) == 2 && strings.IndexFunc(f[0], notLetter) < 0 {

		cred := f[len(f)-1]
		return len(cred) >= 8 && notAVariable(cred) && strings.IndexFunc(cred, notLetter) >= 0
	}
	for _, kv := range strings.Split(v, ";") {
		if kv = strings.TrimSpace(kv); kv == "" {
			continue
		}
		name, _, ok := strings.Cut(kv, "=")
		if !ok || name == "" || strings.ContainsAny(name, " \t") {
			return false
		}
	}
	return strings.Contains(v, "=")
}

func notAPlainKey(s string, a, b int) bool {
	i := a
	for i > 0 && strings.IndexByte(`"' `+"\t:=", s[i-1]) >= 0 {
		i--
	}
	end := i
	for i > 0 && strings.IndexByte(alnum+"_.-", s[i-1]) >= 0 {
		i--
	}
	name := strings.ToLower(s[i:end])
	return !strings.HasSuffix(name, "sort_key") && !strings.HasSuffix(name, "cache_key") &&
		!strings.HasSuffix(name, "prompt_cache_key") && !strings.HasSuffix(name, "public_key")
}

func notPlainKeyOrCode(s string, a, b int) bool {
	return notAPlainKey(s, a, b) && notCode(s, a, b)
}

func namedSecretAt(s string, a, b int) bool {
	return notPlainKeyOrCode(s, a, b) && fieldAt(s, a, b)
}

func realEmail(v string) bool {
	at := strings.LastIndexByte(v, '@')
	if strings.EqualFold(v[:at], "git") {
		return false
	}
	host := strings.ToLower(v[at+1:])
	if !mailHost(v[:at], host) {
		return false
	}
	if fileHost(host) {

		if host = fileStem(host); !strings.Contains(host, ".") || fileHost(host) || !mailHost(v[:at], host) {
			return false
		}
	}
	if docFiles[host] || !mailTLD(host[strings.LastIndexByte(host, '.')+1:]) {
		return false
	}
	for _, fake := range []string{"example.com", "example.org", "example.net", "localhost", ".test", ".invalid", ".example"} {
		if host == strings.TrimPrefix(fake, ".") || strings.HasSuffix(host, fake) {
			return false
		}
	}
	return !strings.HasPrefix(host, "noreply") && !strings.Contains(v, "noreply@")
}

func mailHost(local, host string) bool {
	if strings.HasSuffix(local, "@") || !strings.Contains(host, ".") || strings.Trim(host, ".") != host {
		return false
	}
	linker := true
	for _, l := range strings.Split(host, ".") {
		if l == "" || strings.ContainsFunc(l, func(r rune) bool { return r < 0x80 && r != '-' && !(r >= 'a' && r <= 'z') && !(r >= '0' && r <= '9') }) {
			return false
		}
		if !linkerWords[l] {
			linker = false
		}
	}
	return !linker
}

var linkerWords = map[string]bool{"plt": true, "got": true, "sec": true, "iplt": true, "igot": true}

var docFiles = map[string]bool{
	"agents.md": true, "claude.md": true, "gemini.md": true, "readme.md": true, "skill.md": true,
	"changelog.md": true, "contributing.md": true, "license.md": true, "lessons.md": true, "todo.md": true,
	"copilot-instructions.md": true, "crush.md": true, "qwen.md": true, "iflow.md": true, "warp.md": true,
}

var localTLDs = map[string]bool{"local": true, "internal": true, "lan": true, "corp": true, "home": true, "intranet": true, "localdomain": true}

func mailTLD(tld string) bool {
	if localTLDs[tld] {
		return true
	}
	_, icann := publicsuffix.PublicSuffix(tld)
	return icann
}

var fileExt = map[string]bool{
	"jpg": true, "jpeg": true, "png": true, "gif": true, "webp": true, "svg": true, "heic": true, "heif": true,
	"avif": true, "bmp": true, "tif": true, "tiff": true, "ico": true, "icns": true, "pdf": true,
	"svgz": true, "apng": true, "jxl": true, "psd": true, "eps": true, "lottie": true,
	"mp4": true, "m4v": true, "webm": true, "mkv": true, "avi": true, "mp3": true, "m4a": true, "wav": true,
	"ogg": true, "flac": true, "aac": true, "ttf": true, "otf": true, "woff": true, "woff2": true, "eot": true,
	"json": true, "yaml": true, "yml": true, "toml": true, "xml": true, "txt": true, "csv": true, "tsv": true,
	"log": true, "html": true, "htm": true, "css": true, "scss": true, "less": true, "js": true, "mjs": true,
	"cjs": true, "jsx": true, "ts": true, "tsx": true, "doc": true, "docx": true, "xls": true, "xlsx": true,
	"ppt": true, "pptx": true, "gz": true, "tgz": true, "tar": true, "rar": true, "7z": true, "dmg": true,
}

var scaleExt = map[string]bool{"zip": true, "mov": true, "md": true, "map": true}

var scaleRe = lazyre.New(`^[0-9]+(?:\.[0-9]+)?x$`)

func fileHost(host string) bool {
	dot := strings.LastIndexByte(host, '.')
	ext := host[dot+1:]
	return fileExt[ext] || dot > 0 && scaleExt[ext] && scaleRe.MatchString(host[:dot])
}

func fileStem(host string) string {
	for {
		dot := strings.LastIndexByte(host, '.')
		if dot < 0 || !fileExt[host[dot+1:]] {
			return host
		}
		host = host[:dot]
	}
}

func chineseID(v string) bool {
	w := []int{7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2}
	sum := 0
	for i := 0; i < 17; i++ {
		sum += int(v[i]-'0') * w[i]
	}
	return strings.ToUpper(v[17:]) == string("10X98765432"[sum%11])
}

func luhn(v string) bool {
	var ds []int
	for _, r := range v {
		if r >= '0' && r <= '9' {
			ds = append(ds, int(r-'0'))
		}
	}
	if len(ds) < 15 || len(ds) > 19 {
		return false
	}
	sum := 0
	for i := range ds {
		d := ds[len(ds)-1-i]
		if i%2 == 1 {
			if d *= 2; d > 9 {
				d -= 9
			}
		}
		sum += d
	}
	return sum%10 == 0
}

var (
	mu     sync.RWMutex
	values = map[string]string{}
	kinds  = map[string]bool{}

	used    = map[string]uint64{}
	clock   uint64
	keyOf   []byte
	keyPath string
)

const maxValues = 200_000

func key() []byte {
	mu.RLock()
	k := keyOf
	mu.RUnlock()
	if k != nil {
		return k
	}
	mu.Lock()
	defer mu.Unlock()
	if keyOf != nil {
		return keyOf
	}
	keyOf = loadKey()
	return keyOf
}

func loadKey() []byte {
	if keyPath != "" {
		if b, err := os.ReadFile(keyPath); err == nil && len(b) >= 32 {
			return b[:32]
		}
	}
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	if keyPath != "" {
		_ = os.MkdirAll(filepath.Dir(keyPath), 0o700)
		_ = os.WriteFile(keyPath, b, 0o600)
	}
	return b
}

var b32 = base32.StdEncoding.WithPadding(base32.NoPadding)

func tag(kind, v string) string {
	h := hmac.New(sha256.New, key())
	h.Write([]byte(kind + "\x00" + v))
	return "{{" + kind + "_" + strings.ToLower(b32.EncodeToString(h.Sum(nil))[:8]) + "}}"
}

func placeholder(kind, v string) string {
	p := tag(kind, v)
	mu.Lock()
	if _, ok := values[p]; !ok {
		makeRoom()
		values[p] = v
		kinds[kind] = true
		addKnown(p, v)
	}
	touch(p)
	mu.Unlock()
	return p
}

func touch(p string) {
	clock++
	used[p] = clock
}

func makeRoom() {
	if len(values) < maxValues {
		return
	}
	ps := make([]string, 0, len(values))
	for p := range values {
		ps = append(ps, p)
	}
	sort.Slice(ps, func(i, j int) bool { return used[ps[i]] < used[ps[j]] })
	for _, p := range ps[:len(ps)/2] {
		delete(values, p)
		delete(shapes, p)
		delete(used, p)
	}
	reindexKnown()
}

func (o Options) put() func(kind, v string) string {
	if o.Shape {
		return standIn(shaped)
	}
	return standIn(placeholder)
}

type span struct {
	start, end int
	kind       string
	by         string
	score      float64

	bare bool
}

const (
	ByRule  = "rule"
	ByYours = "yours"
	ByWord  = "word"
	ByModel = "model"
	ByKnown = "known"
)

const (
	Warn  = "warn"
	Block = "block"
)

type Hit struct {
	Kind, By, Placeholder, Action string
	Head                          string
	Len                           int
}

func Hint(kind, v string) (head string, n int) {
	n = utf8.RuneCountInString(v)
	if n < 2 {
		return "", n
	}
	k := 1
	if _, personal := kindCats[kind]; !personal && kind != "TERM" && n >= 16 {

		k = 0
		for _, c := range v {
			if k >= 4 || !strings.ContainsRune("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_", c) {
				break
			}
			k++
			if c == '-' || c == '_' {
				break
			}
		}
		k = max(k, 1)
	}
	r := []rune(v)
	return string(r[:k]), n
}

var anyCases sync.Map

func anyCase(w string) *regexp.Regexp {
	if re, ok := anyCases.Load(w); ok {
		return re.(*regexp.Regexp)
	}
	re := regexp.MustCompile(`(?i)` + regexp.QuoteMeta(w))
	anyCases.Store(w, re)
	return re
}

func wordRune(r rune) bool {
	if r == '_' {
		return true
	}
	if !unicode.IsLetter(r) && !unicode.IsDigit(r) {
		return false
	}
	return !unicode.In(r, unicode.Han, unicode.Hiragana, unicode.Katakana)
}

func wholeWord(s string, a, b int) bool {
	first, _ := utf8.DecodeRuneInString(s[a:b])
	last, _ := utf8.DecodeLastRuneInString(s[a:b])
	if wordRune(first) && a > 0 {
		r, n := utf8.DecodeLastRuneInString(s[:a])
		if wordRune(r) {
			return false
		}
		if unicode.IsDigit(first) && r == '.' {
			if p, _ := utf8.DecodeLastRuneInString(s[:a-n]); unicode.IsDigit(p) {
				return false
			}
		}
	}
	if wordRune(last) && b < len(s) {
		r, n := utf8.DecodeRuneInString(s[b:])
		if wordRune(r) {
			return false
		}
		if unicode.IsDigit(last) && r == '.' {
			if f, _ := utf8.DecodeRuneInString(s[b+n:]); unicode.IsDigit(f) {
				return false
			}
		}
	}
	return true
}

func mask(raw string, o Options, put func(kind, v string) string, escaped bool) (string, int) {
	if len(raw) < 3 {
		return raw, 0
	}
	s := raw
	if escaped {
		s = unescapedView(raw)
		put = unescapedPut(put)
	}
	var found []span
	for _, w := range o.Words {
		if w = strings.TrimSpace(w); len(w) < 2 {
			continue
		}

		if spans, ok := dateSpans(s, w); ok {
			found = append(found, spans...)
			continue
		}

		next := func(i int) (int, int) {
			if o.WordsAnyCase {
				if m := anyCase(w).FindStringIndex(s[i:]); m != nil {
					return i + m[0], i + m[1]
				}
				return -1, -1
			}
			if j := strings.Index(s[i:], w); j >= 0 {
				return i + j, i + j + len(w)
			}
			return -1, -1
		}
		for i := 0; i <= len(s); {
			a, b := next(i)
			if a < 0 {
				break
			}
			if o.WordsWhole && !wholeWord(s, a, b) {
				_, n := utf8.DecodeRuneInString(s[a:])
				i = a + max(n, 1)
				continue
			}
			found = append(found, span{a, b, "TERM", ByWord, 0, false})
			i = max(b, a+1)
		}
	}
	found = append(found, ruleSpans(s, o)...)

	if o.sent {

		now := modelSpans(raw, o)
		kept := sentSpans(sentModel, raw, o, func() []span { return now })
		learnLate(raw, now, kept, o, escaped)
		found = append(found, kept...)
		found = append(found, sentSpans(sentKnown, s, o, func() []span { return knownSpans(s, o) })...)
	} else {
		found = append(found, modelSpans(raw, o)...)
		found = append(found, knownSpans(s, o)...)
	}
	if escaped {
		found = inStrings(raw, outsideEscapes(raw, found))
	}
	found = noNumbers(s, noIDs(s, found))
	if o.sent {
		noteScores(raw, found)
	}
	return apply(raw, found, put, o)
}

func ruleSpans(s string, o Options) []span {
	return memoRules(s, o, func() []span {
		if len(s) >= ruleMemoMin {
			ruleRuns.Add(1)
		}
		var found []span
		all := rules
		if o.Secrets && len(o.Rules) > 0 {

			all = append(customRules(o.Rules), rules...)
		}
		lower := ""

		var split []span
		for _, r := range all {
			if !o.covers(r.cat) {
				continue
			}
			if len(r.markers) > 0 && !containsAny(s, r.markers) {
				continue
			}
			if r.may != nil && !r.may(s) {
				continue
			}
			if len(r.fold) > 0 {
				if lower == "" {
					lower = lowerASCII(s)
				}
				if !containsAny(lower, r.fold) {
					continue
				}
			}
			for _, m := range r.matches(s, lower) {
				if len(r.groups) > 0 {
					took := false
					for g, kind := range r.groups {
						if a, b := m[2*g+2], m[2*g+3]; a >= 0 && r.takes(s, a, b, r.groupOK[g]) {
							found = append(found, span{a, b, kind, r.by(), 0, false})
							took = true
						}
					}
					if took {
						split = append(split, span{m[2], m[1], "", "", 0, false})
					}
					continue
				}
				a, b := m[0], m[1]
				for g := 1; 2*g+1 < len(m); g++ {
					if m[2*g] >= 0 {
						a, b = m[2*g], m[2*g+1]
						break
					}
					if !r.anyGroup {
						break
					}
				}
				ok := r.ok
				if r.fix != nil {
					var good bool
					if a, b, good = r.fix(s, a, b); !good {
						continue
					}
					ok = nil
				}
				if r.takes(s, a, b, ok) {
					found = append(found, span{a, b, r.kind, r.by(), 0, false})
				}
			}
		}
		for _, sp := range split {
			found = slices.DeleteFunc(found, func(f span) bool {
				return f.kind == "EMAIL" && f.start == sp.start && f.end <= sp.end
			})
		}
		return found
	})
}

func learnLate(raw string, now, kept []span, o Options, escaped bool) {
	var late []span
	for _, f := range now {
		if !slices.ContainsFunc(kept, func(k span) bool { return k.start == f.start && k.end == f.end && k.kind == f.kind }) {
			late = append(late, f)
		}
	}
	if len(late) == 0 {
		return
	}
	if escaped {
		late = outsideEscapes(raw, late)
	}
	noteScores(raw, late)
	o.Seen = nil
	put := o.put()
	if escaped {
		put = unescapedPut(put)
	}
	apply(raw, late, put, o)
}

func unescapedView(s string) string {
	if strings.IndexByte(s, '\\') < 0 {
		return s
	}
	b := []byte(s)
	for i := 0; i+1 < len(b); i++ {
		if b[i] != '\\' {
			continue
		}
		i++
		switch b[i] {
		case 'n', 'b', 'f':
			b[i] = '\n'
		case 'r':
			b[i] = '\r'
		case 't':
			b[i] = '\t'
		case 'u':
			for j := i; j < i+5 && j < len(b); j++ {
				b[j] = '\n'
			}
			i += 4
		}
	}
	return string(b)
}

func unescapedPut(put func(kind, v string) string) func(kind, v string) string {
	return func(kind, v string) string {
		if strings.IndexByte(v, '\\') >= 0 {
			var u string
			if json.Unmarshal([]byte(`"`+v+`"`), &u) == nil {
				v = u
			}
		}
		return put(kind, v)
	}
}

func outsideEscapes(s string, found []span) []span {
	if len(found) == 0 || strings.IndexByte(s, '\\') < 0 {
		return found
	}

	type edges struct{ from, to int }
	esc := make([]edges, len(s)+1)
	for i := 0; i < len(s); i++ {
		if s[i] != '\\' {
			continue
		}
		n := 2
		if i+1 < len(s) && s[i+1] == 'u' {
			n = 6
		}
		end := min(i+n, len(s))
		for j := i + 1; j < end; j++ {
			esc[j] = edges{i + 1, end + 1}
		}
		i = end - 1
	}
	out := found[:0]
	for _, f := range found {
		if e := esc[f.start]; e.to > 0 {
			f.start = e.to - 1
		}
		if e := esc[f.end]; e.from > 0 {
			f.end = e.from - 1
		}
		if f.start < f.end {
			out = append(out, f)
		}
	}
	return out
}

func inStrings(s string, found []span) []span {
	if len(found) == 0 || !json.Valid([]byte(s)) {
		return found
	}

	in := make([]int32, len(s))
	n := int32(0)
	for i := 0; i < len(s); i++ {
		if s[i] != '"' {
			continue
		}
		n++
		j := i + 1
		for ; j < len(s) && s[j] != '"'; j++ {
			in[j] = n
			if s[j] == '\\' && j+1 < len(s) {
				j++
				in[j] = n
			}
		}
		i = j
	}
	out := found[:0]
	for _, f := range found {
		a := f.start
		for a < f.end && in[a] == 0 {
			a++
		}
		if a == f.end {
			if bareValue(s, f.start, f.end) {
				f.bare = true
				out = append(out, f)
			}
			continue
		}
		b := a
		for b < f.end && in[b] == in[a] {
			b++
		}
		f.start, f.end = a, b
		out = append(out, f)
	}
	return out
}

func bareValue(s string, a, b int) bool {
	if a >= b || strings.ContainsAny(s[a:b], " \t\r\n{}[]\",:") {
		return false
	}
	i := a - 1
	for i >= 0 && isSpace(s[i]) {
		i--
	}
	k := b
	for k < len(s) && isSpace(s[k]) {
		k++
	}
	return i >= 0 && strings.IndexByte(":[,", s[i]) >= 0 && (k == len(s) || strings.IndexByte(",}]", s[k]) >= 0)
}

func noNumbers(s string, found []span) []span {
	return slices.DeleteFunc(found, func(f span) bool {
		_, personal := kindCats[f.kind]
		return personal && f.by != ByWord && f.by != ByYours && (inDecimal(s, f.start, f.end) || jsonNumber(s, f.start, f.end))
	})
}

func jsonNumber(s string, a, b int) bool {
	if a >= b || strings.Trim(s[a:b], digits) != "" {
		return false
	}
	space := func(c byte) bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' }
	k := b
	for k < len(s) && space(s[k]) {
		k++
	}
	if k < len(s) && strings.IndexByte(",}]", s[k]) < 0 {
		return false
	}
	i := a - 1
	for i >= 0 && space(s[i]) {
		i--
	}
	if i < 0 {
		return false
	}
	switch s[i] {
	case ':':
		for i--; i >= 0 && space(s[i]); i-- {
		}
		return i >= 0 && s[i] == '"'
	case '[', ',':

		for ; i >= 0; i-- {
			if s[i] == '[' {
				return true
			}
			if strings.IndexByte(digits+",.-+eE", s[i]) < 0 && !space(s[i]) {
				return false
			}
		}
	}
	return false
}

func inDecimal(s string, a, b int) bool {
	isDigit := func(i int) bool { return i >= 0 && i < len(s) && s[i] >= '0' && s[i] <= '9' }
	return isDigit(a) && a >= 2 && s[a-1] == '.' && isDigit(a-2) ||
		isDigit(b-1) && b+1 < len(s) && s[b] == '.' && isDigit(b+1)
}

func (r rule) by() string {
	if r.yours {
		return ByYours
	}
	return ByRule
}

func (r rule) matches(s, lower string) [][]int {
	if r.ahead == 0 {
		return r.findAll(s)
	}
	var wins [][2]int
	for _, f := range r.fold {
		for i := 0; ; {
			j := strings.Index(lower[i:], f)
			if j < 0 {
				break
			}
			at := i + j
			i = at + len(f)

			start := max(0, at-r.back)
			if nl := strings.LastIndexByte(s[start:at], '\n'); nl >= 0 {
				start += nl + 1
			} else if start > 0 {
				for start < at && (strings.IndexByte(alnum+"_.-", s[start-1]) >= 0 || s[start]&0xc0 == 0x80) {
					start++
				}
				if start == at && strings.IndexByte(alnum+"_", s[at-1]) >= 0 {
					continue
				}
			}
			wins = append(wins, [2]int{start, min(len(s), i+r.ahead)})
		}
	}
	sort.Slice(wins, func(i, j int) bool { return wins[i][0] < wins[j][0] })
	var out [][]int
	for k := 0; k < len(wins); k++ {
		w := wins[k]
		for k+1 < len(wins) && wins[k+1][0] <= w[1] {
			k++
			w[1] = max(w[1], wins[k][1])
		}
		for _, m := range r.findAll(s[w[0]:w[1]]) {
			for x := range m {
				if m[x] >= 0 {
					m[x] += w[0]
				}
			}
			out = append(out, m)
		}
	}
	return out
}

func (r rule) findAll(s string) [][]int {
	if r.field {
		return fieldMatches(r.re.Regexp(), s)
	}
	return r.re.FindAllStringSubmatchIndex(s, -1)
}

func lowerASCII(s string) string {
	i := 0
	for i < len(s) && !('A' <= s[i] && s[i] <= 'Z') {
		i++
	}
	if i == len(s) {
		return s
	}
	b := []byte(s)
	for ; i < len(b); i++ {
		if c := b[i]; 'A' <= c && c <= 'Z' {
			b[i] = c + 'a' - 'A'
		}
	}
	return string(b)
}

func (r rule) takes(s string, a, b int, ok func(string) bool) bool {
	if b <= a {
		return false
	}
	if r.bound != "" && (a > 0 && strings.IndexByte(r.bound, s[a-1]) >= 0 || b < len(s) && strings.IndexByte(r.bound, s[b]) >= 0) {
		return false
	}
	if ok != nil && !ok(s[a:b]) {
		return false
	}
	return r.at == nil || r.at(s, a, b)
}

func apply(s string, found []span, put func(kind, v string) string, o Options) (string, int) {
	if len(found) == 0 {
		return s, 0
	}

	found = outsideShapes(s, found)
	if strings.Contains(s, "{{") {
		for _, p := range placeholderRe.FindAllStringIndex(s, -1) {
			found = slices.DeleteFunc(found, func(f span) bool { return f.start < p[1] && f.end > p[0] })
		}
		if len(found) == 0 {
			return s, 0
		}
	}

	sort.SliceStable(found, func(i, j int) bool {
		if found[i].start != found[j].start {
			return found[i].start < found[j].start
		}
		return found[i].end > found[j].end
	})
	var b strings.Builder
	last, next, n := 0, 0, 0
	kept := 0

	remember := o.sent && o.Route != ""
	var text uint64
	textOf := func() uint64 {
		if text == 0 {
			text = keptText(o.Route, s) | 1
		}
		return text
	}
	for _, f := range found {
		if f.start < next || f.start < kept && f.by != ByWord {
			continue
		}
		v := s[f.start:f.end]
		if f.by != ByWord && o.allows(v) && (!remember || !maskedBefore(textOf(), v)) {
			kept = max(kept, f.end)
			continue
		}
		next = f.end
		act := o.Actions[f.kind]
		if act != Warn && act != Block {
			act = ""
		}
		h := Hit{Kind: f.kind, By: f.by, Action: act}
		h.Head, h.Len = Hint(f.kind, v)
		if act == Warn {
			if o.Seen != nil {
				h.Placeholder = tag(f.kind, v)
				o.Seen(h)
			}
			continue
		}
		b.WriteString(s[last:f.start])
		h.Placeholder = put(f.kind, v)
		if f.bare {
			b.WriteString(`"` + h.Placeholder + `"`)
		} else {
			b.WriteString(h.Placeholder)
		}
		if remember {
			keepMasked(textOf(), v)
		}
		if o.Seen != nil {
			o.Seen(h)
		}
		last, n = f.end, n+1
	}
	b.WriteString(s[last:])
	return b.String(), n
}

func (o Options) allows(v string) bool {
	for _, a := range o.Allow {
		if strings.EqualFold(strings.TrimSpace(a), v) {
			return true
		}
	}
	return false
}

func containsAny(s string, subs []string) bool {
	for _, x := range subs {
		if strings.Contains(s, x) {
			return true
		}
	}
	return false
}
