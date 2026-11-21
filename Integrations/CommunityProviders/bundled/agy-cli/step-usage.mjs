// Per-model-call usage from agy's local conversation store.
//
// ACP reports usage once, accumulated over a whole session/prompt. Prefer
// `gen_metadata`, written when generation ends, before client tools return.
// Older stores record each completed model call in table `steps`, with
// step_type 15 and status 3 (done), the counts in Protobuf field 9 of
// `metadata` (2 uncached input, 3 output including thinking, 4 cache write,
// 5 cache read, 9 thinking). Summed over a prompt they equal the ACP total
// exactly.
// Protobuf layout first decoded by lili-luo/dsh-plugin-bundle
// (dsh-llm-antigravity-acp, MIT); SQLite reader adapted from
// DylanLIiii/opencode-antigravity-bridge (MIT). Any failure here returns null
// and the caller keeps its estimate.
import { createRequire } from "node:module"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { pathToFileURL } from "node:url"

const MODEL_STEP = 15
const STEP_DONE = 3
const require = createRequire(import.meta.url)

let opener

// Prefer bun:sqlite under Bun (Bun's node:sqlite keeps an unfinalized statement's
// file handle open until GC, locking the store on Windows); fall back to
// node:sqlite on Node >= 22.5. Never open a read-write handle or wait on locks.
function loadOpener() {
  if (opener !== undefined) return opener
  opener = null
  try {
    const { Database, constants } = require("bun:sqlite")
    if (typeof Database === "function") {
      // Bun's bundled SQLite on Linux/Windows disables URI filenames unless SQLITE_OPEN_URI is passed.
      const flags = constants.SQLITE_OPEN_READONLY | constants.SQLITE_OPEN_URI
      opener = (target) => {
        const db = new Database(target, flags)
        return {
          all: (sql, ...args) => {
            const stmt = db.prepare(sql)
            try {
              return stmt.all(...args)
            } finally {
              stmt.finalize()
            }
          },
          close: () => db.close(),
        }
      }
      return opener
    }
  } catch {}
  try {
    const { DatabaseSync } = require("node:sqlite")
    if (typeof DatabaseSync === "function") {
      // Only plain Node reaches this fallback; Node's DatabaseSync.close() finalizes prepared statements.
      opener = (target) => {
        const db = new DatabaseSync(target, { readOnly: true, timeout: 0 })
        return {
          all: (sql, ...args) => db.prepare(sql).all(...args),
          close: () => db.close(),
        }
      }
      return opener
    }
  } catch {}
  return opener
}

export function conversationsDir(env = process.env) {
  return env.AGY_BRIDGE_CONVERSATIONS_DIR ||
    path.join(os.homedir(), ".gemini", "antigravity-cli", "conversations")
}

export function sessionDbPath(sessionId, env = process.env) {
  if (!sessionId || !/^[A-Za-z0-9._-]+$/.test(String(sessionId))) return null
  return path.join(conversationsDir(env), `${sessionId}.db`)
}

function varint(buf, at) {
  let value = 0
  let scale = 1
  for (let i = 0; i < 10; i++) {
    const byte = buf[at + i]
    if (byte === undefined) return null
    value += (byte & 0x7f) * scale
    if ((byte & 0x80) === 0) return { value, next: at + i + 1 }
    scale *= 128
  }
  return null
}

// Calls fn(field, wire, value | bytes) for each field; false on malformed input.
function walk(buf, fn) {
  let at = 0
  while (at < buf.length) {
    const tag = varint(buf, at)
    if (!tag || tag.value < 8) return false
    at = tag.next
    const field = Math.floor(tag.value / 8)
    const wire = tag.value % 8
    if (wire === 0) {
      const item = varint(buf, at)
      if (!item) return false
      at = item.next
      fn(field, wire, item.value)
    } else if (wire === 2) {
      const len = varint(buf, at)
      if (!len || len.next + len.value > buf.length) return false
      fn(field, wire, buf.subarray(len.next, len.next + len.value))
      at = len.next + len.value
    } else if (wire === 1 || wire === 5) {
      at += wire === 1 ? 8 : 4
      if (at > buf.length) return false
    } else {
      return false
    }
  }
  return true
}

const count = (value) => Number.isSafeInteger(value) && value > 0 ? value : 0

function decodeUsage(buf) {
  const usage = { input: 0, output: 0, write: 0, read: 0, thinking: 0 }
  const ok = walk(buf, (field, wire, n) => {
    if (wire !== 0) return
    if (field === 2) usage.input = count(n)
    else if (field === 3) usage.output = count(n)
    else if (field === 4) usage.write = count(n)
    else if (field === 5) usage.read = count(n)
    else if (field === 9) usage.thinking = count(n)
  })
  return ok ? usage : null
}

export function decodeStepUsage(metadata) {
  const buf = metadata instanceof Uint8Array ? metadata
    : ArrayBuffer.isView(metadata) ? new Uint8Array(metadata.buffer, metadata.byteOffset, metadata.byteLength)
      : null
  if (!buf) return null
  let stats = null
  const ok = walk(buf, (field, wire, value) => {
    if (field !== 9 || wire !== 2) return
    stats = decodeUsage(value)
  })
  return ok ? stats : null
}

// gen_metadata.data contains the same usage message at field 1 -> 4.
// Its pre-send local context estimate is separate, at 1 -> 9 -> 10 -> 1.
// A context estimate alone is not a completed, billed model call.
export function decodeGenerationUsage(data) {
  const buf = data instanceof Uint8Array ? data
    : ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
      : null
  if (!buf) return null
  let stats = null
  let context = null
  let valid = true
  const ok = walk(buf, (field, wire, chat) => {
    if (field !== 1 || wire !== 2) return
    valid = walk(chat, (sub, subWire, value) => {
      if (subWire !== 2) return
      if (sub === 4) {
        stats = decodeUsage(value)
        if (!stats) valid = false
      } else if (sub === 9) {
        if (!walk(value, (key, kind, start) => {
          if (key !== 10 || kind !== 2) return
          if (!walk(start, (k, w, n) => {
            if (k === 1 && w === 0) context = count(n)
          })) valid = false
        })) valid = false
      }
    }) && valid
  })
  return ok && valid && stats ? { ...stats, ...(context !== null ? { context } : {}) } : null
}

function runReadOnly(open, target, fn) {
  let db
  try {
    db = open(target)
    return fn(db)
  } finally {
    try { db?.close() } catch {}
  }
}

function tableQuery(db, sql, ...args) {
  try {
    return db.all(sql, ...args)
  } catch (error) {
    if (/no such table|no such column/i.test(String(error?.message || ""))) return null
    throw error
  }
}

function isCheckpointedWal(file) {
  if (fs.existsSync(`${file}-wal`) || fs.existsSync(`${file}-shm`) || fs.existsSync(`${file}-journal`)) return false
  let fd
  try {
    fd = fs.openSync(file, "r")
    const header = new Uint8Array(20)
    if (fs.readSync(fd, header, 0, 20, 0) < 20) return false
    return header[18] === 2 && header[19] === 2
  } catch {
    return false
  } finally {
    if (fd !== undefined) {
      try { fs.closeSync(fd) } catch {}
    }
  }
}

function resolveStorePath(file) {
  if (typeof file !== "string" || !file || file.includes("\0")) return null
  return path.resolve(file)
}

// SQLite rejects non-localhost URI authorities (`file://server/share/...`) unless
// compiled with SQLITE_ALLOW_URI_AUTHORITY, strips `localhost` from `\\localhost\...`,
// and pathToFileURL rejects `\\?\...` extended paths. Prefixing Windows `\\...` paths
// directly after `file:` (with `%`, `?`, `#`, space percent-encoded) avoids any
// `//authority` segment so sqlite3ParseUri hands the exact `\\...` path to winOpen.
function immutableUri(resolved) {
  if (process.platform === "win32" && resolved.startsWith("\\\\")) {
    return `file:${resolved.replace(/[%?# ]/g, (ch) => `%${ch.charCodeAt(0).toString(16).toUpperCase().padStart(2, "0")}`)}?immutable=1`
  }
  return `${pathToFileURL(resolved).href}?immutable=1`
}

// When a WAL-flagged store (header bytes 18..19 = 2, 2) has neither -wal nor
// -shm on disk, no writer holds it open, yet SQLITE_OPEN_READONLY fails with
// SQLITE_CANTOPEN under Apple's libsqlite3 on macOS and creates -wal/-shm
// sidecars under upstream SQLite. Opening with ?immutable=1 keeps that closed
// WAL read strictly side-effect-free; if -wal appears concurrently, re-read
// once against the resolved live file path (never a relative `file:...` string).
function withStore(file, fn) {
  const resolved = resolveStorePath(file)
  if (!resolved || !fs.existsSync(resolved)) return null
  const open = loadOpener()
  if (!open) return null
  if (isCheckpointedWal(resolved)) {
    try {
      const result = runReadOnly(open, immutableUri(resolved), fn)
      if (!fs.existsSync(`${resolved}-wal`)) return result
    } catch {
      if (!fs.existsSync(`${resolved}-wal`)) return null
    }
  }
  try {
    return runReadOnly(open, resolved, fn)
  } catch {
    return null
  }
}

function maxCompletedStep(db) {
  const rows = tableQuery(db,
    `SELECT COALESCE(MAX(idx), -1) AS idx FROM steps WHERE step_type = ${MODEL_STEP} AND status = ${STEP_DONE}`)
  const idx = Number(rows?.[0]?.idx)
  return Number.isSafeInteger(idx) ? idx : null
}

function stepsAfter(db, afterIdx) {
  const rows = tableQuery(db,
    `SELECT idx, metadata FROM steps WHERE step_type = ${MODEL_STEP} AND status = ${STEP_DONE} AND idx > ? ORDER BY idx`,
    afterIdx)
  if (!rows) return null
  const steps = []
  for (const row of rows) {
    const idx = Number(row.idx)
    const usage = decodeStepUsage(row.metadata)
    if (!Number.isSafeInteger(idx) || !usage) continue
    steps.push({ idx, ...usage })
  }
  return steps
}

// Highest completed model-call index, -1 for an empty or missing store, null
// when the store exists but cannot be read.
export function lastModelStep(file) {
  const resolved = resolveStorePath(file)
  if (!resolved) return null
  if (!fs.existsSync(resolved)) return -1
  return withStore(resolved, (db) => maxCompletedStep(db))
}

// Completed model calls after `afterIdx`, oldest first: [{ idx, input, output, write, read, thinking }].
export function modelStepsAfter(file, afterIdx) {
  return withStore(file, (db) => stepsAfter(db, afterIdx))
}

// Pin a turn to one table. Reading both tables for a turn would bill the same
// generation twice. A new store is discovered after its first generation.
export function modelUsageCursor(file) {
  const resolved = resolveStorePath(file)
  if (!resolved) return null
  if (!fs.existsSync(resolved)) return { source: null, idx: -1, generationIdx: -1 }
  return withStore(resolved, (db) => {
    const genRows = tableQuery(db, "SELECT COALESCE(MAX(idx), -1) AS idx FROM gen_metadata")
    const generationIdx = Number(genRows?.[0]?.idx)
    const step = maxCompletedStep(db)
    if (Number.isSafeInteger(generationIdx)) {
      return step === null ? { source: "gen_metadata", idx: generationIdx }
        : { source: null, idx: step, generationIdx }
    }
    return step === null ? null : { source: "steps", idx: step }
  })
}

export function modelUsageAfter(file, cursor) {
  if (!cursor) return null
  return withStore(file, (db) => {
    if (cursor.source !== "steps") {
      const after = cursor.source === "gen_metadata" ? cursor.idx : cursor.generationIdx
      const rows = tableQuery(db, "SELECT idx, data FROM gen_metadata WHERE idx > ? ORDER BY idx", after)
      if (rows) {
        const steps = []
        let pending = false
        for (const row of rows) {
          const idx = Number(row.idx)
          const usage = decodeGenerationUsage(row.data)
          if (!Number.isSafeInteger(idx)) return null
          // Failed generations and pre-send estimates carry no billing counters.
          if (!usage || !(usage.input + usage.read + usage.write + usage.output + usage.thinking)) {
            pending = true
            continue
          }
          pending = false
          steps.push({ idx, ...usage })
        }
        if (steps.length || pending || cursor.source === "gen_metadata") {
          return { source: "gen_metadata", steps, ...(pending ? { pending: true } : {}) }
        }
      }
      if (cursor.source === "gen_metadata") return null
    }
    const steps = stepsAfter(db, cursor.idx)
    return steps === null ? null : { source: "steps", steps }
  })
}
