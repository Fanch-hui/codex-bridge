package redact

import (
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"

	"codexbridge/modelprotocol/internal/lazyre"
)

type Found struct {
	Start, End int
	Label      string
	Score      float64 `json:"score,omitempty"`
}

type Model func(texts []string) [][]Found

var modelKinds = map[string]string{
	"private_person":  "PERSON",
	"private_address": "ADDRESS",
	"private_phone":   "PHONE",
	"private_email":   "EMAIL",
	"account_number":  "ACCOUNT",
	"secret":          "SECRET",
}

func modelCat(kind string) string {
	if kind == "SECRET" {
		return ""
	}
	return catPersonal
}

func modelSpans(s string, o Options) []span {
	if o.Model == nil || !o.covers(catPersonal) && len(o.found[s]) == 0 {
		return nil
	}
	var out []span
	for _, f := range o.found[s] {
		kind := modelKinds[f.Label]
		if kind == "" || !o.covers(modelCat(kind)) || f.Start < 0 || f.End > len(s) || f.Start >= f.End {
			continue
		}
		a, b := f.Start, f.End
		if kind == "SECRET" {

			if k := strings.LastIndex(s[a:b], `":"`); k >= 0 {
				a += k + 3
			}
		}
		edge := isSpace
		if kind != "SECRET" {
			edge = delimiter
		}
		for a < b && edge(s[a]) {
			a++
		}
		for b > a && edge(s[b-1]) {
			b--
		}
		if kind == "PERSON" {
			a, b = zhTrim(s, a, b)
		}
		if a < b && utf8.ValidString(s[a:b]) && modelTakes(kind, s[a:b]) && modelFits(s, a, b, kind, o.args) && !(kind == "PERSON" && zhWordNotName(s, a, b)) {
			out = append(out, span{a, b, kind, ByModel, f.Score, false})
		}
	}
	if o.covers(catPersonal) {
		var person []span
		for _, f := range out {
			if f.kind == "PERSON" {
				person = append(person, f)
			}
		}
		out = append(out, zhNameSpans(s, person, o.NamesByModel)...)
	}
	return out
}

func isSpace(c byte) bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' }

func delimiter(c byte) bool { return isSpace(c) || strings.IndexByte(`"',;:`, c) >= 0 }

func modelTakes(kind, v string) bool {
	if hexLiteral.MatchString(v) {
		return false
	}
	switch kind {
	case "SECRET":
		return len(v) >= 8 && !madeID(v) && !namesThing(v) && !versionValue(v)
	case "PERSON":

		return utf8.RuneCountInString(v) >= 2 && strings.IndexFunc(v, unicode.IsLetter) >= 0 && !snakeWord(v)
	case "ACCOUNT":
		return !madeID(v)
	case "EMAIL":

		return strings.Contains(v, "@") && realEmail(v)
	}
	return true
}

func snakeWord(v string) bool {
	if !strings.Contains(v, "_") || strings.Trim(v, "_") == "" {
		return false
	}
	for _, c := range v {
		if !(c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {
			return false
		}
	}
	return true
}

func namesThing(v string) bool {
	if u, n, ok := strings.Cut(v, ":"); ok && n != "" && strings.Trim(n, digits) == "" {
		v = u
	}
	if uuidRe.MatchString(v) || digestRe.MatchString(v) || sriRe.MatchString(v) || slugRe.MatchString(v) || fileNameRe.MatchString(v) || modelName(v) {
		return true
	}
	return !strings.ContainsAny(v, " \t\n") && (strings.HasPrefix(v, "/") || strings.HasPrefix(v, "~/") ||
		strings.HasPrefix(v, "./") || strings.HasPrefix(v, "../") || len(v) > 3 && v[1] == ':' && v[2] == '\\')
}

func modelName(v string) bool {
	if !dashedRe.MatchString(v) {
		return false
	}
	if dateIn.MatchString(v) {
		return true
	}
	for _, p := range strings.Split(v, "-") {
		if sizePartRe.MatchString(p) {
			return true
		}
	}
	return false
}

var (
	dashedRe   = lazyre.New(`^[a-z][a-z0-9.]*(?:-[a-z0-9.]+)+$`)
	sizePartRe = lazyre.New(`^(?:\d+x)?\d+(?:\.\d+)?[bkm]$|^20\d{6}$`)
	dateIn     = lazyre.New(`(?:^|-)20\d\d-[01]\d-[0-3]\d(?:-|$)`)
)

var (
	uuidRe = lazyre.New(`^(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

	slugRe = lazyre.New(`^[a-z0-9][a-z0-9._@-]*(?:/[a-z0-9._@-]+)+$`)

	fileNameRe = lazyre.New(`^[a-z0-9][a-z0-9_-]*(?:\.[a-z0-9_-]+)*\.[a-z][a-z0-9]{0,4}$`)
	digestRe   = lazyre.New(`^(?i)(?:md5|sha-?(?:1|224|256|384|512)|blake2b?|blake3)[ :=-]+[0-9a-f]{32,128}$`)

	sriRe = lazyre.New(`^sha(?:256|384|512)-[A-Za-z0-9+/]{43,86}={0,2}[}"',;)\]]*$`)
)

func madeID(v string) bool {
	p, rest, ok := strings.Cut(v, "_")
	if !ok || len(p) < 2 || len(p) > 8 || len(rest) < 8 {
		return false
	}
	for _, c := range p {
		if c < 'a' || c > 'z' {
			return false
		}
	}
	plain := true
	for _, c := range rest {
		if c == '_' || c == '-' {
			plain = false
		} else if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {
			return false
		}
	}
	return plain || !keyHeads[p]
}

var keyHeads = map[string]bool{"sk": true, "rk": true, "pk": true, "whsec": true, "shpat": true, "shpss": true, "xoxb": true, "xoxp": true}

func modelFits(s string, a, b int, kind string, args bool) bool {
	if a > 0 && wordByte(s[a-1]) && wordByte(s[a]) || b < len(s) && wordByte(s[b-1]) && wordByte(s[b]) {
		return false
	}
	v := s[a:b]
	if publicID(s, a, b) {
		return false
	}
	if evmRe.MatchString(v) {

		return kind == "SECRET" && secretCued(s, a)
	}
	if packageAt(s, a, b) {
		return false
	}
	switch kind {
	case "PERSON":
		return personFits(s, a, b, v, args)
	case "ACCOUNT":
		if hexRe.MatchString(v) && strings.ContainsAny(v, "abcdef") || versionRe.MatchString(v) || !numberLike(v) {
			return false
		}
		return strings.Trim(v, digits) != "" || cued(s, a, accountCues)
	case "PHONE":
		if !numberLike(v) || countDigits(v) < 7 || epochNumber(v) || decimalRe.MatchString(v) || unicode.IsLetter(rune(v[0])) {
			return false
		}
		return strings.Trim(v, digits) != "" || v[0] == '0' || cued(s, a, phoneCues)
	case "ADDRESS":

		if isASCII(v) && !strings.ContainsAny(v, " \t\n") && strings.ContainsAny(v, `/\`) || programWords(v) {
			return false
		}
		return strings.IndexFunc(v, unicode.IsLetter) >= 0
	case "SECRET":

		if b < len(s) && s[b] == '(' && identPath.MatchString(v) {
			return false
		}
		if !wordByte(v[0]) || patternWords(v) || regexpLike(v) || idAfter(s, a) || strings.ContainsRune(v, ' ') && clockIn.MatchString(v) || uuidIn.MatchString(v) || strings.Contains(v, `": `) || strings.Contains(v, `", "`) || linkRe.MatchString(v) {
			return false
		}

		if a > 1 && (s[a-1] == '+' || s[a-1] == '/') && wordByte(s[a-2]) || b+1 < len(s) && (s[b] == '+' || s[b] == '/') && wordByte(s[b+1]) {
			return false
		}

		if f := strings.Fields(v); len(f) > 1 && hexRe.MatchString(f[0]) || modCacheRe.MatchString(v) {
			return false
		}
		if pinnedAfter(s, b) {
			return false
		}
		if strings.Trim(v, digits) == "" {
			return numberNamedSecret(s, a)
		}
		if wordsOnly(v) && !assignedSecret(s, a) {
			return false
		}
		return !hexRe.MatchString(v) || secretCued(s, a)
	case "EMAIL":

		return wordByte(v[0]) && !modCacheRe.MatchString(v) && !inUserinfo(s, a)
	}
	return true
}

func publicID(s string, a, b int) bool {
	v := s[a:b]
	if bvidRe.MatchString(v) {
		return true
	}
	if !youtubeID.MatchString(v) {
		return false
	}
	return youtubeAt.MatchString(s[max(0, a-160):a])
}

func programWords(v string) bool {
	if strings.Contains(v, "_") {
		return true
	}
	return isASCII(v) && strings.IndexFunc(v, unicode.IsLetter) >= 0 && strings.IndexFunc(v, func(r rune) bool { return unicode.IsUpper(r) || unicode.IsDigit(r) }) < 0
}

var wordsOnlyRe = lazyre.New(`^_*[a-z]+(?:[-._][a-z]+)*_*/?$`)

func wordsOnly(v string) bool { return wordsOnlyRe.MatchString(v) }

func assignedSecret(s string, a int) bool {
	before := strings.ToLower(strings.TrimRight(s[max(0, a-64):a], " \t\"'`“「"))
	for _, sep := range []string{"=", ":", "：", " is", " was", "是", "为", "為"} {
		if !strings.HasSuffix(before, sep) {
			continue
		}
		name := strings.TrimRight(before[:len(before)-len(sep)], " \t\"'`:")
		i := len(name)
		for i > 0 && (wordByte(name[i-1]) || name[i-1] == '.' || name[i-1] == '-') {
			i--
		}
		if i == len(name) {

			return slices.ContainsFunc(secretCues, func(c string) bool { return c[0] >= 0x80 && strings.HasSuffix(name, c) })
		}
		return slices.ContainsFunc(secretCues, func(c string) bool { return c[0] < 0x80 && strings.Contains(name[i:], c) }) ||
			strings.Contains(name[i:], "pass") || strings.Contains(name[i:], "pwd") || strings.Contains(name[i:], "credential")
	}
	return false
}

func pinnedAfter(s string, b int) bool {
	rest := s[b:]
	for _, op := range []string{"===", "==", ">=", "<=", "~=", "!="} {
		if strings.HasPrefix(rest, op) {
			rest = strings.TrimLeft(rest[len(op):], " ")
			return rest != "" && rest[0] >= '0' && rest[0] <= '9'
		}
	}
	return false
}

var moduleRe = lazyre.New(`^(?:[a-z]+:)?@?[A-Za-z0-9_.~-]+(?:(?:/|::)[A-Za-z0-9_.~@-]+)*$`)

func moduleAt(s string, a, b int) bool {
	if !moduleRe.MatchString(s[a:b]) {
		return false
	}
	line := strings.LastIndexByte(s[:a], '\n') + 1
	head := codeHead(s[line:a])
	end := strings.IndexByte(s[b:], '\n')
	if end < 0 {
		end = len(s) - b
	}
	tail := strings.TrimLeft(s[b:b+end], " \t")
	if q := strings.TrimRight(head, " \t"); q != "" && strings.ContainsRune("'\"`", rune(q[len(q)-1])) {

		if tail == "" || tail[0] != q[len(q)-1] {
			return false
		}
		q = strings.TrimRight(q[:len(q)-1], " \t")
		if c := strings.TrimSuffix(q, "("); c != q {
			q = strings.TrimRight(c, " \t")
			return wordEnd(q, "require") || wordEnd(q, "import")
		}
		if !wordEnd(q, "from") {

			return q == "import"
		}
		q = strings.TrimRight(strings.TrimSuffix(q, "from"), " \t")
		return strings.HasPrefix(q, "import") || strings.HasPrefix(q, "export") ||
			strings.HasSuffix(q, "}") || strings.HasSuffix(q, "*") || q == ""
	}

	switch strings.TrimRight(head, " \t") {
	case "from":
		return strings.HasPrefix(tail, "import ")
	case "import":
		return tail == "" || tail[0] == ',' || tail[0] == ';' || strings.HasPrefix(tail, "as ")
	case "use", "extern crate":
		return strings.HasPrefix(tail, "::") || tail == "" || tail[0] == ';' || tail[0] == '{'
	}
	return false
}

func codeHead(h string) string {
	h = strings.TrimLeft(h, " \t")
	i := 0
	for i < len(h) && h[i] >= '0' && h[i] <= '9' {
		i++
	}
	if i > 0 {
		for _, sep := range []string{"→", "\t", ":", "|"} {
			if strings.HasPrefix(h[i:], sep) {
				h = strings.TrimLeft(h[i+len(sep):], " \t")
				break
			}
		}
	}
	if h != "" && (h[0] == '+' || h[0] == '-') {
		h = strings.TrimLeft(h[1:], " \t")
	}
	return h
}

func packageAt(s string, a, b int) bool {

	for b+1 < len(s) && s[b] == '/' && moduleByte(s[b+1]) {
		for b++; b < len(s) && moduleByte(s[b]); b++ {
		}
	}
	if a > 2 && s[a-1] == '/' {
		i := a - 1
		for i > 0 && moduleByte(s[i-1]) {
			i--
		}
		if i < a-2 && s[i] == '@' {
			a = i
		}
	}
	if !moduleRe.MatchString(s[a:b]) {
		return false
	}
	return moduleAt(s, a, b) || dependencyAt(s, a, b) || underPackages(s, a) ||
		missingModuleAt(s, a, b) || installedAt(s, a, b) || pinnedAt(s, a, b)
}

func moduleByte(c byte) bool { return wordByte(c) || c == '.' || c == '-' || c == '~' || c == '@' }

func dependencyAt(s string, a, b int) bool {
	rest := ""
	if a > 0 && s[a-1] == '"' && b < len(s) && s[b] == '"' {
		rest = strings.TrimLeft(s[b+1:], " \t")
		if !strings.HasPrefix(rest, ":") {
			return false
		}
		rest = strings.TrimLeft(rest[1:], " \t")
	} else {
		line := strings.LastIndexByte(s[:a], '\n') + 1
		if strings.Trim(s[line:a], " \t") != "" {
			return false
		}
		rest = strings.TrimLeft(s[b:], " \t")
		if !strings.HasPrefix(rest, "=") || strings.HasPrefix(rest, "==") {
			return false
		}
		rest = strings.TrimLeft(rest[1:], " \t")
		if strings.HasPrefix(rest, "{") {

			return strings.HasPrefix(strings.TrimLeft(rest[1:], " \t"), "version")
		}
	}
	if !strings.HasPrefix(rest, `"`) {
		return false
	}
	v, _, ok := strings.Cut(rest[1:], `"`)
	return ok && depVersion(v)
}

func depVersion(v string) bool {
	for _, p := range []string{"workspace:", "catalog:", "npm:", "file:", "link:", "portal:", "git+", "git:", "github:", "http://", "https://"} {
		if strings.HasPrefix(v, p) {
			return true
		}
	}
	switch v {
	case "*", "latest", "next", "beta", "canary", "x":
		return true
	}
	for _, part := range strings.Fields(strings.NewReplacer("||", " ", " - ", " ").Replace(v)) {
		if !depRangeRe.MatchString(part) {
			return false
		}
	}
	return v != ""
}

var depRangeRe = lazyre.New(`^(?:[~^]|[<>]=?|=)?[vV]?\d+(?:\.(?:\d+|[xX*]))*(?:[-+][0-9A-Za-z.-]+)?$`)

func underPackages(s string, a int) bool {
	return strings.HasSuffix(s[:a], "node_modules/") || strings.HasSuffix(s[:a], "node_modules\\") ||
		strings.HasSuffix(s[:a], "site-packages/") || strings.HasSuffix(s[:a], "site-packages\\")
}

func missingModuleAt(s string, a, b int) bool {
	if a == 0 || b >= len(s) || !strings.ContainsRune("'\"`", rune(s[a-1])) || s[b] != s[a-1] {
		return false
	}
	t := strings.TrimRight(s[:a-1], " \t")
	q := strings.ToLower(t[max(0, len(t)-64):])
	for _, w := range []string{"find module", "find package", "module named", "resolve", "resolve import", "resolve module"} {
		if wordEnd(q, w) {
			return true
		}
	}
	return false
}

var installRe = lazyre.New(`(?:^|[\s;&|(` + "`" + `$])(?:npm|pnpm|yarn|bun|npx|pip|pip3|uv|poetry|pipx|cargo|gem|composer|deno|go)(?: +(?:pip|-[\w-]+))* +(?:add|install|i|remove|rm|uninstall|un|get|require|update|upgrade|up)(?: |$)`)

func installedAt(s string, a, b int) bool {
	if b < len(s) && !isSpace(s[b]) && s[b] != ';' && s[b] != '&' && s[b] != '|' && s[b] != ')' {
		return false
	}
	line := strings.LastIndexByte(s[:a], '\n') + 1
	ms := installRe.FindAllStringIndex(s[line:a], -1)
	if len(ms) == 0 {
		return false
	}
	args := strings.Fields(s[line+ms[len(ms)-1][1] : a])
	if a > 0 && !isSpace(s[a-1]) {
		return false
	}
	for _, w := range args {
		if strings.ContainsAny(w, ";&|<>`$") {
			return false
		}
	}
	if n := len(args); n > 0 && strings.HasPrefix(args[n-1], "-") && credFlag(args[n-1]) {
		return false
	}
	return true
}

func credFlag(f string) bool {
	f = strings.ToLower(f)
	for _, w := range []string{"token", "key", "pass", "secret", "auth", "cred"} {
		if strings.Contains(f, w) {
			return true
		}
	}
	return false
}

func pinnedAt(s string, a, b int) bool {
	if b >= len(s) || s[b] != '@' || strings.ToLower(s[a:b]) != s[a:b] {
		return false
	}
	m := pinVersionRe.FindString(s[b+1:])
	return m != "" && !(len(s) > b+1+len(m) && s[b+1+len(m)] == '.')
}

var pinVersionRe = lazyre.New(`^[\^~]?v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]*[0-9A-Za-z])?`)

func wordEnd(s, w string) bool {
	return strings.HasSuffix(s, w) && (len(s) == len(w) || !wordByte(s[len(s)-len(w)-1]))
}

func wordByte(c byte) bool {
	return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
}

func personFits(s string, a, b int, v string, args bool) bool {
	if strings.ContainsAny(v, "0123456789/\\@<>|=_") || strings.IndexFunc(v, unicode.IsUpper) < 0 && isASCII(v) {
		return false
	}

	for i := 0; i+1 < len(v); i++ {
		if v[i] == '.' && (v[i+1] >= 'a' && v[i+1] <= 'z' || v[i+1] >= 'A' && v[i+1] <= 'Z') {
			return false
		}
	}

	if a > 0 && (s[a-1] == '/' || s[a-1] == '\\' || s[a-1] == '.' && a > 1 && (s[a-2] == '/' || s[a-2] == '\\')) || b < len(s) && (s[b] == '/' || s[b] == '\\') {
		return false
	}
	if strings.ContainsRune(v, ':') {
		return false
	}

	if w := strings.Fields(v); len(w) == 1 && (strings.Trim(v, "ABCDEFGHIJKLMNOPQRSTUVWXYZ") == "" || camelProduct(v) || hostIn(s, v)) {
		return false
	}

	if w := strings.Fields(v); len(w) == 1 && isASCII(v) && !args && thingNamed(s, a, b) {
		return false
	}
	for i, w := range strings.Fields(v) {
		if c := w[0]; c >= 'a' && c <= 'z' && (i == 0 || !nameParticles[w]) {
			return false
		}
		if assistantNames[strings.ToLower(w)] {
			return false
		}
	}
	return true
}

func camelProduct(v string) bool {
	lower := 0
	for i := 0; i < len(v); i++ {
		switch c := v[i]; {
		case c >= 'a' && c <= 'z':
			lower++
		case c >= 'A' && c <= 'Z':
			if lower >= 3 {
				return true
			}
			lower = 0
		default:
			lower = 0
		}
	}
	return false
}

func hostIn(s, w string) bool {
	ls, lw := strings.ToLower(s), strings.ToLower(w)
	for i := 0; ; {
		k := strings.Index(ls[i:], lw+".")
		if k < 0 {
			return false
		}
		k += i
		i = k + 1
		if k > 0 && !strings.ContainsRune("/.@ \t\n\"'(`", rune(ls[k-1])) {
			continue
		}
		if m := hostTail.FindString(ls[k+len(lw):]); m != "" {
			return true
		}
	}
}

var hostTail = lazyre.New(`^(?:\.[a-z0-9-]+)*\.[a-z]{2,6}(?:[/:\s"'),\x60]|$)`)

var nameParticles = map[string]bool{
	"van": true, "von": true, "der": true, "den": true, "de": true, "da": true, "del": true, "della": true,
	"di": true, "du": true, "la": true, "le": true, "bin": true, "binti": true, "al": true, "el": true,
	"y": true, "dos": true, "das": true, "do": true, "ter": true, "ten": true, "zu": true,
}

func numberLike(v string) bool {
	if sizeRe.MatchString(v) || strings.Contains(v, "..") {
		return false
	}
	letters := 0
	for _, c := range v {
		switch {
		case c >= '0' && c <= '9', strings.ContainsRune(" -.()+/", c):
		case unicode.IsLetter(c):
			letters++
		default:
			return false
		}
	}
	return letters <= 4 && countDigits(v)*2 > len(v)
}

func epochNumber(v string) bool {
	if len(v) != 10 && len(v) != 13 || v[0] != '1' {
		return false
	}
	return strings.Trim(v, digits) == ""
}

func countDigits(v string) int {
	n := 0
	for i := 0; i < len(v); i++ {
		if v[i] >= '0' && v[i] <= '9' {
			n++
		}
	}
	return n
}

func isASCII(v string) bool {
	for i := 0; i < len(v); i++ {
		if v[i] >= utf8.RuneSelf {
			return false
		}
	}
	return true
}

var assistantNames = map[string]bool{
	"claude": true, "chatgpt": true, "gpt": true, "codex": true, "gemini": true, "copilot": true,
	"grok": true, "kimi": true, "qwen": true, "deepseek": true, "cursor": true, "devin": true,
	"kiro": true, "opencode": true, "opus": true, "sonnet": true, "haiku": true, "fable": true,
	"glm": true, "doubao": true, "magpie": true, "jev": true,
}

var (
	hexRe = lazyre.New(`^[0-9a-f]{7,64}$`)

	evmRe     = lazyre.New(`^0[xX][0-9a-fA-F]{40}$`)
	decimalRe = lazyre.New(`^\d+\.\d+$`)

	hexLiteral = lazyre.New(`^0[xX][0-9a-fA-F]{1,16}$`)

	bvidRe = lazyre.New(`^BV1[1-9A-HJ-NP-Za-km-z]{9}$|^(?i:av)[1-9]\d{0,11}$`)

	youtubeAt = lazyre.New(`(?i)(?:^|[^a-z0-9.-])(?:(?:www|m|music)\.)?(?:(?:youtube|youtube-nocookie)\.com/(?:(?:watch|playlist)\?(?:[^\s"'<>&]*&)*(?:v|list)=|(?:shorts|embed|live|v|channel)/)|youtu\.be/)$`)
	youtubeID = lazyre.New(`^[A-Za-z0-9_-]{10,64}$`)

	clockIn   = lazyre.New(`(?:^|\s)\d{1,2}:\d{2}(?::\d{2})?Z?(?:\s|$)`)
	versionRe = lazyre.New(`^v?\d+(?:\.\d+)+$`)
	sizeRe    = lazyre.New(`^\d+ ?[x×] ?\d+$`)
	uuidIn    = lazyre.New(`(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`)

	modCacheRe = lazyre.New(`^[0-9a-f]{16}@v\d+$`)

	linkRe = lazyre.New(`^(?:[a-z][a-z0-9+.-]*://|[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/)`)
)

var (
	accountCues = []string{"account", "acct", "a/c", "iban", "routing", "sort code", "card", "账号", "帐号", "账户", "帐户", "卡号", "户名"}
	secretCues  = []string{"key", "token", "secret", "password", "passwd", "密钥", "密码", "令牌"}
	phoneCues   = []string{"phone", "tel", "mobile", "cell", "call", "whatsapp", "sms", "电话", "手机", "联系", "致电"}
)

func cued(s string, at int, cues []string) bool {
	before := strings.ToLower(s[max(0, at-40):at])
	for _, c := range cues {
		if strings.Contains(before, c) {
			return true
		}
	}
	return false
}

func regexpLike(v string) bool {
	return strings.Contains(v, `\|`) || strings.Contains(v, `\b`)
}

func idAfter(s string, a int) bool {
	t := strings.TrimRight(s[max(0, a-24):a], " :=#(>\"'`")
	n := len(t)
	if n < 2 || !strings.EqualFold(t[n-2:], "id") {
		return false
	}
	return n == 2 || !unicode.IsLetter(rune(t[n-3])) || t[n-2] == 'I' && t[n-1] == 'd'
}

func secretCued(s string, at int) bool {
	before := strings.ToLower(s[max(0, at-40):at])
	for _, c := range secretCues {
		k := strings.LastIndex(before, c)
		if k < 0 {
			continue
		}
		gap := strings.TrimLeftFunc(before[k+len(c):], func(r rune) bool { return r == '_' || unicode.IsLetter(r) || unicode.IsDigit(r) })
		words := strings.FieldsFunc(gap, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
		if len(words) == 0 || len(words) == 1 && (words[0] == "is" || words[0] == "was" || words[0] == "是" || words[0] == "为") {
			return true
		}
	}
	return false
}

func numberNamedSecret(s string, a int) bool {
	before := strings.ToLower(s[max(0, a-40):a])
	for {
		t := strings.TrimRight(before, " \t\"'`=:：>“「")
		for _, sep := range []string{" is", " was", "是", "为", "為"} {
			t = strings.TrimSuffix(t, sep)
		}
		if t == before {
			break
		}
		before = t
	}
	if before == "" {
		return false
	}
	for _, c := range numberSecretNames {

		if strings.HasSuffix(before, c) && (c != "pin" || len(before) == 3 || !unicode.IsLetter(rune(before[len(before)-4]))) {
			return true
		}
	}
	return false
}

var numberSecretNames = []string{"key", "token", "secret", "password", "passwd", "pass", "pwd", "passcode", "pin", "密钥", "密码", "令牌", "口令"}

func patternWords(v string) bool {
	parts := strings.Split(v, "|")
	if len(parts) < 3 {
		return false
	}
	for _, p := range parts {
		if p == "" || strings.IndexFunc(p, unicode.IsLetter) < 0 || strings.Trim(p, alnum+"_.-") != "" {
			return false
		}
	}
	return true
}
