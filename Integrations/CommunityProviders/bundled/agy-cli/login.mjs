import os from "node:os"
import { spawnAgy } from "./platform.mjs"

// The Google sign-in, run by agy itself: `agy acp --login` (agy 1.5 and
// later, "ACP terminal auth") prints Google's sign-in link, then reads the
// code the page it lands on shows, or that page's whole address, from
// stdin. agy trades the code and keeps the token where it always does (the
// system keyring); the plugin never sees it. Nothing opens a browser here:
// magpie opens the link, on the machine the user is at, and takes the code
// in its own field, so this works with magpie on a server or in Docker too.

// How long the link waits for its code before agy is stopped. A sign-in
// magpie gives up on reaches no plugin hook, so this is what ends it.
export const LOGIN_WAIT_MS = 15 * 60 * 1000
// How long agy has to print the link, and to trade the code.
export const LOGIN_START_MS = 30_000
export const LOGIN_FINISH_MS = 60_000

const SIGN_IN_LINK = /https:\/\/accounts\.google\.com\/[^\s"'<>]+/

let pending = null

// lastLine is the last thing agy said, for an error.
function lastLine(text) {
  const lines = String(text).split(/\r?\n/).map(line => line.trim()).filter(Boolean)
  return lines.at(-1) ?? ""
}

function stop(child) {
  try { child.stdin?.end() } catch {}
  try { child.kill() } catch {}
}

// startLogin starts agy's sign-in and resolves with its link, or with why
// it couldn't start. A second sign-in ends the first's agy.
export function startLogin(agy, { waitMs = LOGIN_WAIT_MS, startMs = LOGIN_START_MS } = {}) {
  if (pending) {
    stop(pending)
    pending = null
  }
  return new Promise((resolve) => {
    let child
    try {
      child = spawnAgy(agy, ["acp", "--login"], { cwd: os.tmpdir(), stdio: ["pipe", "pipe", "pipe"] })
    } catch (err) {
      resolve({ error: `couldn't run agy: ${err.message}` })
      return
    }
    pending = child
    let out = ""
    let settled = false
    let exited = null
    const waiters = []
    const settle = (value) => {
      if (settled) return
      settled = true
      clearTimeout(startTimer)
      resolve(value)
    }
    const startTimer = setTimeout(() => {
      stop(child)
      settle({ error: `agy didn't print a sign-in link within ${Math.round(startMs / 1000)}s${lastLine(out) ? ` (${lastLine(out)})` : ""}` })
    }, startMs)
    const waitTimer = setTimeout(() => stop(child), waitMs)
    waitTimer.unref?.()
    const read = (data) => {
      out += data
      const link = SIGN_IN_LINK.exec(out)?.[0]
      if (link) settle({ url: link, finish })
    }
    child.stdout?.setEncoding("utf8")
    child.stderr?.setEncoding("utf8")
    child.stdout?.on("data", read)
    child.stderr?.on("data", read)
    child.stdin?.on("error", () => {})
    child.on("error", (err) => {
      exited = { code: null, err }
      for (const w of waiters.splice(0)) w()
      settle({ error: `couldn't run agy: ${err.message}` })
    })
    child.on("close", (code) => {
      clearTimeout(waitTimer)
      if (pending === child) pending = null
      exited = exited ?? { code }
      for (const w of waiters.splice(0)) w()
      // agy before 1.5 has no --login: it prints acp's usage and exits
      if (/Usage:/.test(out) && !SIGN_IN_LINK.test(out)) {
        settle({ error: "this agy can't sign in from magpie (it has no `agy acp --login`). Update it with `agy update`, or run `agy` in a terminal once to sign in, then try again." })
      }
      settle({ error: `agy exited before printing a sign-in link${lastLine(out) ? `: ${lastLine(out)}` : ""}` })
    })

    // finish hands agy the code (or the page's address) and waits for it
    // to trade it. It says why when the sign-in didn't take.
    async function finish(code, { signal, finishMs = LOGIN_FINISH_MS } = {}) {
      const value = String(code ?? "").trim()
      if (!value || /[\r\n]/.test(value)) {
        stop(child)
        return { error: "paste the code the sign-in page shows" }
      }
      if (exited) {
        return { error: "this sign-in is over (its link waits 15 minutes); start it again" }
      }
      const before = out.length
      const done = new Promise((resolve) => waiters.push(resolve))
      let timer
      const late = new Promise((resolve) => { timer = setTimeout(() => resolve("late"), finishMs) })
      const onAbort = () => stop(child)
      signal?.addEventListener?.("abort", onAbort, { once: true })
      try {
        child.stdin.write(value + "\n")
        const how = await Promise.race([done, late])
        if (how === "late") {
          stop(child)
          return { error: `agy didn't finish the sign-in within ${Math.round(finishMs / 1000)}s` }
        }
      } finally {
        clearTimeout(timer)
        signal?.removeEventListener?.("abort", onAbort)
      }
      if (exited.code === 0) return { ok: true, said: lastLine(out.slice(before)) }
      const said = lastLine(out.slice(before)) || lastLine(out)
      if (/invalid_grant/.test(said)) {
        return { error: `Google turned the code away: it was mistyped, used already, or from another sign-in page. Start the sign-in again. (${said})` }
      }
      return { error: said || `agy exited with code ${exited.code}` }
    }
  })
}
