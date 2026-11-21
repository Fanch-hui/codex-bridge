// agy holds every MCP tool it loads into one customization budget of 20,000
// tokens, counted as ceil(UTF-8 bytes / 3). Over it, agy drops whole tools,
// the largest first, so the best-documented ones (bash, a canvas's write
// tool) vanish from the model's function list, and with `tools: []` there is
// no other way to reach them (plugins#1140). fitTools trims the tools' prose
// instead, so every tool and every bit of its schema stays: names, property
// names, types, enums, required, items, anyOf and the bounds all go as the
// client wrote them. Only descriptions are shortened, and only as far as the
// budget needs.

// What the listed tools may take of agy's 20,000: the rest is room for the
// server prefix agy adds to each name and its own serialization.
export const TOOL_TOKEN_BUDGET = 18000

const enc = new TextEncoder()
const bytes = (s) => enc.encode(s).length
export const agyTokens = (s) => Math.ceil(bytes(s) / 3)

const tokensOf = (tools) => tools.reduce((n, tool) => n + agyTokens(JSON.stringify(tool)), 0)

// Keywords that say nothing about which arguments are valid. They are taken
// out only where they are keywords: a property named "title" is the
// client's, and stays.
const DECOR = new Set(["$schema", "title", "examples"])

// A property whose description is its contract: an object with no
// properties of its own, or one whose description carries the branches
// tool-schema.mjs folded out of an anyOf/oneOf. Its text is the only place
// the model learns what goes in it, so it keeps more of it.
const CONTRACT_WEIGHT = 11
const TOOL_WEIGHT = 2.5

function isContract(node) {
  if (!node || typeof node !== "object") return false
  const d = typeof node.description === "string" ? node.description : ""
  if (/\b(Variants|Accepts anyOf):/.test(d)) return true
  const types = Array.isArray(node.type) ? node.type : [node.type]
  return types.includes("object") && !(node.properties && Object.keys(node.properties).length)
}

// cut shortens text to at most max UTF-8 bytes. It drops a trailing
// Examples block first, then ends on a sentence boundary where one is near,
// else on a whole code point, and marks the cut with "…". null when nothing
// worth keeping fits.
export function cut(text, max) {
  if (bytes(text) <= max) return text
  const bare = text.replace(/\s*\bExamples?:[\s\S]*$/i, "").trimEnd()
  if (bare && bytes(bare) <= max) return bare
  const room = max - bytes("…")
  if (room < 4) return null
  let out = ""
  let used = 0
  for (const ch of bare || text) {
    const b = bytes(ch)
    if (used + b > room) break
    out += ch
    used += b
  }
  const stop = Math.max(...[". ", "; ", "。", "；"].map((p) => out.lastIndexOf(p)))
  if (stop > out.length / 2) out = out.slice(0, stop + 1)
  return out.trimEnd() + "…"
}

// A cut text shorter than this says nothing ("The fil…") and only spends
// the budget on its key: such a description goes whole or not at all
// (plugins#1140).
export const MIN_TEXT = 24

// trim is text within max bytes: whole when it fits, else cut, else null
// when what a cut would leave is under MIN_TEXT
function trim(text, max) {
  if (bytes(text) <= max) return text
  return max < MIN_TEXT ? null : cut(text, max)
}

// walk copies one schema node with every description capped: cap(node)
// gives the byte cap for a node's description, and Infinity leaves it.
// strip takes the decorative keywords out too.
function walk(node, cap, strip) {
  if (Array.isArray(node)) return node.map((item) => walk(item, cap, strip))
  if (!node || typeof node !== "object") return node
  const out = {}
  for (const [key, value] of Object.entries(node)) {
    if (strip && DECOR.has(key)) continue
    if (key === "description" && typeof value === "string") {
      const max = cap(node)
      const text = max === Infinity ? value : trim(value, max)
      if (text) out.description = text
      continue
    }
    if ((key === "properties" || key === "$defs" || key === "definitions" || key === "patternProperties") && value && typeof value === "object" && !Array.isArray(value)) {
      // a map of names to schemas: the names are the client's, never keywords
      out[key] = Object.fromEntries(Object.entries(value).map(([name, schema]) => [name, walk(schema, cap, strip)]))
      continue
    }
    if (key === "enum" || key === "const" || key === "default" || key === "required") {
      out[key] = value
      continue
    }
    out[key] = walk(value, cap, strip)
  }
  return out
}

function shaped(tools, { strip, L, lean }) {
  // lean: an ordinary property keeps only a description short enough to
  // go whole, and the room goes to the tools' own and the contracts'
  const plain = lean ? MIN_TEXT - 1 : L
  const prop = L === undefined ? () => Infinity : (node) => (isContract(node) ? CONTRACT_WEIGHT * L : plain)
  return tools.map((tool) => {
    const out = { ...tool }
    if (tool.inputSchema && typeof tool.inputSchema === "object") out.inputSchema = walk(tool.inputSchema, prop, strip)
    if (typeof tool.description === "string") {
      const max = L === undefined ? Infinity : TOOL_WEIGHT * L
      const text = max === Infinity ? tool.description : trim(tool.description, max)
      if (text) out.description = text
      else delete out.description
    }
    return out
  })
}

// highest finds the largest whole n in [lo, hi] for which fits(n) holds,
// given that it holds at lo; fits is monotone in n.
function highest(lo, hi, fits) {
  while (lo < hi) {
    const mid = Math.ceil((lo + hi) / 2)
    if (fits(mid)) lo = mid
    else hi = mid - 1
  }
  return lo
}

// fitTools gives the tools as agy should list them: unchanged when they fit
// the budget, else with the decorative keywords gone, then with every
// description capped at the highest level that fits (a tool's own
// description gets 2.5 times a property's, a contract property's 11 times).
// When that level leaves an ordinary property less than MIN_TEXT, those
// properties keep only what goes whole, and the highest level that fits
// then goes to the tools' own descriptions and the contracts', which say
// what each tool is for and what goes in an open object. A set too large
// even with no descriptions at all goes as small as it can, and agy drops
// what is left over.
export function fitTools(tools, budget = TOOL_TOKEN_BUDGET) {
  if (tokensOf(tools) <= budget) return tools
  const stripped = shaped(tools, { strip: true })
  if (tokensOf(stripped) <= budget) return stripped
  const at = (L) => shaped(tools, { strip: true, L })
  if (tokensOf(at(0)) > budget) return at(0)
  const L = highest(0, 4000, (n) => tokensOf(at(n)) <= budget)
  if (L >= MIN_TEXT) return at(L)
  const lean = (n) => shaped(tools, { strip: true, L: n, lean: true })
  if (tokensOf(lean(0)) > budget) return at(L)
  return lean(highest(0, 4000, (n) => tokensOf(lean(n)) <= budget))
}
