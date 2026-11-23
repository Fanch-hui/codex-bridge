import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { createReadStream } from "node:fs";
import { lstat, readFile, readdir, readlink, realpath } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const dshVersion = "0.2.2-rc.5";
const dshCommit = "9c2670d3bce5275e0d1610272958121af87787bb";
const bundledPlugins = [
  { name: "dsh-zcode", version: "0.2.1", files: [
    "lib/index.js", "lib/proxy/upstream.cjs", "vendor/zcode-api/LICENSE", "LICENSE", "THIRD_PARTY_NOTICES.md"
  ] },
  { name: "dsh-workbuddy-manager", version: "0.4.3", files: [
    "lib/index.js", "lib/manager/contract.js", "LICENSE"
  ] }
];

function relativePath(value) {
  if (typeof value !== "string" || !value || value.includes("\\") || value.includes("\0") ||
      value.startsWith("/") || value.split("/").some(part => !part || part === "." || part === "..") ||
      /^[A-Za-z]:/.test(value)) {
    throw new Error("Invalid embedded DSH resource path.");
  }
  return value;
}

function inside(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === "" || (!path.isAbsolute(relative) && relative !== ".." &&
    !relative.startsWith(`..${path.sep}`));
}

async function digest(filename) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(filename)) hash.update(chunk);
  return hash.digest("hex");
}

async function contents(root) {
  const entries = new Map();
  async function visit(directory, prefix) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const name = prefix ? `${prefix}/${entry.name}` : entry.name;
      const absolute = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) entries.set(name, "link");
      else if (entry.isDirectory()) await visit(absolute, name);
      else if (entry.isFile()) entries.set(name, "file");
      else throw new Error(`Unsupported embedded DSH entry: ${name}`);
    }
  }
  await visit(root, "");
  entries.delete("runtime.json");
  return entries;
}

export async function verifyEmbeddedDSH(rootArgument, platform, architecture, { execute = false } = {}) {
  if (!["darwin", "windows", "linux"].includes(platform) ||
      !["x64", "arm64"].includes(architecture)) {
    throw new Error("Invalid embedded DSH platform or architecture.");
  }
  const root = path.resolve(rootArgument);
  const rootInfo = await lstat(root);
  if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) {
    throw new Error("Embedded DSH root is not a real directory.");
  }
  const manifestPath = path.join(root, "runtime.json");
  const manifestInfo = await lstat(manifestPath);
  if (!manifestInfo.isFile() || manifestInfo.isSymbolicLink()) {
    throw new Error("Embedded DSH manifest is not a regular file.");
  }
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  if (manifest.protocolVersion !== 1 || manifest.dshVersion !== dshVersion ||
      manifest.dshCommit !== dshCommit || manifest.platform !== platform ||
      manifest.architecture !== architecture || !Array.isArray(manifest.files) ||
      !Array.isArray(manifest.links)) {
    throw new Error("Embedded DSH manifest identity does not match the build.");
  }
  const node = relativePath(manifest.node);
  const entrypoint = relativePath(manifest.entry);
  const expected = new Map();
  const names = new Set();
  function reserve(name, kind) {
    const key = platform === "windows" ? name.toLowerCase() : name;
    if (name === "runtime.json" || names.has(key)) throw new Error(`Duplicate DSH resource: ${name}`);
    names.add(key);
    expected.set(name, kind);
  }
  for (const item of manifest.files) {
    const name = relativePath(item.path);
    if (!/^[a-f0-9]{64}$/.test(item.sha256)) throw new Error(`Invalid DSH digest: ${name}`);
    reserve(name, "file");
  }
  for (const item of manifest.links) {
    const name = relativePath(item.path);
    if (typeof item.target !== "string" || !item.target || item.target.includes("\0") ||
        path.isAbsolute(item.target) || /^[A-Za-z]:/.test(item.target)) {
      throw new Error(`Invalid DSH link target: ${name}`);
    }
    reserve(name, "link");
  }
  if (expected.get(node) !== "file" || expected.get(entrypoint) !== "file") {
    throw new Error("Embedded DSH Node executable or host entry is missing from the manifest.");
  }
  for (const component of ["node_modules/@deepseek-ai/dsh/package.json",
    "node_modules/@deepseek-ai/dsh/LICENSE", "node_modules/pnpm/bin/pnpm.cjs",
    "node_modules/pnpm/LICENSE", "licenses/node/LICENSE", "licenses/pnpm/LICENSE",
    ...bundledPlugins.flatMap(plugin => ["package.json", ...plugin.files].map(file => `node_modules/${plugin.name}/${file}`))]) {
    if (expected.get(component) !== "file") throw new Error(`Embedded DSH component is missing: ${component}`);
  }
  const providerComponents = [
    `provider/model-protocol${platform === "windows" ? ".exe" : ""}`,
    "provider/MODEL_PROTOCOL_LICENSE", "provider/community/host.js",
    "provider/community/bridge-secret.js", "provider/community/LICENSE",
    "provider/community/catalog.json", "provider/community/cli.mjs",
    "provider/community/install.mjs", "provider/community/provision-bun.mjs",
    "provider/agent-connections/index.mjs", "provider/agent-connections/connections.mjs",
    "provider/agent-connections/editor.mjs", "provider/agent-connections/package.json",
    "provider/agent-connections/package-lock.json",
    "provider/agent-connections/node_modules/@decimalturn/toml-patch/LICENSE",
    "provider/agent-connections/node_modules/jsonc-parser/LICENSE.md",
    ...["@decimalturn/toml-patch", "jsonc-parser"].map(name => `provider/agent-connections/node_modules/${name}/package.json`)
  ];
  for (const component of providerComponents) {
    if (expected.get(component) !== "file") throw new Error(`Provider runtime component is missing: ${component}`);
  }
  const actual = await contents(root);
  if (actual.size !== expected.size) throw new Error("Embedded DSH resource inventory differs from its manifest.");
  for (const [name, kind] of expected) {
    if (actual.get(name) !== kind) throw new Error(`Embedded DSH resource is missing or has changed type: ${name}`);
  }
  for (const item of manifest.files) {
    if (await digest(path.join(root, ...item.path.split("/"))) !== item.sha256) {
      throw new Error(`Embedded DSH resource digest mismatch: ${item.path}`);
    }
  }
  const dshPackage = JSON.parse(await readFile(path.join(root, "node_modules/@deepseek-ai/dsh/package.json"), "utf8"));
  if (dshPackage.version !== dshVersion) throw new Error("Embedded DSH package version does not match its manifest.");
  for (const plugin of bundledPlugins) {
    const installed = JSON.parse(await readFile(path.join(root, "node_modules", plugin.name, "package.json"), "utf8"));
    if (installed.name !== plugin.name || installed.version !== plugin.version) {
      throw new Error(`Embedded DSH plugin identity does not match: ${plugin.name}`);
    }
  }
  const catalog = JSON.parse(await readFile(path.join(root, "provider/community/catalog.json"), "utf8"));
  for (const entry of catalog.providers.filter(item => item.bundled !== undefined)) {
    if (typeof entry.bundled !== "string" || !/^[a-z0-9][a-z0-9-]{0,63}$/.test(entry.bundled)) {
      throw new Error(`Bundled community plugin location is invalid: ${entry.package}`);
    }
    const manifestPath = `provider/community/bundled/${entry.bundled}/package.json`;
    if (expected.get(manifestPath) !== "file") throw new Error(`Bundled community plugin is missing: ${entry.package}`);
    const installed = JSON.parse(await readFile(path.join(root, ...manifestPath.split("/")), "utf8"));
    if (installed.name !== entry.package || installed.version !== entry.version) {
      throw new Error(`Bundled community plugin identity does not match: ${entry.package}`);
    }
  }
  for (const [name, version] of [["@decimalturn/toml-patch", "3.3.3"], ["jsonc-parser", "3.3.1"]]) {
    const installed = JSON.parse(await readFile(path.join(root, "provider/agent-connections/node_modules", name, "package.json"), "utf8"));
    if (installed.name !== name || installed.version !== version) {
      throw new Error(`Agent connection dependency identity does not match: ${name}`);
    }
  }
  const realRoot = await realpath(root);
  for (const item of manifest.links) {
    const absolute = path.join(root, ...item.path.split("/"));
    if (await readlink(absolute) !== item.target ||
        !inside(root, path.resolve(path.dirname(absolute), item.target)) ||
        !inside(realRoot, await realpath(absolute))) {
      throw new Error(`Embedded DSH link leaves the runtime: ${item.path}`);
    }
  }
  if (execute) {
    const nativePlatform = process.platform === "win32" ? "windows" : process.platform;
    if (nativePlatform !== platform) throw new Error("Protocol execution requires the target OS.");
    const executable = path.join(root, "provider", platform === "windows" ? "model-protocol.exe" : "model-protocol");
    const request = JSON.stringify({ id: 1, method: "cancel", params: { requestId: "verification" } });
    const result = spawnSync(executable, ["--state-dir", tmpdir()], {
      input: `${request}\n`, encoding: "utf8", timeout: 10000, windowsHide: true,
    });
    if (result.error || result.status !== 0) {
      throw new Error("Provider protocol executable failed to start.", { cause: result.error });
    }
    let reply;
    try { reply = JSON.parse(result.stdout); }
    catch { throw new Error("Provider protocol executable returned an invalid response."); }
    if (reply.id !== 1 || reply.result?.cancelled !== false) {
      throw new Error("Provider protocol executable returned an unexpected response.");
    }
  }
  return { files: manifest.files.length, links: manifest.links.length, node };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  if (process.argv.length !== 5 && !(process.argv.length === 6 && process.argv[5] === "--execute")) {
    throw new Error("Usage: node verify-embedded-dsh-runtime.mjs RUNTIME_ROOT PLATFORM ARCHITECTURE [--execute]");
  }
  const execute = process.argv[5] === "--execute";
  const result = await verifyEmbeddedDSH(process.argv[2], process.argv[3], process.argv[4], { execute });
  console.log(`Verified embedded DSH: ${result.files} files and ${result.links} links${execute ? "; protocol executed" : ""}.`);
}
