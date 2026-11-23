import { AsyncLocalStorage } from "node:async_hooks"

// The service owns all persisted credentials; this cache is scoped by provider.
export function createCredentialBridge(send) {
  const scope = new AsyncLocalStorage()
  const stores = new Map()
  const pending = new Map()
  let nextID = 0

  function request(operation, params) {
    const id = `bridge-secret-${++nextID}`
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject })
      Promise.resolve(send({ id, method: "bridge/secret", params: { operation, ...params } }))
        .then((error) => { if (error && pending.delete(id)) reject(error) }, (error) => {
          if (pending.delete(id)) reject(error)
        })
    })
  }

  function validKey(provider, key) {
    return typeof key === "string" && (key === provider || key.startsWith(`${provider}#`))
  }

  async function load(provider) {
    const { keys } = await request("list", { provider })
    if (!Array.isArray(keys) || keys.some((key) => !validKey(provider, key))) throw new Error("Invalid credential index")
    const entries = await Promise.all(keys.map(async (key) => [key, (await request("get", { provider, key })).value]))
    return Object.fromEntries(entries.filter(([, value]) => value !== null && value !== undefined))
  }

  async function withProvider(provider, fn) {
    if (typeof provider !== "string" || !provider || provider.includes("#")) throw new Error("Invalid credential provider")
    let state = stores.get(provider)
    if (!state) {
      state = { ready: load(provider), data: undefined, queue: Promise.resolve() }
      stores.set(provider, state)
    }
    try {
      state.data ??= await state.ready
    } catch (error) {
      if (stores.get(provider) === state) stores.delete(provider)
      throw error
    }
    return scope.run({ provider, state }, fn)
  }

  function current() {
    const value = scope.getStore()
    if (!value) throw new Error("Credential access requires a provider scope")
    return value
  }

  function readAuth() { return current().state.data }
  function readAuthState() { return { all: readAuth(), known: true } }
  function authCopy(key) {
    const all = readAuth()
    const value = key === undefined ? all : all[key]
    return value === undefined ? undefined : structuredClone(value)
  }

  function changeAuth(change) {
    const { provider, state } = current()
    const operation = state.queue.then(async () => {
      const draft = structuredClone(state.data)
      const result = change(draft)
      if (result === false) return false
      const changes = []
      for (const key of new Set([...Object.keys(state.data), ...Object.keys(draft)])) {
        if (!validKey(provider, key)) throw new Error("Credential mutation crossed provider scope")
        if (!(key in draft)) changes.push({ key })
        else if (JSON.stringify(draft[key]) !== JSON.stringify(state.data[key])) changes.push({ key, value: draft[key] })
      }
      if (changes.length) {
        await request("commit", { provider, changes })
        state.data = draft
      }
      return result
    })
    state.queue = operation.then(() => {}, () => {})
    return operation
  }

  async function invalidate(provider) {
    const state = stores.get(provider)
    if (!state) return
    await state.ready
    await state.queue
    if (stores.get(provider) === state) stores.delete(provider)
  }

  function onMessage(msg) {
    if (typeof msg.id !== "string" || !msg.id.startsWith("bridge-secret-")) return false
    const item = pending.get(msg.id)
    if (!item) return true
    pending.delete(msg.id)
    if (msg.error) item.reject(new Error(String(msg.error.message ?? "Credential request failed")))
    else item.resolve(msg.result)
    return true
  }

  function close() {
    for (const { reject } of pending.values()) reject(new Error("Credential channel closed"))
    pending.clear()
  }

  return { withProvider, readAuth, readAuthState, authCopy, changeAuth, invalidate, onMessage, close }
}
