// Codex Bridge: where agy's working folders live, and their cleanup.
//
// Upstream starts each agy in a folder made under os.tmpdir(), and a parked
// session resumes only into a folder of that name under the same tmpdir. A
// host that runs with another TMPDIR from one start to the next (or an OS
// that clears the temp folder) left the saved name unusable: the session
// resumed in a new folder and agy's prompt cache, which follows the folder,
// started again. Here the folders sit next to the session state file, which a
// host already keeps stable (AGY_BRIDGE_STATE_FILE), in a `workspaces` folder
// of mode 0700.
//
// A folder is still removed when its agy stops, and made again under the same
// name on resume (index.mjs, Proc.#spawn and Proc.#stop); only folders an
// abnormal exit left behind need sweeping, and those are swept here.
import fs from "node:fs"
import os from "node:os"
import path from "node:path"

const PREFIX = "magpie-agy-bridge-"
const NAME = /^magpie-agy-bridge-[A-Za-z0-9]{6}$/
const SWEEP_LIMIT = 256
const SWEEP_FIRST_MS = 30_000
const SWEEP_EVERY_MS = 60 * 60 * 1000
const LOG_NAME = "agy-acp.log"

// The folder the working folders are made in: AGY_BRIDGE_WORKSPACE_ROOT (an
// absolute folder, or "tmp" for the temp folder upstream uses), else
// `workspaces` beside the state file. `managed` is true for the folder the
// plugin owns outright, which is kept private.
export function workspaceRoot(stateFile, env = process.env, tmpdir = os.tmpdir()) {
  const named = String(env.AGY_BRIDGE_WORKSPACE_ROOT || "").trim()
  if (/^(?:tmp|temp)$/i.test(named)) return { dir: path.resolve(tmpdir), managed: false }
  if (named && path.isAbsolute(named)) return { dir: path.resolve(named), managed: false }
  return { dir: path.join(path.resolve(path.dirname(stateFile)), "workspaces"), managed: true }
}

// A new working folder. When the root can't be written the temp folder is
// used for this one, as upstream always does, so a turn is not lost to it.
export async function makeWorkspace(root, tmpdir = os.tmpdir()) {
  try {
    await fs.promises.mkdir(root.dir, { recursive: true, mode: 0o700 })
    if (root.managed && process.platform !== "win32") await fs.promises.chmod(root.dir, 0o700).catch(() => {})
    return await fs.promises.mkdtemp(path.join(root.dir, PREFIX))
  } catch {
    return fs.promises.mkdtemp(path.join(tmpdir, PREFIX))
  }
}

// Only a folder this plugin makes, in one of `dirs`: the state file is never
// a way to run agy somewhere else.
export function ownWorkspace(workspace, dirs) {
  if (typeof workspace !== "string" || !path.isAbsolute(workspace)) return null
  const resolved = path.resolve(workspace)
  if (!NAME.test(path.basename(resolved))) return null
  const parent = path.dirname(resolved)
  return dirs.some((dir) => parent === path.resolve(dir)) ? resolved : null
}

async function lastTouched(dir, stat) {
  let touched = stat.mtimeMs
  try {
    touched = Math.max(touched, (await fs.promises.stat(path.join(dir, LOG_NAME))).mtimeMs)
  } catch {}
  return touched
}

// Remove working folders an agy left behind: named like the plugin's own, a
// real folder of this user's, in no `keep` (a live agy's, or a parked
// session still inside its resume window) and untouched for ttlMs. At most
// `limit` are looked at per pass. Returns how many it removed.
export async function sweepWorkspaces(root, { keep, ttlMs, now = Date.now(), limit = SWEEP_LIMIT }) {
  let names
  try {
    names = await fs.promises.readdir(root.dir)
  } catch {
    return 0
  }
  const uid = typeof process.getuid === "function" ? process.getuid() : null
  let looked = 0
  let removed = 0
  for (const name of names) {
    if (!NAME.test(name)) continue
    if (++looked > limit) break
    const dir = path.join(root.dir, name)
    if (keep.has(dir)) continue
    try {
      const stat = await fs.promises.lstat(dir)
      if (!stat.isDirectory() || (uid !== null && stat.uid !== uid)) continue
      if (now - await lastTouched(dir, stat) <= ttlMs) continue
      await fs.promises.rm(dir, { recursive: true, force: true })
      removed++
    } catch {}
  }
  return removed
}

// A first pass shortly after the plugin starts and one every hour, never
// holding the process open. Returns the pass, for a test to run directly.
export function startWorkspaceSweeper({ root, keep, ttlMs }) {
  let running = false
  const pass = async () => {
    if (running) return 0
    running = true
    try {
      return await sweepWorkspaces(root(), { keep: keep(), ttlMs: ttlMs() })
    } catch {
      return 0
    } finally {
      running = false
    }
  }
  setTimeout(pass, SWEEP_FIRST_MS).unref?.()
  setInterval(pass, SWEEP_EVERY_MS).unref?.()
  return pass
}
