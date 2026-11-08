import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { lstat, readFile, readdir, readlink, realpath } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

const dshVersion = "0.2.2-rc.1";
const dshCommit = "66491b05e3f05ad35bcdd4f6cd7ed26041d9e3db";
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

export async function verifyEmbeddedDSH(rootArgument, platform, architecture) {
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
  const realRoot = await realpath(root);
  for (const item of manifest.links) {
    const absolute = path.join(root, ...item.path.split("/"));
    if (await readlink(absolute) !== item.target ||
        !inside(root, path.resolve(path.dirname(absolute), item.target)) ||
        !inside(realRoot, await realpath(absolute))) {
      throw new Error(`Embedded DSH link leaves the runtime: ${item.path}`);
    }
  }
  return { files: manifest.files.length, links: manifest.links.length, node };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  if (process.argv.length !== 5) {
    throw new Error("Usage: node verify-embedded-dsh-runtime.mjs RUNTIME_ROOT PLATFORM ARCHITECTURE");
  }
  const result = await verifyEmbeddedDSH(process.argv[2], process.argv[3], process.argv[4]);
  console.log(`Verified embedded DSH: ${result.files} files and ${result.links} links.`);
}
