package redact

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

func thingNamed(s string, a, b int) bool {
	if t := strings.TrimLeft(s[b:], "*_`\"'”)"); strings.HasPrefix(t, "'s") || strings.HasPrefix(t, "’s") {

		return false
	}
	cs, ce := clauseAround(s, a, b)
	prev, prev2 := wordsBefore(s[cs:a])
	next := latinAfter(s[b:ce])
	switch {
	case (prev == "like" || prev == "called" || prev == "named") && thingKinds[prev2]:
		return true
	case nameBefore[prev] || nameAfter[next] || endsAny(strings.TrimRight(s[cs:a], " "), zhRoles, true) || startsAny(strings.TrimLeft(s[b:ce], " "), zhTitles):
		return false
	case thingBefore[prev] || (prev == "to" || prev == "from" || prev == "with" || prev == "over") && thingVerbs[prev2] || thingAfter[next] || startsAny(strings.TrimLeft(s[b:ce], " "), zhThingAfter):
		return true
	}
	clause := strings.ToLower(s[cs:a] + " " + s[b:ce])
	if hasWord(clause, personWords) || containsAny(clause, zhPersonWords) {
		return false
	}
	return listOfThings(s, a) || namesOnly(s)
}

func listOfThings(s string, a int) bool {
	ls := strings.LastIndexByte(s[:a], '\n') + 1
	if !listItem(s[ls:a]) {
		return false
	}
	for start := 0; start < len(s); {
		end := strings.IndexByte(s[start:], '\n')
		if end < 0 {
			end = len(s)
		} else {
			end += start
		}
		if start != ls {
			t := strings.TrimLeft(s[start:end], " \t")
			if i := listMarker(t); i > 0 {
				l := strings.ToLower(t[i:])
				if hasWord(l, thingWords) && !hasWord(l, personWords) {
					return true
				}
			}
		}
		start = end + 1
	}
	return false
}

func listItem(before string) bool {
	t := strings.TrimLeft(before, " \t")
	i := listMarker(t)
	return i > 0 && strings.Trim(t[i:], " *_`") == ""
}

func listMarker(t string) int {
	i := 0
	for i < len(t) && t[i] >= '0' && t[i] <= '9' {
		i++
	}
	switch {
	case i > 0 && i < len(t) && (t[i] == '.' || t[i] == ')'):
		i++
	case i == 0 && (strings.HasPrefix(t, "- ") || strings.HasPrefix(t, "* ")):
		i = 1
	case i == 0 && strings.HasPrefix(t, "• "):
		i = len("•")
	default:
		return 0
	}
	if i < len(t) && t[i] == ' ' {
		return i + 1
	}
	return 0
}

func clauseAround(s string, a, b int) (int, int) {
	cs := 0
	for i := a - 1; i >= 0; i-- {
		if c := s[i]; c == '\n' || c == '?' || c == '!' || c == ';' || c == '.' && i+1 < len(s) && s[i+1] == ' ' {
			cs = i + 1
			break
		}
		if r, n := utf8.DecodeLastRuneInString(s[:i+1]); n > 1 && strings.ContainsRune("。！？；", r) {
			cs = i + 1
			break
		}
	}
	ce := len(s)
	for i := b; i < len(s); i++ {
		if c := s[i]; c == '\n' || c == '?' || c == '!' || c == ';' || c == '.' && (i+1 == len(s) || s[i+1] == ' ') {
			ce = i
			break
		}
		if r, n := utf8.DecodeRuneInString(s[i:]); n > 1 && strings.ContainsRune("。！？；", r) {
			ce = i
			break
		}
	}
	return cs, ce
}

func latinWords(s string) []string {
	return strings.FieldsFunc(strings.ToLower(s), func(r rune) bool {
		return r >= utf8.RuneSelf || !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-' || r == '\'')
	})
}

func wordsBefore(before string) (string, string) {
	t := strings.TrimRight(before, " \t*_`\"'“(")
	if t == "" {
		return "", ""
	}
	if r, _ := utf8.DecodeLastRuneInString(t); !(r < utf8.RuneSelf && (unicode.IsLetter(r) || unicode.IsDigit(r))) {
		return "", ""
	}
	ws := latinWords(t)
	for len(ws) > 0 && articles[ws[len(ws)-1]] {
		ws = ws[:len(ws)-1]
	}
	switch len(ws) {
	case 0:
		return "", ""
	case 1:
		return ws[0], ""
	}
	return ws[len(ws)-1], ws[len(ws)-2]
}

func latinAfter(after string) string {
	t := strings.TrimLeft(after, " \t*_`\"'”)")
	if strings.HasPrefix(t, "'s ") || strings.HasPrefix(t, "’s ") {
		return ""
	}
	if t == "" {
		return ""
	}
	if r, _ := utf8.DecodeRuneInString(t); !(r < utf8.RuneSelf && unicode.IsLetter(r)) {
		return ""
	}
	if ws := latinWords(t); len(ws) > 0 {
		return ws[0]
	}
	return ""
}

func hasWord(s string, set map[string]bool) bool {
	for _, w := range latinWords(s) {
		if set[strings.TrimSuffix(w, "'s")] {
			return true
		}
	}
	return false
}

func namesOnly(s string) bool {
	t := s
	for _, c := range []string{"和", "或", "、", "，", "与", "跟"} {
		t = strings.ReplaceAll(t, c, " ")
	}
	n := 0
	for _, w := range strings.FieldsFunc(t, func(r rune) bool {
		return r < utf8.RuneSelf && !unicode.IsLetter(r) && !unicode.IsDigit(r) && r != '\''
	}) {
		if listJoins[strings.ToLower(w)] {
			continue
		}
		r, _ := utf8.DecodeRuneInString(w)
		if !isASCII(w) || !unicode.IsUpper(r) {
			return false
		}
		n++
	}
	return n >= 2 && n <= 20
}

func wordSet(ws ...string) map[string]bool {
	m := make(map[string]bool, len(ws))
	for _, w := range ws {
		m[w] = true
	}
	return m
}

var (
	articles  = wordSet("the", "a", "an")
	listJoins = wordSet("and", "or", "vs", "versus", "nor")

	nameBefore = wordSet("colleague", "coworker", "co-worker", "teammate", "friend", "boss", "manager", "wife", "husband",
		"mom", "mum", "dad", "mother", "father", "son", "daughter", "brother", "sister", "aunt", "uncle", "cousin",
		"grandma", "grandpa", "boyfriend", "girlfriend", "fiance", "fiancee", "teacher", "student", "client", "customer",
		"mr", "mrs", "ms", "miss", "dr", "prof", "dear", "hi", "hello", "hey", "thanks", "thank", "cc", "ask", "tell",
		"told", "asked", "email", "emailed", "call", "called", "text", "texted", "meet", "met", "named", "by")
	nameAfter = wordSet("said", "says", "told", "tells", "asked", "asks", "wrote", "writes", "replied", "thinks", "thought",
		"wants", "wanted", "likes", "liked", "loves", "prefers", "recommends", "recommended", "suggested", "mentioned",
		"emailed", "texted", "called", "messaged", "lives", "works", "worked", "jr", "sr")

	thingBefore = wordSet("use", "uses", "using", "used", "install", "installed", "installing", "uninstall", "download",
		"downloaded", "downloading", "open", "opened", "launch", "launched", "buy", "bought", "try", "tried", "trying",
		"app", "apps", "tool", "tools", "vs", "versus")
	thingVerbs = wordSet("switch", "switched", "switching", "move", "moved", "moving", "migrate", "migrated", "migrating",
		"upgrade", "upgraded", "compare", "compared", "comparing", "import", "imported", "export", "exported")
	thingAfter = wordSet("app", "apps", "application", "beta", "pro", "plus", "premium", "vs", "versus", "supports",
		"syncs", "costs", "lets", "offers", "runs", "crashes", "crashed", "integrates", "exports", "imports")

	thingKinds = wordSet("app", "apps", "application", "applications", "tool", "tools", "software", "editors", "clients",
		"plugin", "plugins", "extension", "extensions", "alternatives", "options")

	personWords = wordSet("he", "she", "him", "her", "his", "hers", "himself", "herself",
		"colleague", "colleagues", "coworker", "teammate", "friend", "boss", "manager", "wife", "husband", "mom", "mum",
		"dad", "mother", "father", "son", "daughter", "brother", "sister", "boyfriend", "girlfriend", "teacher",
		"client", "customer", "mr", "mrs", "ms", "dr", "dear", "hi", "hello", "hey", "thanks", "regards", "cc",
		"said", "says", "told", "tells", "asked", "emailed", "texted", "birthday", "married")

	thingWords = wordSet("app", "apps", "application", "applications", "software", "tool", "tools", "utility", "utilities",
		"plugin", "plugins", "extension", "extensions", "launcher", "widget", "widgets",
		"macos", "ios", "ipados", "android", "mac", "iphone", "ipad", "windows", "linux", "download",
		"install", "installed", "pricing", "subscription", "one-time", "trial", "license",
		"open-source", "features", "alternative", "alternatives", "vs", "versus", "icloud", "reader", "player",
		"browser", "note-taking", "markdown", "rss")

	zhPersonWords = []string{"他", "她", "同事", "朋友", "老板", "先生", "女士", "老师", "说", "告诉"}
	zhThingAfter  = []string{"这个软件", "这个应用", "这个工具", "这款", "应用", "软件", "客户端", "插件"}
)
