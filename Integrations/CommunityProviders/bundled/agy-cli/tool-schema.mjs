// Expand JSON Schema constructs that agy's ACP -> CloudCode Schema translator
// either ignores or drops (`$ref` into `$defs`/`definitions`, `allOf`, `oneOf`,
// object/primitive `anyOf` unions, `const` discriminators, `additionalProperties`
// dictionaries, and boolean schemas), before `sanitizeInputSchema` and
// `ensureGeminiArrayItems` normalize types, RE2 patterns, and untyped arrays.
//
// Nullable unions lower to `type: [X, "null"]` (matching `sanitizeInputSchema`),
// which both agy's local JSON Schema validator and its CloudCode schema
// translator accept for null and non-null values alike.
// Local $ref/allOf/const expansion inspired by
// DylanLIiii/opencode-antigravity-bridge (MIT).

const NUMBER_BOUNDS = [
  "minimum", "maximum", "minLength", "maxLength",
  "minItems", "maxItems", "minProperties", "maxProperties",
]
const CONTAINER_MAPS = ["properties", "patternProperties", "dependentSchemas"]
const BOOLEAN_OR_SCHEMA_CHILDREN = ["additionalProperties", "unevaluatedProperties", "unevaluatedItems"]
const SCHEMA_ONLY_CHILDREN = ["propertyNames", "contains", "if", "then", "else", "not"]
const VISITED_OBJECT_KEYS = new Set([
  ...CONTAINER_MAPS,
  ...BOOLEAN_OR_SCHEMA_CHILDREN,
  ...SCHEMA_ONLY_CHILDREN,
  "prefixItems", "items", "anyOf", "oneOf",
])
// Keywords whose value is a name -> schema map: a pointer may pass through
// them but must not stop on them.
const POINTER_MAP_KEYWORDS = new Set(["properties", "patternProperties", "dependentSchemas", "$defs", "definitions"])

// Only `$ref` and `allOf` inlining is charged; ordinary traversal is free.
const MAX_INLINED_NODES = 8192
const MAX_INLINED_BYTES = 256 * 1024
const MAX_DEPTH = 64
const MAX_VARIANT_HINT_CHARS = 1600
const MAX_VARIANT_SUMMARY_CHARS = 240
const MAX_VARIANT_DESCRIPTION_CHARS = 80

const ANY_VALUE_HINT = "Accepts any JSON value."
const NO_VALUE_HINT = "No value is allowed by the original schema."
const NULL_HINT = "Must be null."
const RECURSIVE_HINT = "Recursive schema; follow the tool's original argument contract."
const LIMIT_HINT = "Schema expansion limit reached; follow the tool's original argument contract."

const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value)

function appendHint(node, hint) {
  if (!hint) return
  if (typeof node.description === "string" && node.description.trim()) {
    if (!node.description.includes(hint)) node.description = `${node.description} (${hint})`
  } else {
    node.description = hint
  }
}

function clip(text, max) {
  const flat = text.replace(/\s+/g, " ").trim()
  return flat.length > max ? `${flat.slice(0, max - 3).trimEnd()}...` : flat
}

function scalarBytes(value) {
  if (typeof value === "string") return Buffer.byteLength(value) + 2
  if (typeof value === "number" || typeof value === "boolean") return String(value).length
  return 4
}

function ownBytes(out) {
  let bytes = 2
  for (const [key, value] of Object.entries(out)) {
    if (value === undefined) continue
    bytes += Buffer.byteLength(key) + 4
    if (value === null || typeof value !== "object") {
      bytes += scalarBytes(value)
    } else if (key === "properties" || key === "patternProperties" || key === "dependentSchemas") {
      bytes += 2
      for (const mapKey of Object.keys(value)) bytes += Buffer.byteLength(mapKey) + 4
    } else if (VISITED_OBJECT_KEYS.has(key)) {
      bytes += 2
    } else if (Array.isArray(value) && value.every((item) => item === null || typeof item !== "object")) {
      bytes += 2
      for (const item of value) bytes += scalarBytes(item) + 1
    } else {
      bytes += Buffer.byteLength(JSON.stringify(value))
    }
  }
  return bytes
}

function resolvePointer(root, ref) {
  if (ref === "#") return root
  if (!ref.startsWith("#/")) return undefined
  let parts
  try {
    parts = decodeURIComponent(ref.slice(2)).split("/")
  } catch {
    return undefined
  }
  let target = root
  let inMap = false
  for (const part of parts) {
    const key = part.replace(/~1/g, "/").replace(/~0/g, "~")
    if ((!isObject(target) && !Array.isArray(target)) || !Object.hasOwn(target, key)) return undefined
    // Inside a map the key is a name (`#/properties/properties` is a schema);
    // at a schema node it is a keyword.
    const entersMap = !inMap && isObject(target) && POINTER_MAP_KEYWORDS.has(key)
    target = target[key]
    inMap = entersMap
  }
  if (inMap) return undefined
  return isObject(target) || typeof target === "boolean" ? target : undefined
}

function isNullType(type) {
  return type === "null" || (Array.isArray(type) && type.length === 1 && type[0] === "null")
}

function isNullSchema(schema) {
  if (!isObject(schema)) return false
  if (isNullType(schema.type)) return true
  // A lowered `const: null` leaf (no type, only the null hint).
  return schema.type === undefined && typeof schema.description === "string" &&
    schema.description.includes(NULL_HINT) && schema.properties === undefined &&
    schema.items === undefined && schema.enum === undefined && schema.const === undefined &&
    schema.anyOf === undefined && schema.oneOf === undefined
}

function declaresArray(schema) {
  if (!isObject(schema)) return false
  return schema.type === "array" || (Array.isArray(schema.type) && schema.type.includes("array"))
}

function isObjectBranch(schema) {
  if (!isObject(schema)) return false
  if (schema.type === "object") return true
  if (Array.isArray(schema.type) && schema.type.includes("object") &&
      schema.type.every((t) => t === "object" || t === "null")) {
    return true
  }
  if (schema.type !== undefined) return false
  return isObject(schema.properties) || Array.isArray(schema.required) ||
    schema.additionalProperties !== undefined || isObject(schema.patternProperties)
}

function primitiveTypeOf(schema) {
  if (!isObject(schema)) return null
  const raw = typeof schema.type === "string"
    ? [schema.type]
    : Array.isArray(schema.type)
      ? schema.type.filter((t) => t !== "null")
      : []
  if (raw.length !== 1) return null
  const t = raw[0]
  return (t === "string" || t === "number" || t === "integer" || t === "boolean") ? t : null
}

// Stand-in for a subtree that is not expanded (recursion, depth or budget):
// keep what kind of value it is, never invent a type it did not declare.
function structuralFallback(schema, hint) {
  const nullable = isObject(schema) && Array.isArray(schema.type) && schema.type.includes("null")
  const withNull = (t) => nullable ? [t, "null"] : t
  if (isObjectBranch(schema)) return { type: withNull("object"), description: hint }
  if (declaresArray(schema)) return { type: withNull("array"), description: hint }
  const prim = primitiveTypeOf(schema)
  if (prim) return { type: withNull(prim), description: hint }
  return { description: hint }
}

function summarizeSchema(schema, depth = 0) {
  if (!isObject(schema)) return schema === false ? "never" : "any"
  if (Array.isArray(schema.enum) && schema.enum.length) {
    const shown = schema.enum.slice(0, 12).map((v) => JSON.stringify(v)).join(" | ")
    return schema.enum.length > 12 ? `${shown} | ...` : shown
  }
  if (schema.const !== undefined) return JSON.stringify(schema.const)
  const types = Array.isArray(schema.type) ? schema.type : typeof schema.type === "string" ? [schema.type] : []
  const rawType = types.length ? types.join("|") : undefined
  const nullable = types.includes("null")
  const nonNullTypes = types.filter((t) => t !== "null")
  if ((!rawType || (nonNullTypes.length === 1 && nonNullTypes[0] === "object")) && isObject(schema.properties)) {
    if (depth >= 2) return rawType || "object"
    const req = new Set(Array.isArray(schema.required) ? schema.required : [])
    const entries = Object.entries(schema.properties)
    const shown = entries.slice(0, 8).map(([k, v]) => `${k}${req.has(k) ? "" : "?"}: ${summarizeSchema(v, depth + 1)}`)
    if (entries.length > 8) shown.push("...")
    const body = `{ ${shown.join(", ")} }`
    return nullable ? `${body} | null` : body
  }
  if ((!rawType || rawType === "object") && Array.isArray(schema.required) && schema.required.length) {
    return `{ required: [${schema.required.join(", ")}] }`
  }
  if ((nonNullTypes.length === 1 && nonNullTypes[0] === "array") || (!rawType && isObject(schema.items))) {
    if (depth >= 2 || !isObject(schema.items)) return rawType || "array"
    const body = `array<${summarizeSchema(schema.items, depth + 1)}>`
    return nullable ? `${body} | null` : body
  }
  const combo = Array.isArray(schema.anyOf) ? schema.anyOf : Array.isArray(schema.oneOf) ? schema.oneOf : null
  if (combo && combo.length) {
    if (depth >= 2) return "union"
    const shown = combo.slice(0, 6).map((b) => summarizeSchema(b, depth + 1)).join(" | ")
    return combo.length > 6 ? `${shown} | ...` : shown
  }
  return rawType || "any"
}

function typeList(type) {
  if (typeof type === "string") return [type]
  if (Array.isArray(type)) return type.filter((t) => typeof t === "string")
  return null
}

function intersectTypes(a, b) {
  const left = typeList(a)
  const right = typeList(b)
  if (!left || !left.length) return { type: b }
  if (!right || !right.length) return { type: a }
  const common = new Set()
  for (const t of left) {
    if (right.includes(t)) common.add(t)
    else if ((t === "number" && right.includes("integer")) || (t === "integer" && right.includes("number"))) {
      common.add("integer")
    }
  }
  if (!common.size) return { type: a, conflict: true }
  const nonNull = [...common].filter((t) => t !== "null")
  const list = common.has("null") ? [...nonNull, "null"] : nonNull
  return { type: list.length === 1 ? list[0] : list }
}

function intersectSchemas(schemas) {
  const meaningful = schemas.filter((schema) => isObject(schema) && Object.keys(schema).length)
  if (!meaningful.length) return {}
  if (meaningful.length === 1) return { ...meaningful[0] }
  const out = { ...meaningful[0] }
  const conflicts = []
  for (const schema of meaningful.slice(1)) {
    appendHint(out, schema.description)
    for (const [key, value] of Object.entries(schema)) {
      if (key === "description" || key === "properties" || key === "required" || key === "items" ||
          key === "enum" || key === "type" || NUMBER_BOUNDS.includes(key)) continue
      if (out[key] === undefined) out[key] = value
    }
    if (schema.type !== undefined) {
      const merged = intersectTypes(out.type, schema.type)
      if (merged.conflict) conflicts.push(`${typeList(out.type).join("|")} vs ${typeList(schema.type).join("|")}`)
      out.type = merged.type
    }
  }
  for (const conflict of conflicts) appendHint(out, `Conflicting type constraints in allOf: ${conflict}.`)
  const objects = meaningful.filter((schema) => isObject(schema.properties))
  if (objects.length) {
    const keys = [...new Set(objects.flatMap((schema) => Object.keys(schema.properties)))]
    out.properties = Object.fromEntries(keys.map((key) => [
      key,
      intersectSchemas(objects.filter((schema) => Object.hasOwn(schema.properties, key)).map((schema) => schema.properties[key])),
    ]))
    out.type ??= "object"
  }
  const reqKeys = [...new Set(meaningful.flatMap((schema) => Array.isArray(schema.required) ? schema.required : []))]
  if (reqKeys.length) {
    out.required = reqKeys
    out.type ??= "object"
  }
  const arrays = meaningful.filter((schema) => isObject(schema.items))
  if (arrays.length) {
    out.items = intersectSchemas(arrays.map((schema) => schema.items))
    out.type ??= "array"
  }
  for (const key of NUMBER_BOUNDS) {
    const values = meaningful.map((schema) => schema[key]).filter((v) => typeof v === "number" && Number.isFinite(v))
    if (!values.length) continue
    const lower = key === "minimum" || key.startsWith("min")
    out[key] = (lower ? Math.max : Math.min)(...values)
  }
  const enums = meaningful.filter((schema) => Array.isArray(schema.enum))
  if (enums.length) {
    const first = enums[0].enum
    const common = first.filter((value) => enums.every((schema) => schema.enum.includes(value)))
    if (common.length) {
      out.enum = [...new Set(common)]
    } else {
      delete out.enum
      appendHint(out, "Conflicting enum constraints in allOf.")
    }
  }
  return out
}

function primitiveFamily(nonNull) {
  const types = new Set()
  for (const branch of nonNull) {
    const t = primitiveTypeOf(branch)
    if (!t) return null
    types.add(t)
  }
  if (types.size === 1) return [...types][0]
  if (types.size === 2 && types.has("number") && types.has("integer")) return "number"
  return null
}

function branchLiterals(branch) {
  if (Array.isArray(branch.enum) && branch.enum.length > 0) return branch.enum
  if (branch.const !== undefined && branch.const !== null) return [branch.const]
  return null
}

function unionPrimitiveBranches(nonNull, family, hasNull) {
  const out = { type: hasNull ? [family, "null"] : family }
  const descriptions = [...new Set(
    nonNull.map((b) => typeof b.description === "string" ? b.description.trim() : "").filter(Boolean),
  )]
  if (descriptions.length) out.description = descriptions.slice(0, 3).join("; ")

  // A `const` is a one-value enum. sanitizeInputSchema keeps non-empty string
  // enums and turns numeric, boolean, or null-bearing ones into an "Allowed values" hint.
  const literals = nonNull.map(branchLiterals)
  if (literals.every(Boolean)) {
    const values = [...new Set(literals.flat().filter((v) => v !== null))]
    out.enum = hasNull ? [...values, null] : values
  } else if (literals.some(Boolean)) {
    const known = [...new Set(literals.filter(Boolean).flat())].slice(0, 12).map((v) => JSON.stringify(v)).join(", ")
    appendHint(out, `Known values include: ${known}`)
  }

  for (const key of NUMBER_BOUNDS) {
    if (!nonNull.every((b) => typeof b[key] === "number" && Number.isFinite(b[key]))) continue
    const values = nonNull.map((b) => b[key])
    const lower = key === "minimum" || key.startsWith("min")
    out[key] = (lower ? Math.min : Math.max)(...values)
  }
  const formats = [...new Set(nonNull.map((b) => b.format).filter((f) => typeof f === "string" && f))]
  if (formats.length === 1 && nonNull.every((b) => b.format === formats[0])) out.format = formats[0]
  const patterns = [...new Set(nonNull.map((b) => b.pattern).filter((p) => typeof p === "string" && p))]
  if (patterns.length === 1 && nonNull.every((b) => b.pattern === patterns[0])) out.pattern = patterns[0]

  return out
}

function unionPropertySchemas(schemas) {
  const meaningful = schemas.filter(isObject)
  if (!meaningful.length) return {}
  if (meaningful.length === 1) return { ...meaningful[0] }
  const nonNull = meaningful.filter((b) => !isNullSchema(b))
  const hasNull = nonNull.length < meaningful.length ||
    meaningful.some((b) => Array.isArray(b.type) && b.type.includes("null"))
  if (!nonNull.length) return { description: NULL_HINT }
  if (nonNull.every(isObjectBranch)) return unionObjectBranches(nonNull, hasNull)
  const family = primitiveFamily(nonNull)
  if (family) return unionPrimitiveBranches(nonNull, family, hasNull)
  return {
    anyOf: meaningful,
    description: `Accepts anyOf: ${meaningful.map((b) => summarizeSchema(b)).join(" | ")}`,
  }
}

function variantsHint(branches) {
  const parts = []
  let length = 0
  for (let i = 0; i < branches.length; i++) {
    const branch = branches[i]
    let part = clip(summarizeSchema(branch, 1), MAX_VARIANT_SUMMARY_CHARS)
    if (typeof branch.description === "string" && branch.description.trim()) {
      part += ` (${clip(branch.description, MAX_VARIANT_DESCRIPTION_CHARS)})`
    }
    if (parts.length && length + part.length + 3 > MAX_VARIANT_HINT_CHARS) {
      parts.push(`... (+${branches.length - i} more)`)
      break
    }
    parts.push(part)
    length += part.length + 3
  }
  return `Variants: ${parts.join(" | ")}`
}

function unionObjectBranches(nonNull, hasNull) {
  const out = { type: hasNull ? ["object", "null"] : "object" }
  if (nonNull.length === 1 && typeof nonNull[0].description === "string" && nonNull[0].description.trim()) {
    out.description = nonNull[0].description
  }
  const propKeys = [...new Set(nonNull.flatMap((b) => isObject(b.properties) ? Object.keys(b.properties) : []))]
  if (propKeys.length) {
    out.properties = Object.fromEntries(propKeys.map((key) => [
      key,
      unionPropertySchemas(
        nonNull.filter((b) => isObject(b.properties) && Object.hasOwn(b.properties, key)).map((b) => b.properties[key]),
      ),
    ]))
  }
  const reqSets = nonNull.map((b) => new Set(Array.isArray(b.required) ? b.required : []))
  const commonReq = [...reqSets[0]].filter((key) => reqSets.every((set) => set.has(key)))
  if (commonReq.length) out.required = commonReq

  if (nonNull.some((b) => b.additionalProperties === true)) {
    out.additionalProperties = true
  } else if (nonNull.some((b) => isObject(b.additionalProperties))) {
    out.additionalProperties = unionPropertySchemas(
      nonNull.filter((b) => isObject(b.additionalProperties)).map((b) => b.additionalProperties),
    )
  } else if (nonNull.every((b) => b.additionalProperties === false)) {
    out.additionalProperties = false
  }

  if (nonNull.length > 1) appendHint(out, variantsHint(nonNull))
  return out
}

function lowerUnionKey(out, key) {
  const branches = out[key]
  if (!Array.isArray(branches)) return out
  if (!branches.length) {
    delete out[key]
    return out
  }
  const nonNull = branches.filter((b) => !isNullSchema(b))
  const hasNull = nonNull.length < branches.length ||
    branches.some((b) => Array.isArray(b?.type) && b.type.includes("null"))

  if (!nonNull.length) {
    delete out[key]
    if (isNullType(out.type)) delete out.type
    appendHint(out, NULL_HINT)
    return out
  }

  // Leave array-bearing combinators intact so `ensureGeminiArrayItems` can lift
  // item schemas without narrowing `string | string[]` or `array | null`.
  if (declaresArray(out) || nonNull.some(declaresArray)) {
    if (key === "oneOf") {
      out.anyOf = Array.isArray(out.anyOf) ? [...out.anyOf, ...branches] : branches
      delete out.oneOf
    }
    if (!declaresArray(out)) {
      appendHint(out, `Accepts anyOf: ${branches.map((b) => summarizeSchema(b)).join(" | ")}`)
    }
    return out
  }

  if (nonNull.every(isObjectBranch)) {
    const rest = { ...out }
    delete rest[key]
    return intersectSchemas([rest, unionObjectBranches(nonNull, hasNull)])
  }

  const family = primitiveFamily(nonNull)
  if (family) {
    const rest = { ...out }
    delete rest[key]
    return intersectSchemas([rest, unionPrimitiveBranches(nonNull, family, hasNull)])
  }

  if (key === "oneOf") {
    out.anyOf = Array.isArray(out.anyOf) ? [...out.anyOf, ...branches] : branches
    delete out.oneOf
  }
  appendHint(out, `Accepts anyOf: ${branches.map((b) => summarizeSchema(b)).join(" | ")}`)
  return out
}

function constConflict(out) {
  if (!Array.isArray(out.enum)) return
  if (!out.enum.includes(out.const)) {
    appendHint(out, `Conflicting const and enum constraints; const is ${JSON.stringify(out.const)}.`)
  }
  delete out.enum
}

// `const` on a leaf. Non-empty strings become a one-value enum; `""`, numbers,
// booleans, objects and arrays keep `const` (sanitizeInputSchema turns it into
// a "Must equal" hint) and get the matching type.
function lowerConst(out) {
  const value = out.const
  if (value === null) {
    delete out.const
    if (isNullType(out.type)) delete out.type
    appendHint(out, NULL_HINT)
    return
  }
  if (typeof value === "string") {
    const types = typeList(out.type)
    if (types && !types.every((t) => t === "string" || t === "null")) return
    // `const` already excludes null, so a nullable string type narrows to string.
    out.type = "string"
    if (!value.length) {
      constConflict(out)
      return
    }
    if (Array.isArray(out.enum) && !out.enum.includes(value)) {
      appendHint(out, `Conflicting const and enum constraints; const is ${JSON.stringify(value)}.`)
    }
    out.enum = [value]
    delete out.const
    return
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    out.type ??= Number.isInteger(value) ? "integer" : "number"
    constConflict(out)
  } else if (typeof value === "boolean") {
    out.type ??= "boolean"
    constConflict(out)
  } else if (Array.isArray(value)) {
    out.type ??= "array"
  } else if (isObject(value)) {
    out.type ??= "object"
  }
}

export function expandToolSchema(root) {
  if (!isObject(root)) return root

  // Cycle-free `$ref` targets are expanded once and deep-cloned on reuse.
  const cache = new Map()
  let produced = 0 // schema objects emitted, including cached copies
  let producedBytes = 0 // estimated JSON bytes emitted, including cached copies
  let inlined = 0 // of those, nodes emitted through $ref / allOf expansion
  let inlinedBytes = 0 // of those, bytes emitted through $ref / allOf expansion
  let limits = 0 // recursion / depth / budget fallbacks emitted
  let deepest = 0

  function limit(schema, hint) {
    const out = structuralFallback(schema, hint)
    limits++
    produced++
    producedBytes += ownBytes(out)
    return out
  }

  function measure(inlineDepth, fn) {
    const start = { produced, producedBytes, inlined, inlinedBytes, limits, deepest }
    deepest = inlineDepth
    const schema = fn()
    const result = {
      schema,
      weight: produced - start.produced,
      bytes: producedBytes - start.producedBytes,
      nested: inlined - start.inlined,
      nestedBytes: inlinedBytes - start.inlinedBytes,
      limited: limits !== start.limits,
      height: deepest - inlineDepth,
    }
    deepest = Math.max(start.deepest, deepest)
    // Charge only what nested expansions have not charged already.
    inlined += Math.max(0, result.weight - result.nested)
    inlinedBytes += Math.max(0, result.bytes - result.nestedBytes)
    return result
  }

  function expandRef(target, inlineDepth, active) {
    if (typeof target === "boolean") return visit(target, inlineDepth, active)
    if (inlined >= MAX_INLINED_NODES || inlinedBytes >= MAX_INLINED_BYTES) return limit(target, LIMIT_HINT)
    const hit = cache.get(target)
    if (hit && inlineDepth + hit.height <= MAX_DEPTH) {
      if (inlined + hit.weight > MAX_INLINED_NODES || inlinedBytes + hit.bytes > MAX_INLINED_BYTES) {
        return limit(target, LIMIT_HINT)
      }
      produced += hit.weight
      inlined += hit.weight
      producedBytes += hit.bytes
      inlinedBytes += hit.bytes
      deepest = Math.max(deepest, inlineDepth + hit.height)
      return structuredClone(hit.schema)
    }
    const result = measure(inlineDepth, () => visit(target, inlineDepth, active))
    if (!result.limited) {
      cache.set(target, {
        schema: structuredClone(result.schema),
        weight: result.weight,
        bytes: result.bytes,
        height: result.height,
      })
    }
    return result.schema
  }

  function visit(schema, inlineDepth, active) {
    deepest = Math.max(deepest, inlineDepth)
    if (!isObject(schema)) {
      const out = { description: schema === false ? NO_VALUE_HINT : ANY_VALUE_HINT }
      produced++
      producedBytes += ownBytes(out)
      return out
    }
    if (active.has(schema)) return limit(schema, RECURSIVE_HINT)
    if (inlineDepth > MAX_DEPTH) return limit(schema, LIMIT_HINT)
    produced++
    const nextActive = new Set(active).add(schema)
    const child = (value) => visit(value, inlineDepth, nextActive)

    let out = {}
    for (const [key, value] of Object.entries(schema)) {
      if (key === "$defs" || key === "definitions" || key === "$schema" || key === "$id" ||
          key === "$ref" || key === "allOf") continue
      out[key] = value
    }

    if (out.const !== undefined) lowerConst(out)

    for (const mapKey of CONTAINER_MAPS) {
      if (isObject(out[mapKey])) {
        out[mapKey] = Object.fromEntries(Object.entries(out[mapKey]).map(([k, v]) => [k, child(v)]))
      }
    }
    for (const childKey of BOOLEAN_OR_SCHEMA_CHILDREN) {
      if (isObject(out[childKey])) {
        out[childKey] = child(out[childKey])
      }
    }
    for (const childKey of SCHEMA_ONLY_CHILDREN) {
      if (out[childKey] !== undefined && (isObject(out[childKey]) || typeof out[childKey] === "boolean")) {
        out[childKey] = child(out[childKey])
      }
    }
    if (Array.isArray(out.prefixItems)) {
      out.prefixItems = out.prefixItems.map((item) => child(item))
    }
    if (Array.isArray(out.items)) {
      out.items = out.items.map((item) => child(item))
    } else if (isObject(out.items)) {
      out.items = child(out.items)
    } else if (out.items === false) {
      if (Array.isArray(out.prefixItems) && out.prefixItems.length > 0) {
        // A closed tuple. agy ignores prefixItems, so give it the element
        // union and the tuple length instead of forbidding every element.
        const length = out.prefixItems.length
        out.maxItems = typeof out.maxItems === "number" ? Math.min(out.maxItems, length) : length
        out.items = structuredClone(unionPropertySchemas(out.prefixItems))
      } else {
        out.maxItems = 0
        out.items = { type: "string", description: NO_VALUE_HINT }
      }
    }
    for (const key of ["anyOf", "oneOf"]) {
      if (Array.isArray(out[key])) out[key] = out[key].map((branch) => child(branch))
    }

    if (typeof schema.$ref === "string") {
      const target = resolvePointer(root, schema.$ref)
      if (target !== undefined) {
        out = intersectSchemas([out, expandRef(target, inlineDepth + 1, nextActive)])
      } else {
        appendHint(out, `Unresolved schema reference: ${schema.$ref}`)
      }
    }

    if (Array.isArray(schema.allOf) && schema.allOf.length) {
      const branches = schema.allOf.map((branch) => {
        if (inlined >= MAX_INLINED_NODES || inlinedBytes >= MAX_INLINED_BYTES) {
          return limit(branch, LIMIT_HINT)
        }
        return measure(inlineDepth + 1, () => visit(branch, inlineDepth + 1, nextActive)).schema
      })
      out = intersectSchemas([out, ...branches])
    }

    out = lowerUnionKey(out, "oneOf")
    out = lowerUnionKey(out, "anyOf")

    if (out.additionalProperties === true) {
      appendHint(out, "Accepts arbitrary additional key-value properties.")
    } else if (isObject(out.additionalProperties)) {
      appendHint(out, `Additional properties: ${summarizeSchema(out.additionalProperties)}`)
    }
    if (isObject(out.patternProperties) && Object.keys(out.patternProperties).length > 0) {
      const shown = Object.entries(out.patternProperties).slice(0, 6).map(([pat, val]) => `${pat}: ${summarizeSchema(val)}`)
      appendHint(out, `Pattern properties: ${shown.join(", ")}`)
    }

    producedBytes += ownBytes(out)
    return out
  }

  return visit(root, 0, new Set())
}
