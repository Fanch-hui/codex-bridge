// The OpenCode 2.x face of a package whose plugins are written for
// OpenCode 1.x (and magpie's plugin host).
//
// OpenCode 2.x loads a package's `exports["."]` and wants its default to be
// {id, setup(ctx)}; it has no fallback for a 1.x plugin's named functions
// (plugins#657). This file is that default. It runs each 1.x plugin the
// package's opencode.mjs exports and hands 2.x what the plugin's hooks say:
//
//   auth.methods     → the integration's sign-in methods
//   config()         → the provider, its package, base URL and models
//   provider.models  → the signed-in account's own model list
//   auth.loader      → each request's base URL, key, headers and fetch
//
// What 2.x has no place for is left out: chat.headers and chat.params
// (2.x's sdk hook doesn't carry the session), magpie's usage and checkin,
// tools and events.
//
// scripts/opencode2.mjs is the one copy that is edited. Every package that
// has it carries the same bytes as packages/<name>/opencode2.mjs, and
// scripts/check.mjs fails when a copy differs.

import { readFileSync } from "node:fs"
import * as v1 from "./opencode.mjs"

const pkg = JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8"))

// The key the SDK is made with: the account's own goes on each request in
// its place (see wrapFetch), so a key read when the SDK was made can't go
// out after the account changed.
const PLACEHOLDER = "opencode2-v1-key"

// The SDK package a 1.x npm name runs as on 2.x. A version keeps 2.x from
// swapping @ai-sdk/* for its native providers, which never call the sdk
// hook below; openai-compatible's is the one 2.x ships, the others are AI
// SDK v6's dist-tag, the line 2.x's bridge runs.
export function packageOf(npm) {
  const name = npm || "@ai-sdk/openai-compatible"
  if (name === "@ai-sdk/openai-compatible") return "aisdk:@ai-sdk/openai-compatible@2.0.41"
  if (/^@ai-sdk\/[^/@]+$/.test(name)) return `aisdk:${name}@ai-v6`
  return `aisdk:${name}`
}

// The plugins a 1.x module exports, as magpie's host and OpenCode 1.x read
// them: a default {server} is the one plugin, else every function export
// and every {server} object.
export function pluginsOf(mod) {
  const d = mod?.default
  if (d && typeof d === "object" && ("server" in d || "id" in d || "tui" in d))
    return typeof d.server === "function" ? [d.server] : []
  const out = []
  for (const value of Object.values(mod ?? {})) {
    const fn = typeof value === "function" ? value : value && typeof value === "object" && typeof value.server === "function" ? value.server : null
    if (fn && !out.includes(fn)) out.push(fn)
  }
  return out
}

const int = (n, fallback = 0) => {
  const v = Math.trunc(Number(n))
  return Number.isFinite(v) && v >= 0 ? v : fallback
}
const money = (n) => (Number.isFinite(Number(n)) && Number(n) >= 0 ? Number(n) : 0)
const record = (v) => (v && typeof v === "object" && !Array.isArray(v) ? v : {})
const json = (v) => {
  try {
    return JSON.parse(JSON.stringify(v ?? null))
  } catch {
    return null
  }
}
const strings = (v) => Object.fromEntries(Object.entries(record(v)).filter(([, s]) => typeof s === "string"))
const nonEmpty = (o) => (Object.keys(o).length ? o : undefined)

// connKey names a connection the way 2.x does.
const connKey = (c) => (!c ? "" : c.type === "credential" ? `credential:${c.id}` : `env:${c.name}`)

// ---- sign-in ------------------------------------------------------------

// fields is a 1.x method's prompts as a 2.x form.
export function fieldsOf(prompts) {
  const out = []
  for (const p of prompts ?? []) {
    if (!p?.key) continue
    const f = { key: String(p.key), type: "string", title: String(p.message ?? p.key) }
    if (p.placeholder) f.placeholder = String(p.placeholder)
    if (p.type === "select" && Array.isArray(p.options))
      f.options = p.options.map((o) => ({ value: String(o.value), label: String(o.label ?? o.value), ...(o.hint ? { description: String(o.hint) } : {}) }))
    // a prompt shown only when another answer says so can't be required, and
    // neither can one whose own validate() accepts an empty answer (the
    // browser sign-in's optional API key)
    if (!p.condition && p.required !== false) f.required = true
    out.push(f)
  }
  return out.length ? out : undefined
}

// v1Saved is what a 1.x sign-in's success is saved as, the way 1.x writes
// auth.json: the result without its type and provider.
function v1Saved(r) {
  const { type: _t, provider: _p, ...rest } = r
  if ("key" in r) return { type: "api", ...rest }
  return { type: "oauth", ...rest }
}

// credentialOf is a 1.x sign-in's success as a 2.x credential: OAuth for
// both kinds, the 1.x auth kept whole in its metadata. No refresh is
// registered, so 2.x hands the credential over as it is and the plugin's
// own loader renews it, as it does on 1.x.
export function credentialOf(methodID, r) {
  if (!r || r.type !== "success") throw new Error(r?.error || r?.message || "the sign-in failed")
  const saved = json(v1Saved(r))
  if (saved.type === "api")
    return { type: "oauth", methodID, access: String(saved.key ?? ""), refresh: "", expires: 0, metadata: { v1: saved } }
  return {
    type: "oauth",
    methodID,
    access: String(saved.access ?? ""),
    refresh: String(saved.refresh ?? ""),
    expires: int(saved.expires),
    metadata: { v1: saved },
  }
}

// authOfValue is the 1.x auth a 2.x credential stands for.
export function authOfValue(value) {
  if (!value) return null
  if (value.type === "oauth") {
    const v1 = record(value.metadata).v1
    if (v1 && typeof v1 === "object") return v1
    return { type: "oauth", access: value.access, refresh: value.refresh, expires: value.expires }
  }
  if (value.type === "key") {
    const meta = value.metadata && Object.keys(value.metadata).length ? { metadata: value.metadata } : {}
    return { type: "api", key: value.key, ...meta }
  }
  return null
}

const fingerprint = (a) => JSON.stringify([a?.type, a?.access ?? a?.key ?? "", a?.refresh ?? ""])

// ---- models -------------------------------------------------------------

const MODALITIES = ["text", "audio", "image", "video", "pdf"]

// internalOf is a config model as 1.x hands it to provider.models: what
// fromModelsDevModel makes of it, with the config's own variants.
export function internalOf(providerID, conf, key, m) {
  const mods = record(m.modalities)
  const has = (list, k) => Array.isArray(list) && list.includes(k)
  const cost = record(m.cost)
  return {
    ...m,
    id: key,
    providerID,
    name: m.name ?? key,
    api: { id: m.id ?? key, url: m.provider?.api ?? conf.api ?? conf.options?.baseURL ?? "", npm: m.provider?.npm ?? conf.npm ?? "@ai-sdk/openai-compatible" },
    status: m.status ?? "active",
    headers: m.headers ?? {},
    options: m.options ?? {},
    cost: { input: money(cost.input), output: money(cost.output), cache: { read: money(cost.cache_read), write: money(cost.cache_write) } },
    limit: { context: int(m.limit?.context), input: m.limit?.input, output: int(m.limit?.output) },
    capabilities: {
      temperature: m.temperature ?? false,
      reasoning: m.reasoning ?? false,
      attachment: m.attachment ?? false,
      toolcall: m.tool_call ?? true,
      input: Object.fromEntries(MODALITIES.map((k) => [k, mods.input ? has(mods.input, k) : k === "text"])),
      output: Object.fromEntries(MODALITIES.map((k) => [k, mods.output ? has(mods.output, k) : k === "text"])),
      interleaved: m.interleaved ?? false,
    },
    release_date: m.release_date ?? "",
    variants: record(m.variants),
  }
}

// modelOf is a 1.x model, in config or internal form, as a 2.x Model.Info.
export function modelOf(providerID, provider, key, m) {
  const caps = record(m.capabilities)
  const listFrom = (obj, list) => {
    if (obj && typeof obj === "object") return MODALITIES.filter((k) => obj[k])
    if (Array.isArray(list)) return list.map(String)
    return ["text"]
  }
  const input = listFrom(caps.input, m.modalities?.input)
  const output = listFrom(caps.output, m.modalities?.output)
  const c = record(m.cost)
  const cache = record(c.cache)
  const npm = m.api?.npm ?? m.provider?.npm
  const url = m.api?.url ?? m.provider?.api
  const settings = { ...record(json(m.options)) }
  if (url && url !== provider.baseURL) settings.baseURL = url
  const variants = Object.entries(record(m.variants))
    .filter(([, v]) => !record(v).disabled)
    .map(([id, v]) => {
      const { disabled: _d, ...rest } = record(json(v))
      return nonEmpty(rest) ? { id, settings: rest } : { id }
    })
  const status = ["alpha", "beta", "deprecated", "active"].includes(m.status) ? m.status : "active"
  const out = {
    id: key,
    modelID: String(m.api?.id ?? m.id ?? key),
    providerID,
    name: String(m.name ?? key),
    capabilities: {
      tools: caps.toolcall ?? m.tool_call ?? true,
      input: input.length ? input : ["text"],
      output: output.length ? output : ["text"],
      ...(typeof (caps.temperature ?? m.temperature) === "boolean" ? { temperature: caps.temperature ?? m.temperature } : {}),
    },
    variants,
    time: { released: Date.parse(m.release_date ?? "") || 0 },
    cost: [{ input: money(c.input), output: money(c.output), cache: { read: money(cache.read ?? c.cache_read), write: money(cache.write ?? c.cache_write) } }],
    status,
    enabled: true,
    limit: { context: int(m.limit?.context, 128000) || 128000, output: int(m.limit?.output, 8192) || 8192 },
  }
  if (m.limit?.input) out.limit.input = int(m.limit.input)
  if (npm && npm !== provider.npm) out.package = packageOf(npm)
  if (nonEmpty(settings)) out.settings = settings
  const headers = strings(m.headers)
  if (nonEmpty(headers)) out.headers = headers
  return out
}

// ---- requests -----------------------------------------------------------

const urlOf = (input) => (typeof input === "string" ? input : input instanceof URL ? input.href : input?.url ?? String(input))

// wrapFetch sends a request the SDK made from the provider's settings the
// way 1.x would have sent it with the loader's options: the loader's base
// URL in place of the configured one, the account's key in place of the
// placeholder, the loader's headers added, through the loader's fetch.
export function wrapFetch(next, base, options) {
  return async (input, init = {}) => {
    const o = await options()
    let url = urlOf(input)
    const from = String(base ?? "").replace(/\/+$/, "")
    const to = o.baseURL ? String(o.baseURL).replace(/\/+$/, "") : ""
    if (from && to && from !== to && url.startsWith(from)) url = to + url.slice(from.length)
    const req = input instanceof Request ? input : null
    const headers = new Headers(init.headers ?? req?.headers ?? undefined)
    for (const [k, v] of [...headers.entries()]) {
      if (!v.includes(PLACEHOLDER)) continue
      if (o.key) headers.set(k, v.replaceAll(PLACEHOLDER, o.key))
      else headers.delete(k)
    }
    for (const [k, v] of Object.entries(strings(o.headers))) headers.set(k, v)
    const send = typeof o.fetch === "function" ? o.fetch : next ?? fetch
    if (req && init.body === undefined) {
      const body = req.method === "GET" || req.method === "HEAD" ? undefined : await req.text()
      return send(url, { method: req.method, headers, body, signal: init.signal ?? req.signal })
    }
    return send(url, { ...init, headers })
  }
}

// ---- one plugin ---------------------------------------------------------

async function setupPlugin(ctx, fn, live) {
  const directory = ctx?.location?.directory ?? process.cwd()
  // the active account each provider was last read for, and the renewed
  // auth a plugin saved for it (2.x has no way for a plugin to write a
  // credential back, so it is kept in the plugin's storage, under the
  // credential it renews and the token it was renewed from)
  const current = new Map()
  const saved = new Map()
  const signingIn = new Map()
  const storeKey = (id, key) => `v1auth/${id}/${key}`

  const client = {
    auth: {
      async set(arg) {
        const id = arg?.path?.id
        const body = json(arg?.body)
        const cur = id && current.get(id)
        // a sign-in's own saves belong to the credential it is about to
        // make, not the one that was active when it started
        if (!cur || !body || signingIn.get(id) > 0) return { data: true }
        const entry = { fp: cur.fp, auth: body }
        saved.set(storeKey(id, cur.key), entry)
        await Promise.resolve()
          .then(() => ctx.storage?.set?.(storeKey(id, cur.key), entry))
          .catch(() => {})
        return { data: true }
      },
      async get() {
        return { data: undefined }
      },
    },
    app: { log: async () => ({ data: true }) },
  }

  const hooks = (await fn({ client, directory, worktree: directory, project: {}, serverUrl: undefined, $: undefined }, {})) ?? {}
  const cfg = { provider: {} }
  try {
    await hooks.config?.(cfg)
  } catch {}
  const auth = hooks.auth
  const authID = auth?.provider ? String(auth.provider) : undefined
  const providers = record(cfg.provider)

  // getAuth reads the active account: the credential 2.x holds, or what the
  // plugin last saved renewing it.
  const getAuth = async (id) => {
    const connection = await ctx.integration.connection.active(id).catch(() => undefined)
    if (!connection) {
      current.delete(id)
      return undefined
    }
    const value = await ctx.integration.connection.resolve(connection).catch(() => undefined)
    const base = authOfValue(value)
    if (!base) {
      current.delete(id)
      return undefined
    }
    const key = connKey(connection)
    const fp = fingerprint(base)
    // ours: a credential one of this plugin's own sign-ins made
    const ours = value?.type === "oauth" && !!record(value.metadata).v1
    current.set(id, { key, fp, ours })
    const sk = storeKey(id, key)
    let entry = saved.get(sk)
    if (!entry) {
      entry = await Promise.resolve()
        .then(() => ctx.storage?.get?.(sk))
        .catch(() => undefined)
      if (entry) saved.set(sk, entry)
    }
    return entry && entry.fp === fp && entry.auth ? entry.auth : base
  }

  // the sign-in methods
  if (authID && Array.isArray(auth.methods) && auth.methods.length) {
    const label = (c) => {
      const a = authOfValue(c)
      const name = a?.name ?? a?.email ?? a?.metadata?.name ?? a?.metadata?.email ?? a?.account
      return typeof name === "string" && name ? name : undefined
    }
    const begin = () => signingIn.set(authID, (signingIn.get(authID) ?? 0) + 1)
    const end = () => signingIn.set(authID, Math.max(0, (signingIn.get(authID) ?? 1) - 1))
    const title = record(providers[authID]).name
    // 2.x runs a transform again on every reload, from nothing
    await ctx.integration.transform((editor) => {
      let keyed = false
      // the integration 2.x makes for an id it doesn't know is named by the
      // id; the provider's own name reads better in the sign-in list
      if (typeof title === "string" && title)
        try {
          editor.update?.(authID, (i) => {
            if (i && (!i.name || i.name === authID)) i.name = title
          })
        } catch {}
      auth.methods.forEach((m, i) => {
        if (!m) return
        const methodID = `v1-${i}`
        const form = fieldsOf(m.prompts)
        if (m.type === "api" && typeof m.authorize !== "function") {
          if (keyed) return
          keyed = true
          editor.method.update({ integrationID: authID, method: { type: "key", label: String(m.label ?? "API key"), ...(form ? { form } : {}) } })
          return
        }
        if (typeof m.authorize !== "function") return
        editor.method.update({
          integrationID: authID,
          method: { id: methodID, type: "oauth", label: String(m.label ?? authID), ...(form ? { form } : {}) },
          async authorize(answer) {
            begin()
            let ended = false
            const done = () => {
              if (!ended) end()
              ended = true
            }
            try {
              const inputs = Object.fromEntries(Object.entries(record(answer)).map(([k, v]) => [k, String(v)]))
              const r = await m.authorize(inputs)
              if (m.type === "api") {
                done()
                return { url: "", instructions: "", mode: "auto", callback: Promise.resolve().then(() => credentialOf(methodID, r)) }
              }
              if (r?.method === "code")
                return {
                  url: String(r.url ?? ""),
                  instructions: String(r.instructions ?? ""),
                  mode: "code",
                  callback: async (code) => {
                    try {
                      return credentialOf(methodID, await r.callback(code))
                    } finally {
                      done()
                    }
                  },
                }
              const callback = Promise.resolve()
                .then(() => r.callback())
                .then((res) => credentialOf(methodID, res))
                .finally(done)
              callback.catch(() => {})
              return { url: String(r?.url ?? ""), instructions: String(r?.instructions ?? ""), mode: "auto", callback }
            } catch (e) {
              done()
              throw e
            }
          },
          label,
        })
      })
    })
  }

  // the loader's options for the account signed in now, read again when
  // the account changes
  let loaded = null
  const loaderOptions = async (id) => {
    if (id !== authID || typeof auth?.loader !== "function") {
      const a = authID === id ? await getAuth(id) : undefined
      return { key: a?.type === "api" ? a.key : undefined }
    }
    const a = await getAuth(id)
    if (!a) return {}
    const fp = current.get(id)?.key + "\0" + fingerprint(a)
    if (loaded?.fp !== fp) {
      const p = Promise.resolve()
        .then(() => auth.loader(() => getAuth(id), providerOf(id)))
        .then((o) => record(o))
      loaded = { fp, p }
      p.catch(() => {
        if (loaded?.fp === fp) loaded = null
      })
    }
    const o = await loaded.p
    const key = typeof o.apiKey === "string" && o.apiKey ? o.apiKey : a.type === "api" ? a.key : undefined
    return { baseURL: o.baseURL, key, headers: o.headers, fetch: o.fetch }
  }

  // the providers, with the list the account's own read last gave each
  const source = new Map()
  // providerOf is a provider as 1.x hands it to provider.models and
  // auth.loader
  const providerOf = (id) => {
    const conf = record(providers[id])
    const models = Object.fromEntries(Object.entries(record(conf.models)).map(([k, m]) => [k, internalOf(id, conf, k, record(m))]))
    return { id, name: conf.name ?? id, source: "config", env: [], options: record(conf.options), models }
  }
  const listed = new Set()
  for (const [id, conf0] of Object.entries(providers)) {
    const conf = record(conf0)
    // a provider entry that only names the sign-in (no package, no models)
    // is not a provider of models
    if (!conf.npm && !Object.keys(record(conf.models)).length) continue
    const options = record(conf.options)
    const { apiKey: _k, baseURL: _b, fetch: _f, headers: optHeaders, ...rest } = options
    // with no base URL the config leaves it to the loader: a name that
    // can't resolve stands in for it, and each request swaps in the
    // loader's (wrapFetch)
    const baseURL = options.baseURL ?? conf.api ?? `https://${id.replace(/[^a-z0-9-]/gi, "-")}.opencode2-v1.invalid`
    const npm = conf.npm ?? "@ai-sdk/openai-compatible"
    const info = {
      id,
      ...(id === authID ? { integrationID: id } : {}),
      name: String(conf.name ?? id),
      activation: "auto",
      package: packageOf(npm),
      settings: { ...record(json(rest)), ...(baseURL ? { baseURL: String(baseURL) } : {}) },
    }
    const headers = { ...strings(conf.headers), ...strings(optHeaders) }
    if (nonEmpty(headers)) info.headers = headers
    const prov = { baseURL, npm }
    const fromConfig = () =>
      Object.entries(record(conf.models)).map(([key, m]) => modelOf(id, prov, key, internalOf(id, conf, key, record(m))))
    listed.add(id)
    await ctx.provider.transform((editor) => {
      const s = source.get(id)
      editor.add({ info, models: s?.models ?? fromConfig(), sourceConnection: s?.connection })
    })
    source.set(id, { conf, prov, models: null, connection: undefined })
  }

  // each request: the placeholder key, and the fetch that swaps in the
  // account's. A provider the package doesn't list (one 2.x has built in
  // that the plugin only signs in to) is left to 2.x unless the plugin's
  // loader serves it and one of the plugin's own sign-ins is active.
  const own = authID && !listed.has(authID) && typeof auth?.loader === "function" ? [authID] : []
  for (const id of new Set([...listed, ...own])) {
    const base = source.get(id)?.prov.baseURL
    await ctx.aisdk.hook(
      "sdk",
      async (evt) => {
        const opts = evt.options
        if (!opts || opts.__opencode2) return
        if (!listed.has(id)) {
          await getAuth(id)
          if (!current.get(id)?.ours) return
        }
        opts.__opencode2 = true
        opts.apiKey = PLACEHOLDER
        opts.fetch = wrapFetch(opts.fetch, opts.baseURL ?? base, () => loaderOptions(id))
      },
      { providerID: id },
    )
  }

  // refresh reads the account's own list after a sign-in or a switch
  const listID = hooks.provider?.id ? String(hooks.provider.id) : undefined
  let refreshing = null
  let again = false
  // the account the list was last read for: a credential.updated that
  // leaves it as it was reads nothing again
  let readFor = null
  const stateOf = async () => {
    const c = await ctx.integration.connection.active(authID).catch(() => undefined)
    const a = c ? await getAuth(authID) : undefined
    return connKey(c) + "\0" + (a ? fingerprint(a) : "")
  }
  const refresh = () => {
    if (refreshing) {
      again = true
      return refreshing
    }
    refreshing = (async () => {
      try {
        if (!authID || !source.has(authID)) return
        const s = source.get(authID)
        const connection = await ctx.integration.connection.active(authID).catch(() => undefined)
        const a = connection ? await getAuth(authID) : undefined
        readFor = connKey(connection) + "\0" + (a ? fingerprint(a) : "")
        if (!a || listID !== authID || typeof hooks.provider?.models !== "function") {
          if (s.connection || s.models) {
            s.connection = undefined
            s.models = null
            await ctx.provider.reload()
          }
          return
        }
        const provider = providerOf(authID)
        let got
        try {
          got = await hooks.provider.models(provider, { auth: a })
        } catch {
          got = null
        }
        if (connKey(await ctx.integration.connection.active(authID).catch(() => undefined)) !== connKey(connection)) {
          again = true
          return
        }
        s.connection = connection
        s.models = got && typeof got === "object" ? Object.entries(got).map(([k, m]) => modelOf(authID, s.prov, k, record(m))) : null
        await ctx.provider.reload()
        await ctx.model?.reload?.()
      } finally {
        refreshing = null
        if (again && live.on) {
          again = false
          void refresh()
        }
      }
    })()
    return refreshing
  }

  if (authID && ctx.event?.subscribe)
    void (async () => {
      try {
        // a switch names the integration; an update (a sign-in, a removal)
        // names nothing, so it reads again only when this account changed
        const types = ["credential.switched", "credential.updated"]
        for await (const event of ctx.event.subscribe({ types })) {
          if (!live.on) return
          if (event?.type === "credential.switched" && event?.data?.integrationID === authID) {
            loaded = null
            await refresh()
          } else if (event?.type === "credential.updated" && (await stateOf()) !== readFor) {
            await refresh()
          }
        }
      } catch {}
    })()
  // A plugin still reading its list in the background when the first read
  // returned (agy-cli: `agy models` and a session probe take seconds, and
  // the first read gets its static list) says so through
  // provider.warming(): the list is read once more when that ends, once,
  // and no later than a minute on.
  const warmed = async () => {
    let w
    try {
      w = typeof hooks.provider?.warming === "function" ? hooks.provider.warming() : null
    } catch {
      return
    }
    if (!w || typeof w.then !== "function") return
    let timer
    await Promise.race([
      Promise.resolve(w).catch(() => {}),
      new Promise((r) => {
        timer = setTimeout(r, 60_000)
        timer.unref?.()
      }),
    ])
    clearTimeout(timer)
    if (live.on) await refresh()
  }
  void refresh().then(warmed, () => {})
}

export async function setup(ctx, mod = v1) {
  const live = { on: true }
  for (const fn of pluginsOf(mod)) {
    try {
      await setupPlugin(ctx, fn, live)
    } catch (e) {
      // one plugin failing to start leaves the package's others working
      console.error(`${pkg.name}: ${e?.message ?? e}`)
    }
  }
  return () => {
    live.on = false
  }
}

export default { id: pkg.name, setup: (ctx) => setup(ctx) }
