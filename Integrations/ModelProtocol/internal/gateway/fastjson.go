package gateway

import (
	"bytes"

	"encoding"
	"encoding/binary"
	"encoding/json"
	"errors"
	"hash/maphash"
	"reflect"
	"slices"
	"strconv"
	"sync"
	"sync/atomic"
	"unicode"
	"unicode/utf16"
	"unicode/utf8"
	"unsafe"
)

func decodeJSON(data []byte, dst any) error { return decodeJSONIn(data, dst, false) }

func decodeJSONView(data []byte, dst any) error { return decodeJSONIn(data, dst, true) }

func decodeJSONIn(data []byte, dst any, share bool) error {
	v := reflect.ValueOf(dst)
	if v.Kind() != reflect.Pointer || v.IsNil() || !v.Elem().IsZero() {
		return json.Unmarshal(data, dst)
	}
	var members []memberSpan
	if len(data) >= validMemoMin {
		var valid bool
		if valid, members = longBody(data); !valid {
			return json.Unmarshal(data, dst)
		}
	} else if !jsonCheck(data) {
		return json.Unmarshal(data, dst)
	}
	start := skipJSONSpace(data, 0)
	if close := misfit(data[start], v.Type().Elem()); close != 0 {

		return json.Unmarshal(append(data[:start+1:start+1], close), dst)
	}
	if err := fillJSONIn(trimJSON(data), v.Elem(), members, share); err != nil {
		v.Elem().SetZero()
		return json.Unmarshal(data, dst)
	}
	return nil
}

var heldBodies struct {
	sync.Mutex
	list atomic.Pointer[[][]byte]

	facts map[*byte]heldFacts

	long map[*byte]heldLong
}

type heldLong struct {
	n       int
	valid   bool
	members []memberSpan
}

const heldShareMost = 16

func inHeldBody(raw []byte) bool {
	l := heldBodies.list.Load()
	if l == nil || len(raw) == 0 {
		return false
	}
	p := uintptr(unsafe.Pointer(unsafe.SliceData(raw)))
	for _, b := range *l {
		s := uintptr(unsafe.Pointer(unsafe.SliceData(b)))
		if p >= s && p+uintptr(len(raw)) <= s+uintptr(len(b)) {
			return len(raw)*heldShareMost >= len(b)
		}
	}
	return false
}

func misfit(open byte, t reflect.Type) byte {
	for {
		if t == rawMessageType || t.Implements(jsonUnmarshalerType) || t.Implements(textUnmarshalerType) ||
			reflect.PointerTo(t).Implements(jsonUnmarshalerType) || reflect.PointerTo(t).Implements(textUnmarshalerType) {
			return 0
		}
		if t.Kind() != reflect.Pointer {
			break
		}
		t = t.Elem()
	}
	switch k := t.Kind(); {
	case k == reflect.Interface:
	case open == '[' && k != reflect.Slice && k != reflect.Array:
		return ']'
	case open == '{' && k != reflect.Struct && k != reflect.Map:
		return '}'
	}
	return 0
}

var errSlowJSON = errors.New("decoded by encoding/json")

var (
	rawMessageType      = reflect.TypeFor[json.RawMessage]()
	jsonUnmarshalerType = reflect.TypeFor[json.Unmarshaler]()
	textUnmarshalerType = reflect.TypeFor[encoding.TextUnmarshaler]()
	stringType          = reflect.TypeFor[string]()
	fastFieldsByType    sync.Map
	errFastFieldsUnfit  = errors.New("struct not decoded field by field")
	jsonNull            = []byte("null")
	jsonTrue, jsonFalse = []byte("true"), []byte("false")
)

type fastFields struct {
	names []string
	index []int
	err   error
}

func jsonFieldsOf(t reflect.Type) *fastFields {
	if f, ok := fastFieldsByType.Load(t); ok {
		return f.(*fastFields)
	}
	f := &fastFields{}
	for i := range t.NumField() {
		sf := t.Field(i)
		if sf.Anonymous {
			f.err = errFastFieldsUnfit
			break
		}
		if !sf.IsExported() {
			continue
		}
		tag := sf.Tag.Get("json")
		if tag == "-" {
			continue
		}
		name, opts, _ := bytes.Cut([]byte(tag), []byte(","))
		for o := range bytes.SplitSeq(opts, []byte(",")) {
			if string(o) == "string" {
				f.err = errFastFieldsUnfit
			}
		}
		if !validTagName(string(name)) {
			name = []byte(sf.Name)
		}
		if slices.Contains(f.names, string(name)) {
			f.err = errFastFieldsUnfit
		}
		f.names = append(f.names, string(name))
		f.index = append(f.index, i)
	}
	fastFieldsByType.Store(t, f)
	return f
}

func validTagName(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		switch {
		case bytes.ContainsRune([]byte("!#$%&()*+-./:;<=>?@[]^_{|}~ "), c):
		case !unicode.IsLetter(c) && !unicode.IsDigit(c):
			return false
		}
	}
	return true
}

func (f *fastFields) field(key []byte) int {
	for i, n := range f.names {
		if n == string(key) {
			return i
		}
	}
	for i, n := range f.names {
		if bytes.EqualFold([]byte(n), key) {
			return i
		}
	}
	return -1
}

func fillJSON(raw []byte, v reflect.Value, share bool) error { return fillJSONIn(raw, v, nil, share) }

func fillJSONIn(raw []byte, v reflect.Value, members []memberSpan, share bool) error {
	t := v.Type()
	if t == rawMessageType {
		if share || inHeldBody(raw) {

			v.SetBytes(raw[:len(raw):len(raw)])
		} else {
			v.SetBytes(bytes.Clone(raw))
		}
		return nil
	}
	if t.Kind() != reflect.Pointer && (t.Implements(jsonUnmarshalerType) || t.Implements(textUnmarshalerType) ||
		reflect.PointerTo(t).Implements(jsonUnmarshalerType) || reflect.PointerTo(t).Implements(textUnmarshalerType)) {
		return json.Unmarshal(raw, v.Addr().Interface())
	}
	null := bytes.Equal(raw, jsonNull)
	switch t.Kind() {
	case reflect.Pointer:
		if null {
			v.SetZero()
			return nil
		}
		if t.Implements(jsonUnmarshalerType) || t.Implements(textUnmarshalerType) {
			return json.Unmarshal(raw, v.Addr().Interface())
		}
		if v.IsNil() {
			v.Set(reflect.New(t.Elem()))
		}
		return fillJSONIn(raw, v.Elem(), members, share)
	case reflect.String:
		if null {
			return nil
		}
		if raw[0] != '"' {
			return errSlowJSON
		}
		s, ok := unquoteJSON(raw)
		if !ok {
			return errSlowJSON
		}
		v.SetString(s)
		return nil
	case reflect.Bool:
		switch {
		case null:
		case bytes.Equal(raw, jsonTrue):
			v.SetBool(true)
		case bytes.Equal(raw, jsonFalse):
			v.SetBool(false)
		default:
			return errSlowJSON
		}
		return nil
	case reflect.Struct:
		if null {
			return nil
		}
		if raw[0] != '{' {
			return errSlowJSON
		}
		f := jsonFieldsOf(t)
		if f.err != nil {
			return f.err
		}

		var few uint64
		var many []bool
		var err error
		eachMemberIn(raw, members, func(key, val []byte) bool {
			name, ok := keyName(key)
			if !ok {
				err = errSlowJSON
				return false
			}
			i := f.field(name)
			if i < 0 {
				return true
			}
			twice := false
			if len(f.names) <= 64 {
				twice, few = few&(1<<i) != 0, few|1<<i
			} else {
				if many == nil {
					many = make([]bool, len(f.names))
				}
				twice, many[i] = many[i], true
			}
			if twice {
				err = errSlowJSON
				return false
			}
			err = fillJSON(val, v.Field(f.index[i]), share)
			return err == nil
		})
		return err
	case reflect.Slice:
		if t.Elem().Kind() == reflect.Uint8 {
			return errSlowJSON
		}
		if null {
			v.SetZero()
			return nil
		}
		if raw[0] != '[' {
			return errSlowJSON
		}
		var elems [][]byte
		eachElement(raw, func(el []byte) bool {
			elems = append(elems, el)
			return true
		})
		s := reflect.MakeSlice(t, len(elems), len(elems))
		for i, el := range elems {
			if err := fillJSON(el, s.Index(i), share); err != nil {
				return err
			}
		}
		v.Set(s)
		return nil
	case reflect.Map:
		if t.Key() != stringType {
			return errSlowJSON
		}
		if null {
			v.SetZero()
			return nil
		}
		if raw[0] != '{' {
			return errSlowJSON
		}
		if v.IsNil() {
			v.Set(reflect.MakeMap(t))
		}
		var err error
		eachMemberIn(raw, members, func(key, val []byte) bool {
			name, ok := unquoteJSON(key)
			if !ok {
				err = errSlowJSON
				return false
			}
			el := reflect.New(t.Elem()).Elem()
			if err = fillJSON(val, el, share); err != nil {
				return false
			}
			v.SetMapIndex(reflect.ValueOf(name), el)
			return true
		})
		return err
	}

	return json.Unmarshal(raw, v.Addr().Interface())
}

func isJSONSpace(c byte) bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' }

func skipJSONSpace(data []byte, i int) int {
	const spaces = 0x2020202020202020
	for i+8 <= len(data) && binary.LittleEndian.Uint64(data[i:]) == spaces {
		i += 8
	}
	for i < len(data) && isJSONSpace(data[i]) {
		i++
	}
	return i
}

func trimJSON(data []byte) []byte {
	i := skipJSONSpace(data, 0)
	j := len(data)
	for j-8 >= i && binary.LittleEndian.Uint64(data[j-8:]) == 0x2020202020202020 {
		j -= 8
	}
	for j > i && isJSONSpace(data[j-1]) {
		j--
	}
	return data[i:j]
}

func eachMember(obj []byte, f func(key, val []byte) bool) {
	eachMemberAt(obj, func(k0, k1, v0, v1 int) bool { return f(obj[k0:k1], obj[v0:v1:v1]) })
}

func eachMemberIn(obj []byte, members []memberSpan, f func(key, val []byte) bool) {
	if members == nil {
		if h := topSplit.Load(); h != nil && len(obj) >= validMemoMin {
			(*h)(obj)
		}
		eachMember(obj, f)
		return
	}
	for _, m := range members {
		if !f(obj[m.k0:m.k1], obj[m.v0:m.v1:m.v1]) {
			return
		}
	}
}

func eachMemberAt(obj []byte, f func(k0, k1, v0, v1 int) bool) {
	i := skipJSONSpace(obj, 1)
	if obj[i] == '}' {
		return
	}
	for {
		k := i
		i = skipJSONString(obj, i)
		k1 := i
		i = skipJSONSpace(obj, i)
		i = skipJSONSpace(obj, i+1)
		s := i
		i = skipJSONValue(obj, i)
		if !f(k, k1, s, i) {
			return
		}
		i = skipJSONSpace(obj, i)
		if obj[i] != ',' {
			return
		}
		i = skipJSONSpace(obj, i+1)
	}
}

func eachElement(arr []byte, f func(el []byte) bool) {
	i := skipJSONSpace(arr, 1)
	if arr[i] == ']' {
		return
	}
	for {
		s := i
		i = skipJSONValue(arr, i)
		if !f(arr[s:i:i]) {
			return
		}
		i = skipJSONSpace(arr, i)
		if arr[i] != ',' {
			return
		}
		i = skipJSONSpace(arr, i+1)
	}
}

func elementsOf(raw []byte) []json.RawMessage {
	if len(raw) == 0 || raw[0] != '[' {
		return nil
	}
	var out []json.RawMessage
	eachElement(raw, func(el []byte) bool {
		out = append(out, el)
		return true
	})
	return out
}

func inputList(raw json.RawMessage) ([]json.RawMessage, bool) {
	raw = trimJSON(raw)
	switch {
	case len(raw) == 0:
		return nil, false
	case raw[0] == '[':
		return elementsOf(raw), true
	case string(raw) == "null":
		return nil, true
	}
	return nil, false
}

func skipJSONString(data []byte, i int) int {
	i++
	for {
		j := bytes.IndexByte(data[i:], '"')
		if j < 0 {
			return len(data)
		}
		i += j
		n := 0
		for k := i - 1; data[k] == '\\'; k-- {
			n++
		}
		i++
		if n%2 == 0 {
			return i
		}
	}
}

func skipJSONValue(data []byte, i int) int {
	switch data[i] {
	case '"':
		return skipJSONString(data, i)
	case '{', '[':
		depth := 0
		for i < len(data) {
			switch data[i] {
			case '"':
				i = skipJSONString(data, i)
				continue
			case '{', '[':
				depth++
			case '}', ']':
				depth--
				if depth == 0 {
					return i + 1
				}
			}
			i++
		}
		return i
	}
	for i < len(data) {
		switch c := data[i]; {
		case c == ',' || c == '}' || c == ']' || isJSONSpace(c):
			return i
		}
		i++
	}
	return i
}

func keyName(key []byte) ([]byte, bool) {
	if len(key) < 2 || key[0] != '"' || key[len(key)-1] != '"' {
		return nil, false
	}
	k := key[1 : len(key)-1]
	for _, c := range k {
		if c == '\\' || c == '"' || c < ' ' || c >= utf8.RuneSelf {
			name, ok := unquoteJSON(key)
			return []byte(name), ok
		}
	}
	return k, true
}

func unquoteJSON(q []byte) (string, bool) {
	if len(q) < 2 || q[0] != '"' || q[len(q)-1] != '"' {
		return "", false
	}
	s := q[1 : len(q)-1]
	r := 0
	for r < len(s) {
		c := s[r]
		if c == '\\' || c == '"' || c < ' ' {
			break
		}
		if c < utf8.RuneSelf {
			r++
			continue
		}
		rr, size := utf8.DecodeRune(s[r:])
		if rr == utf8.RuneError && size == 1 {
			break
		}
		r += size
	}
	if r == len(s) {
		return string(s), true
	}
	b := make([]byte, 0, len(s)+2*utf8.UTFMax)
	b = append(b, s[:r]...)
	for r < len(s) {
		switch c := s[r]; {
		case c == '\\':
			r++
			if r >= len(s) {
				return "", false
			}
			switch s[r] {
			default:
				return "", false
			case '"', '\\', '/', '\'':
				b = append(b, s[r])
				r++
			case 'b':
				b = append(b, '\b')
				r++
			case 'f':
				b = append(b, '\f')
				r++
			case 'n':
				b = append(b, '\n')
				r++
			case 'r':
				b = append(b, '\r')
				r++
			case 't':
				b = append(b, '\t')
				r++
			case 'u':
				r--
				rr := hex4(s[r:])
				if rr < 0 {
					return "", false
				}
				r += 6
				if utf16.IsSurrogate(rr) {
					if dec := utf16.DecodeRune(rr, hex4(s[r:])); dec != unicode.ReplacementChar {
						r += 6
						b = utf8.AppendRune(b, dec)
						break
					}
					rr = unicode.ReplacementChar
				}
				b = utf8.AppendRune(b, rr)
			}
		case c == '"', c < ' ':
			return "", false
		case c < utf8.RuneSelf:
			b = append(b, c)
			r++
		default:
			rr, size := utf8.DecodeRune(s[r:])
			r += size
			b = utf8.AppendRune(b, rr)
		}
	}
	if cap(b)-len(b) > len(b)/4 {

		return string(b), true
	}

	return unsafe.String(unsafe.SliceData(b), len(b)), true
}

func hex4(s []byte) rune {
	if len(s) < 6 || s[0] != '\\' || s[1] != 'u' {
		return -1
	}
	var r rune
	for _, c := range s[2:6] {
		switch {
		case '0' <= c && c <= '9':
			c = c - '0'
		case 'a' <= c && c <= 'f':
			c = c - 'a' + 10
		case 'A' <= c && c <= 'F':
			c = c - 'A' + 10
		default:
			return -1
		}
		r = r*16 + rune(c)
	}
	return r
}

const jsonMaxDepth = 10000

const validMemoMin = 32 << 10

var validMemo struct {
	sync.Mutex
	sums [8]validEntry
	next int
}

type validSum struct {
	n   int
	sum uint64
}

type validEntry struct {
	validSum
	members []memberSpan
}

type memberSpan struct{ k0, k1, v0, v1 int }

var topSplit atomic.Pointer[func(data []byte)]

func longBody(data []byte) (valid bool, members []memberSpan) {
	if e, held := heldLongOf(data); held {
		return e.valid, e.members
	}
	s := validSum{len(data), validHash(data)}
	validMemo.Lock()
	i := slices.IndexFunc(validMemo.sums[:], func(e validEntry) bool { return e.validSum == s })
	if i >= 0 && validMemo.sums[i].members != nil {
		members = validMemo.sums[i].members
		validMemo.Unlock()
		return true, members
	}
	validMemo.Unlock()
	if i < 0 && !heldMember(data) {
		if f := validScanned.Load(); f != nil {
			(*f)(data)
		}
		if !jsonCheck(data) {
			return false, nil
		}
	}
	raw := trimJSON(data)
	if raw[0] == '{' {
		if f := topSplit.Load(); f != nil {
			(*f)(data)
		}
		members = []memberSpan{}
		eachMemberAt(raw, func(k0, k1, v0, v1 int) bool {
			members = append(members, memberSpan{k0, k1, v0, v1})
			return true
		})
	}
	validMemo.Lock()
	if i = slices.IndexFunc(validMemo.sums[:], func(e validEntry) bool { return e.validSum == s }); i >= 0 {
		validMemo.sums[i].members = members
	} else {
		validMemo.sums[validMemo.next] = validEntry{s, members}
		validMemo.next = (validMemo.next + 1) % len(validMemo.sums)
	}
	validMemo.Unlock()
	return true, members
}

var validSeed = maphash.MakeSeed()

func validHash(data []byte) uint64 {
	if f := validHashed.Load(); f != nil {
		(*f)(data)
	}
	return maphash.Bytes(validSeed, data)
}

var validHashed atomic.Pointer[func(data []byte)]

func heldLongOf(data []byte) (heldLong, bool) {
	key := unsafe.SliceData(data)
	heldBodies.Lock()
	e, ok := heldBodies.long[key]
	heldBodies.Unlock()
	if ok && e.n == len(data) {
		return e, true
	}
	l := heldBodies.list.Load()
	if l == nil || !slices.ContainsFunc(*l, func(b []byte) bool { return unsafe.SliceData(b) == key && len(b) == len(data) }) {
		return heldLong{}, false
	}
	e = heldLong{n: len(data)}
	if f := validScanned.Load(); f != nil {
		(*f)(data)
	}
	if e.valid = jsonCheck(data); e.valid {
		if raw := trimJSON(data); raw[0] == '{' {
			if f := topSplit.Load(); f != nil {
				(*f)(data)
			}
			e.members = []memberSpan{}
			eachMemberAt(raw, func(k0, k1, v0, v1 int) bool {
				e.members = append(e.members, memberSpan{k0, k1, v0, v1})
				return true
			})
		}
	}
	heldBodies.Lock()
	defer heldBodies.Unlock()

	if l := heldBodies.list.Load(); l != nil && slices.ContainsFunc(*l, func(b []byte) bool { return unsafe.SliceData(b) == key && len(b) == len(data) }) {
		if heldBodies.long == nil {
			heldBodies.long = map[*byte]heldLong{}
		}
		heldBodies.long[key] = e
	}
	return e, true
}

func heldMember(data []byte) bool {
	if len(data) == 0 {
		return false
	}
	p := uintptr(unsafe.Pointer(unsafe.SliceData(data)))
	l := heldBodies.list.Load()
	if l == nil {
		return false
	}
	heldBodies.Lock()
	defer heldBodies.Unlock()
	for _, b := range *l {
		e, ok := heldBodies.long[unsafe.SliceData(b)]
		if !ok || !e.valid || e.n != len(b) || len(e.members) == 0 {
			continue
		}
		raw := trimJSON(b)
		start := uintptr(unsafe.Pointer(unsafe.SliceData(raw)))
		if p < start || p+uintptr(len(data)) > start+uintptr(len(raw)) {
			continue
		}
		off := int(p - start)
		i, found := slices.BinarySearchFunc(e.members, off, func(m memberSpan, off int) int { return m.v0 - off })
		return found && e.members[i].v1-e.members[i].v0 == len(data)
	}
	return false
}

var validScanned atomic.Pointer[func(data []byte)]

func jsonValid(data []byte) bool {
	if len(data) < validMemoMin {
		return jsonCheck(data)
	}
	if e, held := heldLongOf(data); held {
		return e.valid
	}
	if heldMember(data) {
		return true
	}
	s := validSum{len(data), validHash(data)}
	validMemo.Lock()
	known := slices.ContainsFunc(validMemo.sums[:], func(e validEntry) bool { return e.validSum == s })
	validMemo.Unlock()
	if known {
		return true
	}
	if f := validScanned.Load(); f != nil {
		(*f)(data)
	}
	if !jsonCheck(data) {
		return false
	}
	validMemo.Lock()
	validMemo.sums[validMemo.next] = validEntry{validSum: s}
	validMemo.next = (validMemo.next + 1) % len(validMemo.sums)
	validMemo.Unlock()
	return true
}

func jsonCheck(data []byte) bool {
	i := skipJSONSpace(data, 0)
	i, ok := validJSONValue(data, i, 0)
	return ok && skipJSONSpace(data, i) == len(data)
}

var jsonStringByte = func() (t [256]bool) {
	for c := range 0x20 {
		t[c] = true
	}
	t['"'], t['\\'] = true, true
	return t
}()

func validJSONValue(data []byte, i, depth int) (int, bool) {
	if i >= len(data) {
		return i, false
	}
	switch c := data[i]; {
	case c == '"':
		return validJSONString(data, i)
	case c == '{':
		if depth+1 > jsonMaxDepth {
			return i, false
		}
		i = skipJSONSpace(data, i+1)
		if i < len(data) && data[i] == '}' {
			return i + 1, true
		}
		for {
			if i >= len(data) || data[i] != '"' {
				return i, false
			}
			var ok bool
			if i, ok = validJSONString(data, i); !ok {
				return i, false
			}
			i = skipJSONSpace(data, i)
			if i >= len(data) || data[i] != ':' {
				return i, false
			}
			i = skipJSONSpace(data, i+1)
			if i, ok = validJSONValue(data, i, depth+1); !ok {
				return i, false
			}
			i = skipJSONSpace(data, i)
			if i >= len(data) {
				return i, false
			}
			switch data[i] {
			case '}':
				return i + 1, true
			case ',':
				i = skipJSONSpace(data, i+1)
			default:
				return i, false
			}
		}
	case c == '[':
		if depth+1 > jsonMaxDepth {
			return i, false
		}
		i = skipJSONSpace(data, i+1)
		if i < len(data) && data[i] == ']' {
			return i + 1, true
		}
		for {
			var ok bool
			if i, ok = validJSONValue(data, i, depth+1); !ok {
				return i, false
			}
			i = skipJSONSpace(data, i)
			if i >= len(data) {
				return i, false
			}
			switch data[i] {
			case ']':
				return i + 1, true
			case ',':
				i = skipJSONSpace(data, i+1)
			default:
				return i, false
			}
		}
	case c == 't':
		return i + 4, bytes.HasPrefix(data[i:], jsonTrue)
	case c == 'f':
		return i + 5, bytes.HasPrefix(data[i:], jsonFalse)
	case c == 'n':
		return i + 4, bytes.HasPrefix(data[i:], jsonNull)
	case c == '-' || '0' <= c && c <= '9':
		return validJSONNumber(data, i)
	}
	return i, false
}

func stopsString(x uint64) bool {
	const ones, highs = 0x0101010101010101, 0x8080808080808080
	quote, slash := x^(ones*'"'), x^(ones*'\\')
	return ((x-ones*0x20)&^x|(quote-ones)&^quote|(slash-ones)&^slash)&highs != 0
}

func validJSONString(data []byte, i int) (int, bool) {
	i++
	for i < len(data) {
		for i+8 <= len(data) && !stopsString(binary.LittleEndian.Uint64(data[i:])) {
			i += 8
		}
		if i >= len(data) {
			break
		}
		c := data[i]
		if !jsonStringByte[c] {
			i++
			continue
		}
		switch {
		case c == '"':
			return i + 1, true
		case c < 0x20:
			return i, false
		}

		if i+1 >= len(data) {
			return i, false
		}
		switch data[i+1] {
		case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
			i += 2
		case 'u':
			if i+6 > len(data) {
				return i, false
			}
			for _, h := range data[i+2 : i+6] {
				if !('0' <= h && h <= '9' || 'a' <= h && h <= 'f' || 'A' <= h && h <= 'F') {
					return i, false
				}
			}
			i += 6
		default:
			return i, false
		}
	}
	return i, false
}

func isDigit(c byte) bool { return '0' <= c && c <= '9' }

func validJSONNumber(data []byte, i int) (int, bool) {
	if data[i] == '-' {
		i++
	}
	switch {
	case i >= len(data):
		return i, false
	case data[i] == '0':
		i++
	case isDigit(data[i]):
		for i < len(data) && isDigit(data[i]) {
			i++
		}
	default:
		return i, false
	}
	if i < len(data) && data[i] == '.' {
		i++
		if i >= len(data) || !isDigit(data[i]) {
			return i, false
		}
		for i < len(data) && isDigit(data[i]) {
			i++
		}
	}
	if i < len(data) && (data[i] == 'e' || data[i] == 'E') {
		i++
		if i < len(data) && (data[i] == '+' || data[i] == '-') {
			i++
		}
		if i >= len(data) || !isDigit(data[i]) {
			return i, false
		}
		for i < len(data) && isDigit(data[i]) {
			i++
		}
	}
	return i, true
}

func topMember(body []byte, key string) (val []byte, found, ok bool) {
	var members []memberSpan
	if len(body) >= validMemoMin {
		var valid bool
		if valid, members = longBody(body); !valid {
			return nil, false, false
		}
	} else if !jsonCheck(body) {
		return nil, false, false
	}
	raw := trimJSON(body)
	if raw[0] != '{' {
		return nil, false, false
	}
	eachMemberIn(raw, members, func(k, v []byte) bool {
		if keyIs(k, key) {
			val, found = v, true
		}
		return true
	})
	return val, found, true
}

func withoutTopMember(body []byte, key string) []byte {
	var members []memberSpan
	if len(body) >= validMemoMin {
		var valid bool
		if valid, members = longBody(body); !valid {
			return body
		}
	} else if !jsonCheck(body) {
		return body
	}
	start := skipJSONSpace(body, 0)
	raw := trimJSON(body)
	if raw[0] != '{' {
		return body
	}
	if members == nil {
		eachMemberAt(raw, func(k0, k1, v0, v1 int) bool {
			members = append(members, memberSpan{k0, k1, v0, v1})
			return true
		})
	}

	var cuts [][2]int
	for i := 0; i < len(members); {
		if !keyIs(raw[members[i].k0:members[i].k1], key) {
			i++
			continue
		}
		j := i + 1
		for j < len(members) && keyIs(raw[members[j].k0:members[j].k1], key) {
			j++
		}
		switch {
		case j < len(members):
			cuts = append(cuts, [2]int{members[i].k0, members[j].k0})
		case i > 0:
			cuts = append(cuts, [2]int{members[i-1].v1, members[j-1].v1})
		default:
			cuts = append(cuts, [2]int{1, len(raw) - 1})
		}
		i = j
	}
	if len(cuts) == 0 {
		return body
	}
	out := make([]byte, 0, len(body))
	out = append(out, body[:start]...)
	last := 0
	for _, c := range cuts {
		out = append(out, raw[last:c[0]]...)
		last = c[1]
	}
	out = append(out, raw[last:]...)
	return append(out, body[start+len(raw):]...)
}

func memberOf(obj []byte, key string) (val []byte, found bool) {
	eachMember(obj, func(k, v []byte) bool {
		if keyIs(k, key) {
			val, found = v, true
		}
		return true
	})
	return val, found
}

func keyIs(quoted []byte, key string) bool {
	if len(quoted) == len(key)+2 && string(quoted[1:len(quoted)-1]) == key {
		return true
	}
	if bytes.IndexByte(quoted, '\\') < 0 {
		return false
	}
	s, _ := unquoteJSON(quoted)
	return s == key
}

func stringBytes(raw []byte) ([]byte, bool) {
	if len(raw) == 0 || raw[0] != '"' {
		return nil, false
	}
	if s := raw[1 : len(raw)-1]; plainASCII(s) {
		return s, true
	}
	s, ok := unquoteJSON(raw)
	return []byte(s), ok
}

func plainASCII(s []byte) bool {
	for _, c := range s {
		if c == '\\' || c >= 0x80 {
			return false
		}
	}
	return true
}

func memberOrNil(it []byte, key string) []byte {
	if len(it) == 0 || it[0] != '{' {
		return nil
	}
	v, _ := memberOf(it, key)
	return v
}

func marshalRaw(v any, escapeHTML bool) (_ []byte, ok bool) {
	switch v := v.(type) {
	case map[string]json.RawMessage:
		if v == nil {
			return []byte("null"), true
		}
		n := 2
		keys := make([]string, 0, len(v))
		for k, raw := range v {
			n += len(k) + len(raw) + 4
			keys = append(keys, k)
		}
		slices.Sort(keys)
		dst := make([]byte, 0, n)
		dst = append(dst, '{')
		for i, k := range keys {
			if i > 0 {
				dst = append(dst, ',')
			}
			if dst, ok = appendJSONKey(dst, k, escapeHTML); !ok {
				return nil, false
			}
			dst = append(dst, ':')
			if dst, ok = appendRawJSON(dst, v[k], escapeHTML); !ok {
				return nil, false
			}
		}
		return append(dst, '}'), true
	case []json.RawMessage:
		if v == nil {
			return []byte("null"), true
		}
		n := 2
		for _, raw := range v {
			n += len(raw) + 1
		}
		dst := make([]byte, 0, n)
		dst = append(dst, '[')
		for i, raw := range v {
			if i > 0 {
				dst = append(dst, ',')
			}
			if dst, ok = appendRawJSON(dst, raw, escapeHTML); !ok {
				return nil, false
			}
		}
		return append(dst, ']'), true
	}
	return nil, false
}

func appendJSONKey(dst []byte, key string, escapeHTML bool) ([]byte, bool) {
	for i := 0; i < len(key); i++ {
		if c := key[i]; c < 0x20 || c >= 0x7f || c == '"' || c == '\\' || escapeHTML && (c == '<' || c == '>' || c == '&') {
			var b bytes.Buffer
			enc := json.NewEncoder(&b)
			enc.SetEscapeHTML(escapeHTML)
			if enc.Encode(key) != nil {
				return dst, false
			}
			return append(dst, bytes.TrimRight(b.Bytes(), "\n")...), true
		}
	}
	dst = append(dst, '"')
	dst = append(dst, key...)
	return append(dst, '"'), true
}

func appendRawJSON(dst []byte, raw json.RawMessage, escapeHTML bool) ([]byte, bool) {
	if raw == nil {
		return append(dst, "null"...), true
	}
	if !jsonCheck(raw) {
		return dst, false
	}
	return appendCompactJSON(dst, raw, escapeHTML), true
}

func appendCompactJSON(dst, src []byte, escapeHTML bool) []byte {
	start := 0
	for i := 0; i < len(src); {
		switch c := src[i]; {
		case c == '"':
			j := skipJSONString(src, i)
			if escapeHTML {
				dst = append(dst, src[start:i]...)
				dst = appendHTMLEscaped(dst, src[i:j])
				start = j
			}
			i = j
		case isJSONSpace(c):
			dst = append(dst, src[start:i]...)
			i++
			start = i
		default:
			i++
		}
	}
	return append(dst, src[start:]...)
}

func appendHTMLEscaped(dst, s []byte) []byte {
	const hex = "0123456789abcdef"
	start := 0
	for i := 0; i < len(s); i++ {
		switch c := s[i]; {
		case c == '<' || c == '>' || c == '&':
			dst = append(dst, s[start:i]...)
			dst = append(dst, '\\', 'u', '0', '0', hex[c>>4], hex[c&0xF])
			start = i + 1
		case c == 0xE2 && i+2 < len(s) && s[i+1] == 0x80 && s[i+2]&^1 == 0xA8:
			dst = append(dst, s[start:i]...)
			dst = append(dst, '\\', 'u', '2', '0', '2', hex[s[i+2]&0xF])
			start = i + 3
			i += 2
		}
	}
	return append(dst, s[start:]...)
}

func marshalBody(out map[string]any, spent string) ([]byte, error) {
	keys := make([]string, 0, len(out))
	for k := range out {

		if _, ok := appendJSONKey(nil, k, true); !ok {
			return json.Marshal(out)
		}
		keys = append(keys, k)
	}
	slices.Sort(keys)
	vals := make([][]json.RawMessage, len(keys))
	kept := bodyKept
	n := 2
	for i, k := range keys {
		items, sizes, ok := marshalItems(out[k], k == spent, &kept)
		if !ok {
			return json.Marshal(out)
		}
		vals[i] = items
		n += len(k) + 4 + len(items) + sizes
	}
	dst := make([]byte, 0, n)
	dst = append(dst, '{')
	for i, k := range keys {
		if i > 0 {
			dst = append(dst, ',')
		}
		var ok bool
		if dst, ok = appendJSONKey(dst, k, true); !ok {
			return json.Marshal(out)
		}
		dst = append(dst, ':')
		items := vals[i]
		vals[i] = nil
		if !isSplitList(out[k]) {
			dst = append(dst, items[0]...)
			continue
		}
		dst = append(dst, '[')
		list := reflect.ValueOf(out[k])
		for j, it := range items {
			if j > 0 {
				dst = append(dst, ',')
			}
			if it != nil {
				dst = append(dst, it...)
				continue
			}

			var err error
			if dst, err = appendJSONValue(dst, list.Index(j).Addr().Interface()); err != nil {
				return nil, err
			}
			if k == spent {
				list.Index(j).SetZero()
			}
		}
		dst = append(dst, ']')
	}
	return append(dst, '}'), nil
}

func isSplitList(v any) bool {
	if _, ok := v.(json.Marshaler); ok {
		return false
	}
	rv := reflect.ValueOf(v)
	return rv.Kind() == reflect.Slice && rv.Type().Elem().Kind() != reflect.Uint8 && rv.Len() > 1
}

func marshalItems(v any, spend bool, kept *int) ([]json.RawMessage, int, bool) {
	if !isSplitList(v) {
		b, err := marshalSized(v)
		*kept -= len(b)
		return []json.RawMessage{b}, len(b), err == nil
	}
	rv := reflect.ValueOf(v)
	items := make([]json.RawMessage, rv.Len())
	size := 0
	for i := range items {

		it := rv.Index(i).Addr().Interface()
		if *kept <= 0 {
			n, ok := jsonSize(it)
			if !ok {
				return nil, 0, false
			}
			size += n
			continue
		}
		b, err := marshalSized(it)
		if err != nil {
			return nil, 0, false
		}
		items[i] = b
		size += len(b)
		*kept -= len(b)
		if spend {
			rv.Index(i).SetZero()
		}
	}
	return items, size, true
}

func marshalSized(v any) ([]byte, error) {
	n, ok := jsonSize(v)
	if !ok {
		return json.Marshal(v)
	}
	return appendJSONValue(make([]byte, 0, n), v)
}

func jsonSize(v any) (int, bool) {
	switch v := v.(type) {
	case nil:
		return 4, true
	case string:
		return jsonStringSize(v), true
	case bool:
		if v {
			return 4, true
		}
		return 5, true
	case int:
		var b [20]byte
		return len(strconv.AppendInt(b[:0], int64(v), 10)), true
	case int64:
		var b [20]byte
		return len(strconv.AppendInt(b[:0], v, 10)), true
	case *any:

		if v == nil {
			return 4, true
		}
		return jsonSize(*v)
	case *map[string]any:
		if v == nil {
			return 4, true
		}
		return jsonSize(*v)
	case map[string]any:
		if v == nil {
			return 4, true
		}
		n := 2 + max(len(v)-1, 0)
		for k, x := range v {
			if !plainJSONKey(k) {
				return 0, false
			}
			m, ok := jsonSize(x)
			if !ok {
				return 0, false
			}
			n += len(k) + 3 + m
		}
		return n, true
	case *[]map[string]any:
		if v == nil {
			return 4, true
		}
		return jsonSize(*v)
	case []map[string]any:
		if v == nil {
			return 4, true
		}
		n := 2 + max(len(v)-1, 0)
		for _, x := range v {
			m, ok := jsonSize(x)
			if !ok {
				return 0, false
			}
			n += m
		}
		return n, true
	case *[]any:
		if v == nil {
			return 4, true
		}
		return jsonSize(*v)
	case []any:
		if v == nil {
			return 4, true
		}
		n := 2 + max(len(v)-1, 0)
		for _, x := range v {
			m, ok := jsonSize(x)
			if !ok {
				return 0, false
			}
			n += m
		}
		return n, true
	}
	b, err := json.Marshal(v)
	return len(b), err == nil
}

func appendJSONValue(dst []byte, v any) ([]byte, error) {
	switch v := v.(type) {
	case nil:
		return append(dst, "null"...), nil
	case string:
		return appendJSONString(dst, v), nil
	case bool:
		return strconv.AppendBool(dst, v), nil
	case int:
		return strconv.AppendInt(dst, int64(v), 10), nil
	case int64:
		return strconv.AppendInt(dst, v, 10), nil
	case *any:
		if v == nil {
			return append(dst, "null"...), nil
		}
		return appendJSONValue(dst, *v)
	case *map[string]any:
		if v == nil {
			return append(dst, "null"...), nil
		}
		return appendJSONValue(dst, *v)
	case map[string]any:
		if v == nil {
			return append(dst, "null"...), nil
		}
		keys := make([]string, 0, len(v))
		for k := range v {
			if !plainJSONKey(k) {
				return appendMarshalled(dst, v)
			}
			keys = append(keys, k)
		}
		slices.Sort(keys)
		dst = append(dst, '{')
		for i, k := range keys {
			if i > 0 {
				dst = append(dst, ',')
			}
			dst = append(dst, '"')
			dst = append(dst, k...)
			dst = append(dst, '"', ':')
			var err error
			if dst, err = appendJSONValue(dst, v[k]); err != nil {
				return dst, err
			}
		}
		return append(dst, '}'), nil
	case *[]map[string]any:
		if v == nil {
			return append(dst, "null"...), nil
		}
		return appendJSONValue(dst, *v)
	case []map[string]any:
		if v == nil {
			return append(dst, "null"...), nil
		}
		dst = append(dst, '[')
		for i, x := range v {
			if i > 0 {
				dst = append(dst, ',')
			}
			var err error
			if dst, err = appendJSONValue(dst, x); err != nil {
				return dst, err
			}
		}
		return append(dst, ']'), nil
	case *[]any:
		if v == nil {
			return append(dst, "null"...), nil
		}
		return appendJSONValue(dst, *v)
	case []any:
		if v == nil {
			return append(dst, "null"...), nil
		}
		dst = append(dst, '[')
		for i, x := range v {
			if i > 0 {
				dst = append(dst, ',')
			}
			var err error
			if dst, err = appendJSONValue(dst, x); err != nil {
				return dst, err
			}
		}
		return append(dst, ']'), nil
	}
	return appendMarshalled(dst, v)
}

func appendMarshalled(dst []byte, v any) ([]byte, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return dst, err
	}
	return append(dst, b...), nil
}

func plainJSONKey(k string) bool {
	for i := 0; i < len(k); i++ {
		if c := k[i]; c < 0x20 || c >= 0x7f || c == '"' || c == '\\' || c == '<' || c == '>' || c == '&' {
			return false
		}
	}
	return true
}

func jsonStringSize(s string) int {
	n := 2
	for i := 0; i < len(s); {
		c := s[i]
		if c < utf8.RuneSelf {
			switch {
			case c == '"', c == '\\', c == '\b', c == '\f', c == '\n', c == '\r', c == '\t':
				n += 2
			case c < 0x20, c == '<', c == '>', c == '&':
				n += 6
			default:
				n++
			}
			i++
			continue
		}
		r, size := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && size == 1 || r == '\u2028' || r == '\u2029' {
			n += 6
		} else {
			n += size
		}
		i += size
	}
	return n
}

func appendJSONString(dst []byte, s string) []byte {
	const hex = "0123456789abcdef"
	dst = append(dst, '"')
	start := 0
	for i := 0; i < len(s); {
		c := s[i]
		if c < utf8.RuneSelf {
			if c >= 0x20 && c != '"' && c != '\\' && c != '<' && c != '>' && c != '&' {
				i++
				continue
			}
			dst = append(dst, s[start:i]...)
			switch c {
			case '"', '\\':
				dst = append(dst, '\\', c)
			case '\b':
				dst = append(dst, '\\', 'b')
			case '\f':
				dst = append(dst, '\\', 'f')
			case '\n':
				dst = append(dst, '\\', 'n')
			case '\r':
				dst = append(dst, '\\', 'r')
			case '\t':
				dst = append(dst, '\\', 't')
			default:
				dst = append(dst, '\\', 'u', '0', '0', hex[c>>4], hex[c&0xF])
			}
			i++
			start = i
			continue
		}
		r, size := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && size == 1 {
			dst = append(dst, s[start:i]...)
			dst = append(dst, `\ufffd`...)
			i += size
			start = i
			continue
		}
		if r == '\u2028' || r == '\u2029' {
			dst = append(dst, s[start:i]...)
			dst = append(dst, '\\', 'u', '2', '0', '2', hex[r&0xF])
			i += size
			start = i
			continue
		}
		i += size
	}
	dst = append(dst, s[start:]...)
	return append(dst, '"')
}

var bodyKept = 4 << 20
