package redact

import (
	"net/netip"
	"strconv"
	"strings"
	"time"

	"codexbridge/modelprotocol/internal/lazyre"
)

const catPersonal = "personal"

type Category struct {
	ID    string
	Kinds []string
	On    bool
}

var Categories = []Category{
	{ID: "ssn", Kinds: []string{"SSN"}, On: true},
	{ID: "passport", Kinds: []string{"PASSPORT"}, On: true},
	{ID: "iban", Kinds: []string{"IBAN"}, On: true},
	{ID: "birthday", Kinds: []string{"BIRTHDAY"}, On: true},
	{ID: "mac", Kinds: []string{"MAC"}, On: true},
	{ID: "serial", Kinds: []string{"SERIAL"}, On: true},
	{ID: "home", Kinds: []string{"USERNAME"}},
	{ID: "userhost", Kinds: []string{"USERNAME", "HOSTNAME"}},
	{ID: "ip", Kinds: []string{"IP"}},
	{ID: "bucket", Kinds: []string{"BUCKET"}},
}

var categoryOn = func() map[string]bool {
	m := map[string]bool{}
	for _, c := range Categories {
		m[c.ID] = c.On
	}
	return m
}()

const (
	sep = `["']?[ \t]*(?:[:#=：][ \t]*)?`

	months = `(?i:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?`

	pathName = "[^\\s/\\\\:*?\"'<>|,;()\\[\\]{}`$%]{1,64}"

	hostRe = `[A-Za-z0-9][A-Za-z0-9-]{0,62}(?:\.[A-Za-z0-9-]{1,63})*`

	unixUser = `[a-z_][a-z0-9_.-]{0,31}`

	lineUser = `[A-Za-z0-9_][A-Za-z0-9._-]{0,31}`

	bucketRe = `[A-Za-z0-9](?:[A-Za-z0-9._-]{0,61}[A-Za-z0-9])?`
)

var moreRules = []rule{

	{kind: "SSN", cat: "ssn", re: lazyre.New(`\d{3}-\d{2}-\d{4}`), markers: []string{"-"}, bound: alnum + "-", ok: ssnOK},
	{kind: "SSN", cat: "ssn", re: lazyre.New(`(?i:\bssn|\bsocial[ \t]+security(?:[ \t]+(?:number|no\.?|#))?)` + sep + `(?:(?i:is)[ \t]+)?["']?(\d{9}|\d{3} \d{2} \d{4})`),
		fold: []string{"ssn", "social"}, back: 8, ahead: 80, bound: digits, ok: ssnOK},

	{kind: "PASSPORT", cat: "passport", anyGroup: true, bound: alnum, ok: passportOK,
		re: lazyre.New(`(?i:\bpassport(?:[ \t]*(?:no\.?|number|num|#))?|\breisepass(?:nummer)?)` + sep + `(?:(?i:is|was)[ \t]+)?["']?([A-Z0-9]{6,9})` +
			`|(?:护照(?:号码|号)?|護照(?:號碼|号码|番号)?|パスポート(?:番号)?)[ \t]*(?:[:：=][ \t]*)?(?:是[ \t]*|は[ \t]*)?["']?([A-Z0-9]{6,9})`),
		fold: []string{"passport", "reisepass", "护照", "護照", "パスポート"}, back: 8, ahead: 80},

	{kind: "IBAN", cat: "iban", re: lazyre.New(`[A-Z]{2}\d{2}(?:[A-Z0-9]{11,30}|(?: [A-Z0-9]{4}){2,7}(?: [A-Z0-9]{1,3})?)`), bound: alnum, fix: ibanAt},

	{kind: "BIRTHDAY", cat: "birthday", bound: digits, ok: dateOK,
		re: lazyre.New(`(?:(?i:\bdate[ \t]+of[ \t]+birth|\bbirth[ \t_-]?date|\bbirthday|\bdob\b|\bd\.o\.b\.?|\bborn(?:[ \t]+on)?|\bgeburtsdatum|\bgeboren(?:[ \t]+am)?)|生日|出生日期|出生年月日|出生于|出生於|出生|誕生日|生年月日)` +
			sep + `(?:(?i:is|was)[ \t]+|是[ \t]*|为[ \t]*|為[ \t]*|は[ \t]*)?["']?` +
			`(\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{4}[ \t]*年[ \t]*\d{1,2}[ \t]*月[ \t]*\d{1,2}[ \t]*日?|\d{1,2}[-/.]\d{1,2}[-/.]\d{4}` +
			`|` + months + `[ \t]+\d{1,2}(?:st|nd|rd|th)?,?[ \t]+\d{4}|\d{1,2}(?:st|nd|rd|th)?[ \t]+` + months + `,?[ \t]+\d{4})`),
		fold: []string{"birth", "dob", "d.o.b", "born", "geburt", "geboren", "生日", "出生", "誕生日", "生年月日"}, back: 16, ahead: 80},

	{kind: "MAC", cat: "mac", re: lazyre.New(`[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}|[0-9A-Fa-f]{2}(?:-[0-9A-Fa-f]{2}){5}`), bound: alnum + ":-", ok: macOK},

	{kind: "SERIAL", cat: "serial", anyGroup: true, bound: alnum + "-", ok: serialOK,
		re: lazyre.New(`(?i:\bserial[ \t_-]?(?:number|num|no\.?|#)?|\bs/n|\bsn)(?:[ \t]*\([^)\n]{1,20}\))?["']?[ \t]*[:#=：][ \t]*["']?([A-Za-z0-9][A-Za-z0-9-]{4,39})` +
			`|(?:序列号|序列號|シリアル番号|(?i:seriennummer))[ \t]*[:：=]?[ \t]*["']?([A-Za-z0-9][A-Za-z0-9-]{4,39})`),
		fold: []string{"serial", "s/n", "sn", "序列", "シリアル", "seriennummer"}, back: 8, ahead: 80},

	{kind: "USERNAME", cat: "home", fix: homeAt,
		re:   lazyre.New(`(?:^|[^A-Za-z0-9_.~/\\-])(?:file://)?(?:/mnt/[a-z])?/(?:Users|home)/(` + pathName + `)`),
		fold: []string{"/users/", "/home/"}, back: 16, ahead: 80},
	{kind: "USERNAME", cat: "home", anyGroup: true, fix: homeAt,
		re: lazyre.New(`(?:^|[^A-Za-z0-9])[A-Za-z]:(?:\\{1,4}|/)(?i:users|documents and settings)(?:\\{1,4}|/)` +
			`(?:([A-Za-z0-9._-]+(?: [A-Za-z0-9._-]+)+)(?:\\|/)|(` + pathName + `))`),
		fold: []string{"users", "documents and settings"}, back: 12, ahead: 100},

	{cat: "userhost", groups: []string{"USERNAME", "HOSTNAME"}, groupOK: []func(string) bool{userOK, hostOK}, markers: []string{"@"}, at: notPackagePin,
		re: lazyre.New(`(?m)(?:^|[^A-Za-z0-9._%+-])(` + unixUser + `)@(` + hostRe + `)(?::[~/]|:[ \t]*$|[ \t]+[~/]|[ \t]*[$%#>][ \t]|[ \t]*[$%#>]$)`)},
	{cat: "userhost", groups: []string{"USERNAME", "HOSTNAME"}, groupOK: []func(string) bool{userOK, hostOK}, markers: []string{"@"}, at: notPackagePin,
		re: lazyre.New(`(?i:\b(?:ssh|scp|sftp|rsync|mosh|ssh-copy-id))\b[^\n@]{0,80}?[ \t"'](` + unixUser + `)@(` + hostRe + `)`)},

	{kind: "HOSTNAME", cat: "userhost", anyGroup: true, ok: lineHostOK,
		re: lazyre.New(`(?m)^[ \t]*["']?(?:(?i:host[ \t_-]?name|computer[ \t_-]?name|machine[ \t_-]?name|device[ \t_-]?name)|主机名|主機名|計算機名|コンピュータ名|コンピューター名)["']?` +
			`[ \t]*[:=：][ \t]*(?:["'](` + hostRe + `)["'][ \t]*[,;]?|(` + hostRe + `))[ \t]*$|^[ \t]+HostName[ \t]+(` + hostRe + `)[ \t]*$`),
		fold: []string{"name", "主机", "主機", "計算機", "コンピュータ"}},

	{kind: "USERNAME", cat: "userhost", anyGroup: true, ok: lineUserOK, at: notLineIdent,
		re: lazyre.New(`(?m)^[ \t]*["']?(?:(?i:user[ \t_-]?name|login[ \t_-]?name|user|login|logname)|用户名|用戶名|ユーザー名)["']?` +
			`[ \t]*[:=：][ \t]*(?:["'](` + lineUser + `)["'][ \t]*[,;]?|(` + lineUser + `))[ \t]*$|^[ \t]+User[ \t]+(` + lineUser + `)[ \t]*$`),
		fold: []string{"user", "login", "logname", "用户", "用戶", "ユーザー"}},

	{kind: "IP", cat: "ip", markers: []string{"."}, at: ipv4At,
		re: lazyre.New(`(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}`)},
	{kind: "IP", cat: "ip", markers: []string{":"}, bound: alnum + ":_", ok: ipv6OK,
		re: lazyre.New(`[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{0,4}){2,7}`)},

	{cat: "bucket", groups: []string{"BUCKET", "BUCKET"}, groupOK: []func(string) bool{bucketOK, bucketOK}, markers: []string{"://"},
		re: lazyre.New(`(?i:\b(?:s3a?|s3n|gs|oss|cosn?|obs|r2|ks3|bos|tos|az|azure|wasbs?|abfss?)://)(` + bucketRe + `)(?:@([a-z0-9]{3,24})\.(?:blob|dfs)\.core\.windows\.net)?`)},
	{kind: "BUCKET", cat: "bucket", ok: bucketOK, fold: bucketHosts, back: 128, ahead: 32,
		re: lazyre.New(`(?:^|[^A-Za-z0-9.-])([a-z0-9](?:[a-z0-9.-]{0,61}[a-z0-9])?)\.(?:s3(?:[.-](?:dualstack\.)?[a-z0-9-]+)?\.amazonaws\.com(?:\.cn)?|s3-accelerate\.amazonaws\.com` +
			`|storage\.googleapis\.com|oss-[a-z0-9-]+\.aliyuncs\.com|cos\.[a-z0-9-]+\.myqcloud\.com|obs\.[a-z0-9-]+\.myhuaweicloud\.com|r2\.cloudflarestorage\.com` +
			`|(?:blob|dfs)\.core\.windows\.net|[a-z0-9-]+\.digitaloceanspaces\.com|tos-[a-z0-9-]+\.volces\.com)`)},
	{kind: "BUCKET", cat: "bucket", ok: bucketOK, fold: bucketHosts, back: 48, ahead: 80,
		re: lazyre.New(`(?:^|[^A-Za-z0-9.-])(?:s3(?:[.-](?:dualstack\.)?[a-z0-9-]+)?\.amazonaws\.com(?:\.cn)?|storage\.googleapis\.com|storage\.cloud\.google\.com` +
			`|[a-z0-9]{3,24}\.blob\.core\.windows\.net|oss-[a-z0-9-]+\.aliyuncs\.com|[a-z0-9-]+\.digitaloceanspaces\.com)/(` + bucketRe + `)`)},
}

var bucketHosts = []string{"amazonaws.com", "googleapis.com", "cloud.google.com", "aliyuncs.com", "myqcloud.com", "windows.net",
	"cloudflarestorage.com", "digitaloceanspaces.com", "myhuaweicloud.com", "volces.com"}

func ssnOK(v string) bool {
	d := strings.NewReplacer("-", "", " ", "").Replace(v)
	if len(d) != 9 || d[:3] == "000" || d[:3] == "666" || d[0] == '9' || d[3:5] == "00" || d[5:] == "0000" {
		return false
	}

	switch d {
	case "123456789", "078051120", "219099999":
		return false
	}
	return strings.Trim(d, d[:1]) != ""
}

func passportOK(v string) bool {
	n := 0
	for i := 0; i < len(v); i++ {
		if v[i] >= '0' && v[i] <= '9' {
			n++
		}
	}
	return n >= 5 && strings.Trim(v, v[:1]) != ""
}

var ibanLen = map[string]int{
	"AD": 24, "AE": 23, "AL": 28, "AT": 20, "AZ": 28, "BA": 20, "BE": 16, "BG": 22, "BH": 22, "BI": 27, "BR": 29, "BY": 28,
	"CH": 21, "CR": 22, "CY": 28, "CZ": 24, "DE": 22, "DJ": 27, "DK": 18, "DO": 28, "EE": 20, "EG": 29, "ES": 24, "FI": 18,
	"FK": 18, "FO": 18, "FR": 27, "GB": 22, "GE": 22, "GI": 23, "GL": 18, "GR": 27, "GT": 28, "HN": 28, "HR": 21, "HU": 28,
	"IE": 22, "IL": 23, "IQ": 23, "IS": 26, "IT": 27, "JO": 30, "KW": 30, "KZ": 20, "LB": 28, "LC": 32, "LI": 21, "LT": 20,
	"LU": 20, "LV": 21, "LY": 25, "MC": 27, "MD": 24, "ME": 22, "MK": 19, "MN": 20, "MR": 27, "MT": 31, "MU": 30, "NI": 28,
	"NL": 18, "NO": 15, "OM": 23, "PK": 24, "PL": 28, "PS": 29, "PT": 25, "QA": 29, "RO": 24, "RS": 22, "RU": 33, "SA": 24,
	"SC": 31, "SD": 18, "SE": 24, "SI": 19, "SK": 24, "SM": 27, "SO": 23, "ST": 25, "SV": 28, "TL": 23, "TN": 24, "TR": 26,
	"UA": 29, "VA": 22, "VG": 24, "XK": 20, "YE": 30,
}

func ibanOK(v string) bool {
	v = strings.ReplaceAll(v, " ", "")
	if n, ok := ibanLen[v[:2]]; !ok || n != len(v) {
		return false
	}
	r := v[4:] + v[:4]
	m := 0
	for i := 0; i < len(r); i++ {
		c := r[i]
		switch {
		case c >= '0' && c <= '9':
			m = (m*10 + int(c-'0')) % 97
		case c >= 'A' && c <= 'Z':
			m = (m*100 + int(c-'A') + 10) % 97
		default:
			return false
		}
	}
	return m == 1
}

func ibanAt(s string, a, b int) (int, int, bool) {
	for {
		if ibanOK(s[a:b]) {
			return a, b, true
		}
		i := strings.LastIndexByte(s[a:b], ' ')
		if i < 0 {
			return 0, 0, false
		}
		b = a + i
	}
}

var dateNums = lazyre.New(`\d+`)

var dateClock = time.Now

func dateOK(v string) bool {
	ns := dateNums.FindAllString(v, -1)
	num := func(s string) int { n, _ := strconv.Atoi(s); return n }
	yearAgo := dateClock().AddDate(-1, 0, 0)
	valid := func(y, m, d int) bool {
		return y >= 1900 && y <= 2099 && m >= 1 && m <= 12 && d >= 1 && d <= 31 &&
			time.Date(y, time.Month(m), d, 0, 0, 0, 0, time.Local).Before(yearAgo)
	}
	if len(ns) == 2 {
		l := strings.ToLower(v)
		for i, m := range []string{"jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"} {
			if strings.Contains(l, m) {
				d, y := num(ns[0]), num(ns[1])
				if len(ns[0]) == 4 {
					d, y = y, d
				}
				return valid(y, i+1, d)
			}
		}
		return false
	}
	if len(ns) != 3 {
		return false
	}
	if len(ns[0]) == 4 {
		return valid(num(ns[0]), num(ns[1]), num(ns[2]))
	}
	p, q, y := num(ns[0]), num(ns[1]), num(ns[2])
	return valid(y, p, q) || valid(y, q, p)
}

func macOK(v string) bool {
	l := strings.ToLower(strings.ReplaceAll(v, "-", ":"))
	switch l {
	case "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff", "00:11:22:33:44:55", "aa:bb:cc:dd:ee:ff", "01:23:45:67:89:ab", "12:34:56:78:9a:bc", "xx:xx:xx:xx:xx:xx":
		return false
	}
	return strings.ContainsAny(l, "abcdef")
}

func serialOK(v string) bool {
	return len(v) >= 6 && strings.ContainsAny(v, digits) && strings.Trim(v, v[:1]) != ""
}

var notNames = map[string]bool{
	"shared": true, "public": true, "guest": true, "default": true, "default user": true, "all users": true,
	"user": true, "username": true, "user_name": true, "yourname": true, "your-name": true, "your_name": true, "yourusername": true,
	"you": true, "me": true, "name": true, "example": true, "foo": true, "bar": true, "someone": true, "john": true, "jdoe": true,
	"runner": true, "node": true, "vscode": true, "codespace": true, "linuxbrew": true, "...": true,
}

func homeAt(s string, a, b int) (int, int, bool) {
	for b > a && s[b-1] == '.' {
		b--
	}
	if b == a || s[a] == '.' || notNames[strings.ToLower(s[a:b])] {
		return 0, 0, false
	}
	return a, b, true
}

var notUsers = map[string]bool{
	"git": true, "root": true, "ec2-user": true, "ubuntu": true, "admin": true, "postgres": true, "www-data": true, "nobody": true,
	"centos": true, "debian": true, "fedora": true, "azureuser": true, "opc": true, "core": true, "vagrant": true, "docker": true,
	"str": true, "string": true, "int": true, "bool": true, "any": true, "none": true, "null": true, "nil": true, "true": true, "false": true,
	"undefined": true, "hi": true, "hello": true, "hey": true, "yes": true, "no": true, "ok": true, "okay": true, "thanks": true,
	"continue": true, "go": true, "stop": true, "help": true, "test": true, "y": true, "n": true,
}

func userOK(v string) bool {
	l := strings.ToLower(v)
	return len(v) >= 2 && !notUsers[l] && !notNames[l]
}

var codeObjects = map[string]bool{
	"self": true, "this": true, "os": true, "process": true, "request": true, "req": true, "ctx": true, "context": true,
	"config": true, "cfg": true, "conf": true, "settings": true, "env": true, "args": true, "opts": true, "options": true,
	"props": true, "params": true, "session": true, "socket": true, "platform": true, "window": true, "location": true, "url": true,
	"u": true, "r": true, "c": true, "s": true, "m": true, "p": true, "x": true, "data": true, "info": true, "user": true,
}

func inCode(v string) bool {
	first, _, dotted := strings.Cut(strings.ToLower(v), ".")
	if !dotted {
		return false
	}
	last := strings.ToLower(v[strings.LastIndexByte(v, '.')+1:])
	return codeObjects[first] || notUsers[last] || notNames[last] || publicHosts[last] || last == "login" || last == "username"
}

func notPackagePin(s string, a, b int) bool {
	if b < len(s) && s[b] == '@' {

		e := b + 1
		for e < len(s) && strings.IndexByte(alnum+"-.", s[e]) >= 0 {
			e++
		}
		return !versionHost(strings.TrimRight(s[b+1:e], "."))
	}
	return !(a > 0 && s[a-1] == '@' && versionHost(s[a:b]))
}

var versionHostRe = lazyre.New(`^v?\d+(?:\.\d+)+(?:-[0-9A-Za-z.-]+)?$`)

func versionHost(h string) bool {
	if !versionHostRe.MatchString(h) {
		return false
	}
	_, err := netip.ParseAddr(h)
	return err != nil
}

func lineUserOK(v string) bool {
	l := strings.ToLower(v)
	return userOK(v) && !inCode(v) && !chatWords[l] && !identParts[l]
}

var identParts = map[string]bool{
	"user": true, "users": true, "usr": true, "username": true, "name": true, "names": true, "login": true, "logname": true,
	"account": true, "acct": true, "owner": true, "author": true, "member": true, "person": true, "profile": true,
	"current": true, "cur": true, "default": true, "target": true, "new": true, "old": true, "my": true, "the": true,
	"obj": true, "object": true, "info": true, "id": true, "model": true, "data": true, "record": true, "entity": true,
	"row": true, "item": true, "input": true, "arg": true, "args": true, "param": true, "value": true, "val": true,
	"str": true, "type": true, "dto": true, "db": true, "auth": true, "session": true, "self": true,
}

func notLineIdent(s string, a, b int) bool {
	if a > 0 && (s[a-1] == '"' || s[a-1] == '\'') {
		return true
	}
	w := identWords(s[a:b])
	if len(w) < 2 {
		return true
	}
	for _, x := range w {
		if identParts[strings.ToLower(x)] {
			return false
		}
	}
	return true
}

func nameAlone(s string, a, b int) bool {
	identByte := func(c byte) bool { return wordByte(c) || c == '$' }
	if a > 0 && identByte(s[a-1]) || b < len(s) && identByte(s[b]) {
		return false
	}
	if a > 1 && (s[a-1] == '.' || s[a-1] == '-') && identByte(s[a-2]) || b+1 < len(s) && (s[b] == '.' || s[b] == '-') && identByte(s[b+1]) {
		return false
	}
	quoted := a > 0 && b < len(s) && (s[a-1] == '"' || s[a-1] == '\'') && s[b] == s[a-1]
	if quoted {

		rest := strings.TrimLeft(s[b+1:], " \t")
		return !strings.HasPrefix(rest, ":")
	}
	if a > 0 && (s[a-1] == '"' || s[a-1] == '\'' || s[a-1] == '`') {
		return true
	}
	rest := strings.TrimLeft(s[b:], " \t")
	if rest != "" && (rest[0] == '(' || rest[0] == '[' || rest[0] == '=' || strings.HasPrefix(rest, ":=")) {
		return false
	}
	head := strings.TrimRight(s[:a], " \t")
	if len(head) < a {

		for _, kw := range declWords {
			if strings.HasSuffix(head, kw) && (len(head) == len(kw) || !identByte(head[len(head)-len(kw)-1])) {
				return false
			}
		}
	}
	if strings.HasSuffix(head, " =") || strings.HasSuffix(head, "\t=") || strings.HasSuffix(head, ":=") {

		return false
	}
	if head != "" && (head[len(head)-1] == '(' || head[len(head)-1] == ',') && paramRest.MatchString(rest) {

		return head[len(head)-1] == '(' && len(head) > 1 && head[len(head)-2] >= '0' && head[len(head)-2] <= '9'
	}
	return true
}

var paramRest = lazyre.New(`^(?:[,):]|[*\[\]]*[A-Za-z_][\w.*\[\]]*[ \t]*[,)])`)

var declWords = []string{"const", "let", "var", "val", "def", "func", "fn", "function", "class", "struct", "interface", "enum", "return", "import", "typeof"}

func lineHostOK(v string) bool { return hostOK(v) && !inCode(v) }

var chatWords = map[string]bool{
	"done": true, "why": true, "what": true, "how": true, "sure": true, "please": true, "retry": true, "next": true, "again": true,
	"great": true, "good": true, "nice": true, "cool": true, "fix": true, "go-ahead": true, "proceed": true, "lgtm": true,
	"required": true, "optional": true, "unknown": true, "anonymous": true, "guest": true, "current": true, "me": true,
}

var publicHosts = map[string]bool{
	"github.com": true, "gitlab.com": true, "bitbucket.org": true, "ssh.dev.azure.com": true, "vs-ssh.visualstudio.com": true,
	"localhost": true, "host": true, "hostname": true, "server": true, "remote": true, "example": true, "your-server": true,
	"str": true, "string": true, "none": true, "null": true, "true": true, "false": true, "undefined": true,
}

func hostOK(v string) bool {
	l := strings.ToLower(strings.TrimRight(v, "."))
	if len(l) < 2 || publicHosts[l] || strings.HasPrefix(l, "process.") || strings.HasPrefix(l, "os.") || strings.HasPrefix(l, "env.") {
		return false
	}
	if _, err := netip.ParseAddr(l); err == nil {
		return false
	}
	for _, ex := range []string{"example.com", "example.org", "example.net", ".example", ".test", ".invalid", ".localhost"} {
		if l == strings.TrimPrefix(ex, ".") || strings.HasSuffix(l, ex) {
			return false
		}
	}
	return true
}

var notIPs = func() []netip.Prefix {
	var out []netip.Prefix
	for _, p := range []string{"0.0.0.0/8", "100.64.0.0/10", "192.0.0.0/24", "192.0.2.0/24", "198.18.0.0/15", "198.51.100.0/24",
		"203.0.113.0/24", "240.0.0.0/4", "2001:db8::/32", "64:ff9b::/96", "100::/64"} {
		out = append(out, netip.MustParsePrefix(p))
	}
	return out
}()

var resolvers = map[string]bool{
	"8.8.8.8": true, "8.8.4.4": true, "1.1.1.1": true, "1.0.0.1": true, "9.9.9.9": true, "149.112.112.112": true,
	"208.67.222.222": true, "208.67.220.220": true, "114.114.114.114": true, "223.5.5.5": true, "223.6.6.6": true,
	"119.29.29.29": true, "180.76.76.76": true, "2001:4860:4860::8888": true, "2001:4860:4860::8844": true,
	"2606:4700:4700::1111": true, "2606:4700:4700::1001": true,
}

func publicIP(a netip.Addr) bool {
	a = a.Unmap()
	if !a.IsValid() || a.IsPrivate() || a.IsLoopback() || a.IsLinkLocalUnicast() || a.IsMulticast() || a.IsUnspecified() ||
		a.IsLinkLocalMulticast() || a.IsInterfaceLocalMulticast() || resolvers[a.String()] {
		return false
	}
	if a.Is6() && a.As16()[0]&0xe0 != 0x20 {
		return false
	}
	for _, p := range notIPs {
		if p.Contains(a) {
			return false
		}
	}
	return true
}

func ipv4At(s string, a, b int) bool {
	if a > 0 {
		c := s[a-1]
		if strings.IndexByte(alnum+"._-=~^", c) >= 0 {
			return false
		}

		if c == '/' && a >= 2 && strings.IndexByte(alnum+"._-", s[a-2]) >= 0 {
			return false
		}
	}
	if b < len(s) {
		c := s[b]
		if strings.IndexByte(alnum+"_-", c) >= 0 || c == '.' && b+1 < len(s) && s[b+1] >= '0' && s[b+1] <= '9' {
			return false
		}
	}
	before := strings.ToLower(strings.TrimRight(s[max(0, a-16):a], " \t:=\"'"))
	for _, w := range []string{"version", "ver", "release", "build", "rev", "版本"} {

		if strings.HasSuffix(before, w) && (len(before) == len(w) || strings.IndexByte(alnum+"_", before[len(before)-len(w)-1]) < 0) {
			return false
		}
	}
	ip, err := netip.ParseAddr(s[a:b])
	return err == nil && publicIP(ip)
}

func ipv6OK(v string) bool {
	if strings.Count(v, ":") < 2 {
		return false
	}
	ip, err := netip.ParseAddr(v)
	return err == nil && ip.Is6() && publicIP(ip)
}

var notBuckets = map[string]bool{
	"bucket": true, "my-bucket": true, "mybucket": true, "bucket-name": true, "bucketname": true, "my-bucket-name": true,
	"your-bucket": true, "your-bucket-name": true, "yourbucket": true, "example-bucket": true, "examplebucket": true,
	"amzn-s3-demo-bucket": true, "doc-example-bucket": true, "s3": true, "www": true, "storage": true, "container": true,
	"mycontainer": true, "my-container": true, "mystorageaccount": true, "account": true,

	"upload": true, "download": true, "batch": true, "b": true, "v1": true, "v2": true, "api": true,
}

func bucketOK(v string) bool {
	l := strings.ToLower(v)
	return len(l) >= 3 && !notBuckets[l] && strings.Trim(l, digits) != ""
}
