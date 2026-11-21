// RE2-safe JSON Schema `pattern` / `patternProperties` handling for agy.
//
// agy validates every tool parameter schema against the JSON Schema 2020-12
// metaschema using Go's `regexp` library (RE2). JSON Schema defines `pattern`
// as an ECMA-262 regular expression, so constructs that are legal in JavaScript
// — `\uXXXX` / `\u{...}` escapes, lookaheads, backreferences — make agy fail
// "building toolbox" and abort the whole turn before any model call.
//
// We translate the Unicode escapes RE2 can express (`\uXXXX` → `\x{XXXX}`),
// join UTF-16 surrogate pairs into one code point (including mixed escaped
// and raw pairs), then drop anything still not compilable as RE2 — or whose
// RE2 meaning is not the ECMA-262 meaning, such as `\z`, `\S`, `\Q…\E`,
// `\a`, and `\A` — into a description hint. Common character classes
// (`\s`, `\d`, `\w`) are kept even though RE2 is ASCII-only for these;
// dropping `\s` would disable many ordinary tool schemas. The rewrite is
// idempotent. Tool-call arguments are plain JSON values, not patterns, so
// the response path needs no reverse transform.
//
// See: https://github.com/google-antigravity/antigravity-cli/issues/1327

const HINT_PREFIX = "pattern: "

export function appendHint(node, hint) {
  if (!hint || !node || typeof node !== "object" || Array.isArray(node)) return
  if (typeof node.description === "string" && node.description.trim()) {
    if (!node.description.includes(hint)) node.description = `${node.description} (${hint})`
  } else {
    node.description = hint
  }
}

const HIGH_SURROGATE_START = 0xD800
const HIGH_SURROGATE_END = 0xDBFF
const LOW_SURROGATE_START = 0xDC00
const LOW_SURROGATE_END = 0xDFFF
const UNICODE_MAX = 0x10FFFF

function isHighSurrogate(cp) {
  return cp >= HIGH_SURROGATE_START && cp <= HIGH_SURROGATE_END
}

function isLowSurrogate(cp) {
  return cp >= LOW_SURROGATE_START && cp <= LOW_SURROGATE_END
}

function joinSurrogates(high, low) {
  return 0x10000 + ((high - HIGH_SURROGATE_START) << 10) + (low - LOW_SURROGATE_START)
}

function isHex(char) {
  return /[0-9a-fA-F]/.test(char)
}

function parseUnicodeEscape(source, idx) {
  if (source[idx] !== "\\") return null
  const rest = source.slice(idx + 1)
  let match = /^u\{([0-9a-fA-F]+)\}/.exec(rest)
  if (match) return { end: idx + 1 + match[0].length, cp: parseInt(match[1], 16), hex: match[1] }
  match = /^u([0-9a-fA-F]{4})/.exec(rest)
  if (match) return { end: idx + 1 + match[0].length, cp: parseInt(match[1], 16), hex: match[1] }
  match = /^U([0-9a-fA-F]{8})/.exec(rest)
  if (match) return { end: idx + 1 + match[0].length, cp: parseInt(match[1], 16), hex: match[1] }
  match = /^x\{([0-9a-fA-F]+)\}/.exec(rest)
  if (match) return { end: idx + 1 + match[0].length, cp: parseInt(match[1], 16), hex: match[1] }
  return null
}

function emitHex(cp, hex = null) {
  if (hex != null && Number.parseInt(hex, 16) === cp) return `\\x{${hex}}`
  const digits = cp.toString(16).toUpperCase()
  return `\\x{${cp <= 0xFFFF ? digits.padStart(4, "0") : digits}}`
}

// Escape-aware translation of ECMA-262 Unicode escapes into RE2 `\x{...}`.
// Adjacent UTF-16 surrogate escapes (and raw surrogate pairs in the string)
// are joined into one code point so `😀` stays a single character in RE2.
// `\\u0000` (a literal backslash then the letters u0000) is left alone.
export function translateUnicodeEscapes(source) {
  if (typeof source !== "string") return source
  let out = ""
  let i = 0
  const length = source.length
  while (i < length) {
    const parsed = parseUnicodeEscape(source, i)
    if (parsed) {
      const next = parseUnicodeEscape(source, parsed.end)
      if (Number.isFinite(parsed.cp) && isHighSurrogate(parsed.cp) && next && Number.isFinite(next.cp) && isLowSurrogate(next.cp)) {
        out += emitHex(joinSurrogates(parsed.cp, next.cp))
        i = next.end
        continue
      }
      // Mixed: escaped high surrogate + raw low surrogate code unit.
      if (Number.isFinite(parsed.cp) && isHighSurrogate(parsed.cp) && parsed.end < length) {
        const rawLow = source.charCodeAt(parsed.end)
        if (isLowSurrogate(rawLow)) {
          out += emitHex(joinSurrogates(parsed.cp, rawLow))
          i = parsed.end + 1
          continue
        }
      }
      out += emitHex(parsed.cp, parsed.hex)
      i = parsed.end
      continue
    }
    if (source[i] === "\\") {
      out += source[i++]
      if (i < length) out += source[i++]
      continue
    }
    const code = source.charCodeAt(i)
    if (isHighSurrogate(code) && i + 1 < length) {
      const next = parseUnicodeEscape(source, i + 1)
      if (next && Number.isFinite(next.cp) && isLowSurrogate(next.cp)) {
        out += emitHex(joinSurrogates(code, next.cp))
        i = next.end
        continue
      }
      const low = source.charCodeAt(i + 1)
      if (isLowSurrogate(low)) {
        out += emitHex(joinSurrogates(code, low))
        i += 2
        continue
      }
    }
    out += source[i++]
  }
  return out
}

// Letters accepted after a backslash outside a character class, when the
// RE2 meaning matches ECMA-262 closely enough to keep. `\z` and `\S`
// compile in RE2 but differ from JS (yetone called these out). `\a` is
// BEL in RE2 and a literal `a` in non-unicode JS; `\A` is start-of-text
// in RE2 and a literal `A` in JS; `\Q…\E` is quoting in RE2 and not
// an ECMA-262 construct. All of those are dropped into a hint.
// `\s` / `\d` / `\w` are kept (RE2 is ASCII-only for these).
const RE2_LETTER_ESCAPES = new Set([
  "f", "n", "r", "t", "v",
  "b", "B", "d", "D", "s", "w", "W",
])

// `\b` / `\B` / `\A` / `\z` / `\Q` / `\E` / `\a` are not kept inside a class.
const RE2_CLASS_LETTER_ESCAPES = new Set([
  "f", "n", "r", "t", "v",
  "d", "D", "s", "w", "W",
])

const SINGLE_ESCAPE_CP = {
  f: 0x0c,
  n: 0x0a,
  r: 0x0d,
  t: 0x09,
  v: 0x0b,
}

const RE2_GROUP_FLAGS = new Set(["i", "m", "s", "U"])

// Names Go's `regexp` accepts in `\p{...}` / `\P{...}` (case-insensitive).
// Includes general categories, scripts, and the aliases Go documents (Any,
// ASCII, Assigned, Letter, …). `Script=Greek` and other key=value forms are
// not in this set and are rejected. Generated against Go 1.27's `regexp`.
const RE2_UNICODE_PROPERTIES = new Set([
  "adlam", "ahom", "anatolian_hieroglyphs", "any", "arabic", "armenian", "ascii", "assigned",
  "avestan", "balinese", "bamum", "bassa_vah", "batak", "bengali", "beria_erfe", "bhaiksuki",
  "bopomofo", "brahmi", "braille", "buginese", "buhid", "c", "canadian_aboriginal", "carian",
  "cased_letter", "caucasian_albanian", "cc", "cf", "chakma", "cham", "cherokee", "chorasmian",
  "close_punctuation", "cn", "cntrl", "co", "common", "connector_punctuation", "control", "coptic",
  "cs", "cuneiform", "currency_symbol", "cypriot", "cypro_minoan", "cyrillic", "dash_punctuation", "decimal_number",
  "deseret", "devanagari", "digit", "dives_akuru", "dogra", "duployan", "egyptian_hieroglyphs", "elbasan",
  "elymaic", "enclosing_mark", "ethiopic", "final_punctuation", "format", "garay", "georgian", "glagolitic",
  "gothic", "grantha", "greek", "gujarati", "gunjala_gondi", "gurmukhi", "gurung_khema", "han",
  "hangul", "hanifi_rohingya", "hanunoo", "hatran", "hebrew", "hiragana", "imperial_aramaic", "inherited",
  "initial_punctuation", "inscriptional_pahlavi", "inscriptional_parthian", "javanese", "kaithi", "kannada", "katakana", "kawi",
  "kayah_li", "kharoshthi", "khitan_small_script", "khmer", "khojki", "khudawadi", "kirat_rai", "l",
  "lao", "latin", "lc", "lepcha", "letter", "letter_number", "limbu", "line_separator",
  "linear_a", "linear_b", "lisu", "ll", "lm", "lo", "lowercase_letter", "lt",
  "lu", "lycian", "lydian", "m", "mahajani", "makasar", "malayalam", "mandaic",
  "manichaean", "marchen", "mark", "masaram_gondi", "math_symbol", "mc", "me", "medefaidrin",
  "meetei_mayek", "mende_kikakui", "meroitic_cursive", "meroitic_hieroglyphs", "miao", "mn", "modi", "modifier_letter",
  "modifier_symbol", "mongolian", "mro", "multani", "myanmar", "n", "nabataean", "nag_mundari",
  "nandinagari", "nd", "new_tai_lue", "newa", "nko", "nl", "no", "nonspacing_mark",
  "number", "nushu", "nyiakeng_puachue_hmong", "ogham", "ol_chiki", "ol_onal", "old_hungarian", "old_italic",
  "old_north_arabian", "old_permic", "old_persian", "old_sogdian", "old_south_arabian", "old_turkic", "old_uyghur", "open_punctuation",
  "oriya", "osage", "osmanya", "other", "other_letter", "other_number", "other_punctuation", "other_symbol",
  "p", "pahawh_hmong", "palmyrene", "paragraph_separator", "pau_cin_hau", "pc", "pd", "pe",
  "pf", "phags_pa", "phoenician", "pi", "po", "private_use", "ps", "psalter_pahlavi",
  "punct", "punctuation", "rejang", "runic", "s", "samaritan", "saurashtra", "sc",
  "separator", "sharada", "shavian", "siddham", "sidetic", "signwriting", "sinhala", "sk",
  "sm", "so", "sogdian", "sora_sompeng", "soyombo", "space_separator", "spacing_mark", "sundanese",
  "sunuwar", "surrogate", "syloti_nagri", "symbol", "syriac", "tagalog", "tagbanwa", "tai_le",
  "tai_tham", "tai_viet", "tai_yo", "takri", "tamil", "tangsa", "tangut", "telugu",
  "thaana", "thai", "tibetan", "tifinagh", "tirhuta", "titlecase_letter", "todhri", "tolong_siki",
  "toto", "tulu_tigalari", "ugaritic", "unassigned", "uppercase_letter", "vai", "vithkuqi", "wancho",
  "warang_citi", "yezidi", "yi", "z", "zanabazar_square", "zl", "zp", "zs",
])

function isKnownUnicodeProperty(name) {
  if (typeof name !== "string" || !name) return false
  const body = name[0] === "^" ? name.slice(1) : name
  return body.length > 0 && RE2_UNICODE_PROPERTIES.has(body.toLowerCase())
}

function isCodePointInRange(cp) {
  return Number.isInteger(cp) && cp >= 0 && cp <= UNICODE_MAX
}

// Conservative RE2 compiler check. Returns true only when the pattern should
// compile with Go's `regexp.Compile` (the same engine agy uses) *and* keep
// its JavaScript meaning. Anything we cannot positively accept is rejected,
// which drops the pattern into a hint rather than risking a toolbox failure.
export function isRE2Safe(source) {
  if (typeof source !== "string") return false
  const length = source.length
  let i = 0
  let depth = 0
  let canQuantify = false

  // Repeat-product tracking, matching Go's repeatIsValid(..., 1000):
  // the product of nested `{n}` / `{n,m}` / `{n,}` maxima (min if unbounded)
  // along any one path must not exceed 1000. Concat and alternation take
  // the max of their children, not the product. `*`, `+`, `?`, `{0,}`, and
  // `{1,}` are not OpRepeat product-checked in Go.
  const groupStack = [{ alt: 1, best: 1, last: 1 }]
  const ctx = () => groupStack[groupStack.length - 1]
  const foldLast = () => {
    const c = ctx()
    c.alt = Math.max(c.alt, c.last)
  }
  const noteAtom = (mass = 1) => {
    foldLast()
    ctx().last = mass
    canQuantify = true
  }

  const parseEscape = (inCharClass) => {
    // Called at `\`. Returns null on error, or {set} / {cp}.
    if (i >= length || source[i] !== "\\") return null
    i++
    if (i >= length) return null
    const next = source[i++]
    if (next >= "1" && next <= "9") return null
    if (next === "0") {
      let extra = 0
      let oct = 0
      while (extra < 2 && i < length && source[i] >= "0" && source[i] <= "7") {
        oct = (oct << 3) + (source[i++] - "0")
        extra++
      }
      return { cp: oct }
    }
    if (next === "x") {
      if (i < length && source[i] === "{") {
        i++
        let hex = ""
        while (i < length && isHex(source[i])) hex += source[i++]
        if (!hex || i >= length || source[i] !== "}") return null
        i++
        const cp = Number.parseInt(hex, 16)
        if (!isCodePointInRange(cp)) return null
        return { cp }
      }
      if (i + 1 < length && isHex(source[i]) && isHex(source[i + 1])) {
        const cp = Number.parseInt(source.slice(i, i + 2), 16)
        i += 2
        return { cp }
      }
      return null
    }
    if (next === "p" || next === "P") {
      if (i < length && source[i] === "{") {
        i++
        let name = ""
        while (i < length && source[i] !== "}") {
          const char = source[i]
          if (!/[A-Za-z0-9_^]/.test(char)) return null
          name += char
          i++
        }
        if (!name || i >= length || source[i] !== "}") return null
        i++
        if (!isKnownUnicodeProperty(name)) return null
        return { set: true }
      }
      if (i < length && /[A-Za-z]/.test(source[i])) {
        const name = source[i++]
        if (!isKnownUnicodeProperty(name)) return null
        return { set: true }
      }
      return null
    }
    // `\Q…\E` is RE2 quoting, not ECMA-262. Drop it.
    if (next === "Q" || next === "E") return null
    if (next === "u" || next === "U" || next === "C" || next === "k" || next === "Z" || next === "G") return null
    // `\z` and `\S` compile in RE2 but differ from JS; drop them.
    // `\a` / `\A` also differ from JS (BEL / start-of-text vs literal letters).
    if (next === "z" || next === "S" || next === "a" || next === "A") return null
    if (/[A-Za-z]/.test(next)) {
      const allowed = (inCharClass ? RE2_CLASS_LETTER_ESCAPES : RE2_LETTER_ESCAPES).has(next)
      if (!allowed) return null
      if (next === "d" || next === "D" || next === "s" || next === "w" || next === "W") return { set: true }
      if (next === "b" || next === "B") return { set: true }
      if (Object.hasOwn(SINGLE_ESCAPE_CP, next)) return { cp: SINGLE_ESCAPE_CP[next] }
      return { set: true }
    }
    // Unknown letter-like or non-ASCII escapes (`\é`) are invalid in RE2.
    // Punctuation escapes (`\.`, `\ `, `\-`, …) are accepted as that character.
    if (/^[A-Za-z]$/.test(next) === false && next.charCodeAt(0) >= 0x80) return null
    return { cp: next.charCodeAt(0) }
  }

  const parseClassItem = () => {
    if (i >= length) return null
    if (source[i] === "\\") return parseEscape(true)
    let cp = source.charCodeAt(i++)
    if (isHighSurrogate(cp) && i < length && isLowSurrogate(source.charCodeAt(i))) {
      cp = joinSurrogates(cp, source.charCodeAt(i++))
    }
    return { cp }
  }

  const consumeClass = () => {
    // Called at `[`. Rejects inverted ranges (`[z-a]`) the way Go does
    // (`hi < lo` is ErrInvalidCharRange).
    i++
    if (i < length && source[i] === "^") i++
    let justOpened = true
    while (i < length) {
      if (source[i] === "]" && !justOpened) {
        i++
        return true
      }
      // Go treats `[:` inside a class as a POSIX named class (`[[:alpha:]]`).
      // JS does not, so keepers would either fail to compile in RE2 or
      // match a different set. Reject the pattern and drop it to a hint.
      if (source[i] === "[" && i + 1 < length && source[i + 1] === ":") return false
      const lo = parseClassItem()
      if (!lo) return false
      justOpened = false
      // `[a-]` : the '-' before ']' is literal, not a range.
      if (lo.cp != null && i < length && source[i] === "-" && i + 1 < length && source[i + 1] !== "]") {
        i++
        const hi = parseClassItem()
        if (!hi) return false
        if (hi.cp == null) return false
        if (hi.cp < lo.cp) return false
      }
    }
    return false
  }

  const applyRepeatProduct = (min, maxStr) => {
    const hasMax = maxStr != null && maxStr !== ""
    const max = hasMax ? Number(maxStr) : null
    // Go only product-checks OpRepeat when min >= 2 or max >= 2.
    // `{0,}`, `{1,}`, `{1}` and `{0,1}` are not product-checked.
    const productChecked = min >= 2 || (hasMax && max >= 2)
    if (!productChecked) return true
    const m = hasMax ? max : min
    const last = ctx().last || 1
    if (m > 0 && last * m > 1000) return false
    ctx().last = last * m
    return true
  }

  const consumeRepeat = () => {
    // Called at `{`. A well-formed bound is `{n}`, `{n,}` or `{n,m}`.
    // RE2 rejects a leading or nested well-formed bound, a bound above 1000,
    // min > max, and a nested product of maxima above 1000 (e.g. `(a{1000}){2}`).
    // A `{` that is not a well-formed bound is a literal.
    const start = i
    i++
    if (i >= length || source[i] < "0" || source[i] > "9") {
      i = start + 1
      noteAtom(1)
      return true
    }
    let minStr = ""
    while (i < length && source[i] >= "0" && source[i] <= "9") minStr += source[i++]
    let maxStr = null
    if (i < length && source[i] === ",") {
      i++
      maxStr = ""
      while (i < length && source[i] >= "0" && source[i] <= "9") maxStr += source[i++]
    }
    if (i >= length || source[i] !== "}") {
      i = start + 1
      noteAtom(1)
      return true
    }
    if (!canQuantify) return false
    const min = Number(minStr)
    if (min > 1000) return false
    if (maxStr != null && maxStr !== "") {
      const max = Number(maxStr)
      if (max > 1000 || min > max) return false
    }
    i++
    if (i < length && source[i] === "?") i++
    else if (i < length && source[i] === "+") return false
    if (!applyRepeatProduct(min, maxStr)) return false
    canQuantify = false
    return true
  }

  const consumeNamedGroup = () => {
    // Called after `(?<` or `(?P<`.
    let name = 0
    while (i < length && source[i] !== ">") {
      if (!/[A-Za-z0-9_]/.test(source[i])) return false
      i++
      name++
    }
    if (name === 0 || i >= length || source[i] !== ">") return false
    i++
    depth++
    foldLast()
    groupStack.push({ alt: 1, best: 1, last: 1 })
    canQuantify = false
    return true
  }

  const consumeGroup = () => {
    // Called at `(`.
    i++
    if (i < length && source[i] === "?") {
      i++
      if (i >= length) return false
      const next = source[i]
      if (next === ":") {
        i++
        depth++
        foldLast()
        groupStack.push({ alt: 1, best: 1, last: 1 })
        canQuantify = false
        return true
      }
      if (next === "P") {
        i++
        if (i >= length || source[i] !== "<") return false
        i++
        return consumeNamedGroup()
      }
      if (next === "<") {
        // Go 1.26+ accepts `(?<name>…)` as well as `(?P<name>…)`.
        // Lookbehinds `(?<=` / `(?<!` are still rejected.
        i++
        if (i < length && (source[i] === "=" || source[i] === "!")) return false
        return consumeNamedGroup()
      }
      // Flags: (?imsU) or (?imsU-imsU) or (?imsU:...) — not lookaheads.
      let flags = 0
      while (i < length && RE2_GROUP_FLAGS.has(source[i])) {
        i++
        flags++
      }
      if (i < length && source[i] === "-") {
        i++
        while (i < length && RE2_GROUP_FLAGS.has(source[i])) {
          i++
          flags++
        }
      }
      if (i < length && source[i] === ":") {
        if (flags === 0) return false
        i++
        depth++
        foldLast()
        groupStack.push({ alt: 1, best: 1, last: 1 })
        canQuantify = false
        return true
      }
      if (i < length && source[i] === ")") {
        if (flags === 0) return false
        i++
        canQuantify = false
        return true
      }
      // `(?=`, `(?!`, `(?>`, `(?(` …
      return false
    }
    depth++
    foldLast()
    groupStack.push({ alt: 1, best: 1, last: 1 })
    canQuantify = false
    return true
  }

  while (i < length) {
    const char = source[i]
    if (char === "\\") {
      if (!parseEscape(false)) return false
      noteAtom(1)
      continue
    }
    if (char === "[") {
      if (!consumeClass()) return false
      noteAtom(1)
      continue
    }
    if (char === "]") return false
    if (char === "(") {
      if (!consumeGroup()) return false
      continue
    }
    if (char === ")") {
      if (depth <= 0 || groupStack.length <= 1) return false
      depth--
      const inner = groupStack.pop()
      ctx().last = Math.max(inner.best, inner.alt, inner.last)
      canQuantify = true
      i++
      continue
    }
    if (char === "*" || char === "+" || char === "?") {
      if (!canQuantify) return false
      i++
      if (i < length && source[i] === "?") i++
      else if (i < length && source[i] === "+") return false
      canQuantify = false
      continue
    }
    if (char === "{") {
      if (!consumeRepeat()) return false
      continue
    }
    if (char === "|") {
      const c = ctx()
      c.best = Math.max(c.best, c.alt, c.last)
      c.alt = 1
      c.last = 1
      canQuantify = false
      i++
      continue
    }
    if (char === "^" || char === "$") {
      canQuantify = false
      i++
      continue
    }
    // Ordinary literal, including UTF-16 surrogate pairs as one atom.
    if (isHighSurrogate(source.charCodeAt(i)) && i + 1 < length && isLowSurrogate(source.charCodeAt(i + 1))) {
      i += 2
    } else {
      i++
    }
    noteAtom(1)
  }
  return depth === 0 && groupStack.length === 1
}

export function sanitizePatternString(original) {
  if (typeof original !== "string") {
    return { ok: false, pattern: undefined, original }
  }
  const translated = translateUnicodeEscapes(original)
  if (isRE2Safe(translated)) {
    return { ok: true, pattern: translated, original }
  }
  return { ok: false, pattern: undefined, original }
}

// Mutates a single schema node: `pattern` and `patternProperties` keys.
// Recursion into child schemas is the caller's job (sanitizeInputSchema).
export function sanitizePatternFields(node) {
  if (!node || typeof node !== "object" || Array.isArray(node)) return node

  if (Object.hasOwn(node, "pattern")) {
    const result = sanitizePatternString(node.pattern)
    if (result.ok) {
      node.pattern = result.pattern
    } else {
      const shown = typeof result.original === "string" ? result.original : JSON.stringify(result.original)
      appendHint(node, `${HINT_PREFIX}${shown}`)
      delete node.pattern
    }
  }

  if (node.patternProperties && typeof node.patternProperties === "object" && !Array.isArray(node.patternProperties)) {
    const next = {}
    const dropped = []
    for (const [key, value] of Object.entries(node.patternProperties)) {
      const result = sanitizePatternString(key)
      if (result.ok) next[result.pattern] = value
      else dropped.push(key)
    }
    if (dropped.length) {
      appendHint(node, `dropped patternProperties: ${dropped.join(", ")}`)
    }
    if (Object.keys(next).length) {
      node.patternProperties = next
    } else {
      delete node.patternProperties
      // If every key was dropped and additionalProperties is false, the
      // object would now reject every property. Lift that so the schema
      // stays usable; the hint already records what was dropped.
      if (node.additionalProperties === false) {
        delete node.additionalProperties
        appendHint(node, "additionalProperties:false was lifted because every patternProperties key was dropped")
      }
    }
  }

  return node
}
