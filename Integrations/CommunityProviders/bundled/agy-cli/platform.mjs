import { spawn } from "node:child_process"
import path from "node:path"
import { accountEnv, currentHome } from "./account.mjs"

export function agyCandidates(env, home, platform = process.platform) {
  const windows = platform === "win32"
  const paths = windows ? path.win32 : path.posix
  const names = windows ? ["agy.exe", "agy.cmd", "agy.bat"] : ["agy"]
  const searchPath = env.PATH || (windows ? env.Path : "") || ""
  const candidates = env.AGY_PATH ? [env.AGY_PATH] : []
  for (const directory of searchPath.split(windows ? ";" : ":")) {
    if (directory) candidates.push(...names.map(name => paths.join(directory.replace(/^"|"$/g, ""), name)))
  }
  const directories = windows ? [
    paths.join(env.LOCALAPPDATA || paths.join(home, "AppData", "Local"), "agy", "bin"),
    paths.join(env.LOCALAPPDATA || paths.join(home, "AppData", "Local"), "Programs", "Antigravity", "bin"),
    paths.join(home, ".local", "bin"),
    paths.join(home, ".gemini", "bin"),
  ] : [paths.join(home, ".local", "bin"), paths.join(home, ".gemini", "bin"), "/usr/local/bin", "/opt/homebrew/bin"]
  for (const directory of directories) candidates.push(...names.map(name => paths.join(directory, name)))
  // the copy the plugin installed itself (install.mjs), last: an agy the
  // user installed wins
  candidates.push(ownAgyPath(env, home, platform))
  return candidates
}

// Where the plugin installs agy when the machine has none (install.mjs):
// a folder of its own under the user's data folder, never one an agy the
// user installed is in, so it never writes over theirs. In magpie's Docker
// image XDG_DATA_HOME is /config/data, on the volume, so it outlives the
// container.
export function ownAgyPath(env, home, platform = process.platform) {
  if (platform === "win32") {
    const local = env.LOCALAPPDATA || path.win32.join(home, "AppData", "Local")
    return path.win32.join(local, "magpie-agy-cli", "agy.exe")
  }
  const data = env.XDG_DATA_HOME && path.posix.isAbsolute(env.XDG_DATA_HOME) ? env.XDG_DATA_HOME : path.posix.join(home, ".local", "share")
  return path.posix.join(data, "magpie-agy-cli", "agy")
}

// The cmd.exe escaping algorithm is adapted from node-cross-spawn:
// https://github.com/moxystudio/node-cross-spawn/blob/master/lib/util/escape.js
// Copyright (c) 2018 Made With MOXY Lda
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
const cmdMeta = /([()\][%!^"`<>&|;, *?])/g

function cmdArgument(value, doubleEscape) {
  let argument = String(value)
  if (/[\0\r\n]/.test(argument)) throw new Error("a Windows command argument contains a line break or NUL")
  argument = argument.replace(/(?=(\\+?)?)\1"/g, '$1$1\\"')
  argument = argument.replace(/(?=(\\+?)?)\1$/, "$1$1")
  argument = `"${argument}"`.replace(cmdMeta, "^$1")
  // npm's cmd-shim adds a second cmd expansion pass when forwarding %*.
  return doubleEscape ? argument.replace(cmdMeta, "^$1") : argument
}

export function agySpawnSpec(file, args, platform = process.platform, env = process.env) {
  if (platform !== "win32" || !/\.(?:cmd|bat)$/i.test(file)) return { file, args, options: {} }
  if (/[\0\r\n]/.test(file)) throw new Error("a Windows command path contains a line break or NUL")
  const doubleEscape = /node_modules[\\/]\.bin[\\/][^\\/]+\.cmd$/i.test(file)
  const command = [path.win32.normalize(file).replace(cmdMeta, "^$1"), ...args.map(arg => cmdArgument(arg, doubleEscape))].join(" ")
  return {
    file: env.ComSpec || env.COMSPEC || env.comspec || "cmd.exe",
    args: ["/d", "/v:off", "/s", "/c", `"${command}"`],
    options: { windowsVerbatimArguments: true, windowsHide: true },
  }
}

// The environment an agy child runs with. A value the user set for
// AGY_CLI_DISABLE_AUTO_UPDATE (in the parent's environment or the caller's)
// is kept as written. Only when nobody set it do the plugin's children run
// with auto-update off, so a pool of ACP processes doesn't update the binary
// under each other; the user's own `agy` runs keep updating. Work for an
// account with a home of its own (account.mjs) runs agy in that home.
export function childEnv(parent = process.env, extra = {}, platform = process.platform) {
  const env = {}
  const names = new Map()
  const home = currentHome()
  for (const source of [parent, extra, home ? accountEnv(home, platform) : null]) {
    for (const [key, value] of Object.entries(source || {})) {
      if (value === undefined) continue
      // Windows treats env names case-insensitively; keep the caller's PATH.
      const name = platform === "win32" ? key.toUpperCase() : key
      if (names.has(name)) delete env[names.get(name)]
      names.set(name, key)
      env[key] = value
    }
  }
  if (![...names.keys()].some(name => name.toUpperCase() === "AGY_CLI_DISABLE_AUTO_UPDATE")) {
    env.AGY_CLI_DISABLE_AUTO_UPDATE = "true"
  }
  return env
}

export function spawnAgy(file, args, options = {}) {
  const command = agySpawnSpec(file, args)
  const env = childEnv(process.env, options?.env)
  return spawn(command.file, command.args, { ...options, ...command.options, windowsHide: true, env })
}

export function windowsMcpShim(executable, server) {
  const quote = value => {
    if (/["\0\r\n]/.test(value)) throw new Error("invalid Windows MCP shim path")
    return `"${value.replace(/%/g, "%%")}"`
  }
  return `@echo off\r\nsetlocal DisableDelayedExpansion\r\n${quote(executable)} ${quote(server)}\r\n`
}

// agy dials --ide-mcp-port by running `nc` from PATH. On Windows a console
// program started that way can be handed a console of its own, and nc.cmd
// always runs in cmd.exe, a console program: each dial then flashes a window
// and leaves a conhost.exe behind (#1047). A GUI-subsystem nc.exe never gets
// a console, whatever creation flags agy uses, and still talks over the
// stdio pipes agy hands it. Bun builds it from mcp-server.mjs on the user's
// own machine; nothing prebuilt ships. magpie runs plugins on a Bun it keeps
// as magpie-bun(.exe), so that name counts as Bun too. Another runtime (an
// opencode build, Node) gets null, and the caller falls back to nc.cmd.
export function windowsNcBuild(runtime, server, outfile, versions = process.versions) {
  if (!versions?.bun || !/^(?:magpie-)?bun(?:\.exe)?$/i.test(path.win32.basename(String(runtime || "")))) return null
  return { file: runtime, args: ["build", "--compile", "--windows-hide-console", server, "--outfile", outfile] }
}

// One taskkill run that ends each agy and everything it started (cmd.exe,
// nc); null when there is nothing to end.
export function windowsTreeKill(pids) {
  const live = [...new Set(pids)].filter(pid => Number.isInteger(pid) && pid > 0)
  if (!live.length) return null
  return { file: "taskkill", args: ["/T", "/F", ...live.flatMap(pid => ["/PID", String(pid)])] }
}
