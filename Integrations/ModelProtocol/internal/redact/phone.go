package redact

import (
	"strings"
	"unicode/utf8"
)

var phoneWords = []string{"phone", "phones", "mobile", "mobiles", "tel", "telephone", "cell", "cellphone", "contact", "contacts", "whatsapp", "sms", "msisdn", "fax"}

var phoneMarks = []string{"手机", "电话", "電話", "联系", "聯繫", "联络"}

var idWords = []string{"order", "id", "uid", "no", "no.", "#", "number", "ticket", "invoice", "订单", "订单号", "单号", "编号", "流水号", "工单", "工单号", "运单号", "快递单号", "订单编号", "交易号", "序号", "账单号", "id号"}

func phoneAt(s string, a, b int) bool {
	if b-a > 11 {
		return true
	}
	if name, prev, ok := fieldName(s, a); ok {
		return phoneName(name) || prev != "" && phoneName(prev) || strings.EqualFold(name, "number")
	}
	if a > 0 && s[a-1] == '#' {
		return false
	}
	before := strings.ToLower(strings.TrimRight(s[max(0, a-32):a], " \t(\"'“「"))
	for _, c := range []string{"是", "为", "為"} {
		before = strings.TrimRight(strings.TrimSuffix(before, c), " \t")
	}
	for _, w := range idWords {
		if !strings.HasSuffix(before, w) {
			continue
		}

		rest := before[:len(before)-len(w)]
		r, _ := utf8.DecodeLastRuneInString(rest)
		if len(rest) > 0 && w[0] < 0x80 && (r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '_') {
			continue
		}

		if w == "no" || w == "no." || w == "number" {
			rest = strings.TrimRight(rest, " ")
			if phoneName(rest[nameStart(rest, len(rest)):]) {
				return true
			}
		}
		return false
	}
	return true
}

func phoneName(name string) bool {
	for _, w := range nameWords(name) {
		for _, p := range phoneWords {
			if w == p {
				return true
			}
		}
	}
	for _, m := range phoneMarks {
		if strings.Contains(name, m) {
			return true
		}
	}
	return false
}

func fieldName(s string, a int) (name, prev string, ok bool) {
	i := a
	for i > 0 && strings.IndexByte(" \t\"'", s[i-1]) >= 0 {
		i--
	}
	switch {
	case i > 0 && s[i-1] == '>':

		k := strings.LastIndexByte(s[max(0, i-65):i-1], '<')
		if k < 0 {
			return "", "", false
		}
		tag := s[max(0, i-65)+k+1 : i-1]
		if sp := strings.IndexAny(tag, " \t"); sp >= 0 {
			tag = tag[:sp]
		}
		if tag == "" || strings.IndexFunc(tag, func(r rune) bool {
			return !(r < 0x80 && strings.IndexByte(alnum+"_.:-", byte(r)) >= 0)
		}) >= 0 {
			return "", "", false
		}
		return tag, "", true
	case i > 0 && (s[i-1] == ':' || s[i-1] == '='):
		i--
	case i >= len("：") && s[i-len("："):i] == "：":
		i -= len("：")
	default:
		return "", "", false
	}
	for i > 0 && strings.IndexByte(" \t\"'", s[i-1]) >= 0 {
		i--
	}
	j := nameStart(s, i)
	if j == i {
		return "", "", false
	}
	name = s[j:i]
	if n := utf8.RuneCountInString(name); n > 6 && hasCJK(name) {

		name = string([]rune(name)[n-6:])
	}
	if j >= 2 && s[j-1] == ' ' && s[j-2] != ' ' {
		prev = s[nameStart(s, j-1) : j-1]
	}
	return name, prev, true
}

func nameStart(s string, i int) int {
	j := i
	for j > 0 {
		r, n := utf8.DecodeLastRuneInString(s[:j])
		if !(r < 0x80 && strings.IndexByte(alnum+"_.-", byte(r)) >= 0 || r >= 0x4e00 && r <= 0x9fff) {
			break
		}
		j -= n
	}
	return j
}

func hasCJK(s string) bool {
	for _, r := range s {
		if r >= 0x4e00 && r <= 0x9fff {
			return true
		}
	}
	return false
}
