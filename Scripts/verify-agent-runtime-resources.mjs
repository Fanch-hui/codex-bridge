import { createHash } from "node:crypto";
import { readFile, readdir, access } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sources = path.join(repository, "Packages/BridgeCore/Sources");
const bundleRoot = process.argv[2] ? path.resolve(process.argv[2]) : null;
const manifests = [
  ["BridgePiRPC", "PiRuntimeResources.swift", "PiBridgeExtension"],
  ["BridgeQoderSDK", "QoderRuntimeResources.swift", "QoderHost"],
  ["BridgePiRPC", "PiNativeHistoryResources.swift", "PiNativeHistory"],
];

async function packagedDirectory(module, group) {
  const candidates = [
    path.join(bundleRoot, `BridgeCore_${module}.bundle`, group),
    path.join(bundleRoot, `BridgeCore_${module}.bundle/Contents/Resources`, group),
    path.join(bundleRoot, `BridgeCore_${module}.resources`, group),
  ];
  const existing = [];
  for (const candidate of candidates) {
    try { await access(candidate); existing.push(candidate); } catch {}
  }
  if (existing.length !== 1) throw new Error(`Expected one packaged ${module}/${group}`);
  return existing[0];
}

let checked = 0;
for (const [module, manifest, group] of manifests) {
  const code = await readFile(path.join(sources, module, manifest), "utf8");
  const hashes = new Map(Array.from(code.matchAll(/"([^"\n]+)"\s*:\s*"([a-f0-9]{64})"/g),
    match => [match[1], match[2]]));
  if (group === "PiNativeHistory") {
    const digest = code.match(/expectedSHA256\s*=\s*"([a-f0-9]{64})"/);
    if (digest) hashes.set("native-history.mjs", digest[1]);
  }
  if (!hashes.size) throw new Error(`Empty resource manifest: ${manifest}`);
  const directory = bundleRoot ? await packagedDirectory(module, group)
    : path.join(sources, module, "Resources", group);
  const entries = await readdir(directory);
  if (entries.length !== hashes.size || entries.some(name => !hashes.has(name))) {
    throw new Error(`Resource manifest does not cover ${module}/${group}`);
  }
  for (const [name, expected] of hashes) {
    const actual = createHash("sha256").update(await readFile(path.join(directory, name))).digest("hex");
    if (actual !== expected) throw new Error(`Resource digest mismatch: ${module}/${group}/${name}`);
    checked += 1;
  }
}
console.log(`Verified ${checked} Agent runtime resources against embedded manifests.`);
