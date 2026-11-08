import { spawnSync } from "node:child_process";
import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { builtinModules } from "node:module";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const source = path.join(repository, "Packages/BridgeCore/Sources/BridgeClaudeSDK/Resources/ClaudeHost");
const build = path.join(repository, ".build/claude-sdk-runtime");
const check = process.argv.slice(2);
if (check.length > 1 || (check.length && check[0] !== "--check")) {
  throw new Error("Usage: node Scripts/build-claude-sdk-runtime.mjs [--check]");
}
await mkdir(build, { recursive: true });
for (const name of ["package.json", "package-lock.json"]) {
  await copyFile(path.join(source, name), path.join(build, name));
}

const npm = process.platform === "win32" ? "npm.cmd" : "npm";
const install = spawnSync(npm, ["ci", "--ignore-scripts", "--no-audit", "--no-fund"], {
  cwd: build, stdio: "inherit", shell: process.platform === "win32",
});
if (install.error) throw install.error;
if (install.status !== 0) throw new Error(`npm ci exited with ${install.status}.`);

const entry = path.join(build, "sdk-entry.mjs");
await writeFile(entry, "export * from '@anthropic-ai/claude-agent-sdk';\n");
const dependencies = path.join(build, "node_modules");
const esbuild = await import(pathToFileURL(path.join(dependencies, "esbuild/lib/main.js")));
const result = await esbuild.build({
  absWorkingDir: repository,
  entryPoints: [entry],
  outfile: path.join(build, "vendor.mjs"),
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node22",
  nodePaths: [dependencies],
  legalComments: "inline",
  metafile: true,
  banner: { js: 'import { createRequire as __bridgeCreateRequire } from "node:module"; const require = __bridgeCreateRequire(import.meta.url);' },
});
await writeFile(path.join(build, "vendor-meta.json"), JSON.stringify(result.metafile, null, 2) + "\n");
const builtins = new Set(builtinModules.map(name => name.replace(/^node:/, "")));
for (const output of Object.values(result.metafile.outputs)) {
  for (const dependency of output.imports.filter(item => item.external)) {
    if (!builtins.has(dependency.path.replace(/^node:/, ""))) {
      throw new Error(`Unbundled Claude SDK dependency: ${dependency.path}`);
    }
  }
}
const vendor = await import(pathToFileURL(path.join(build, "vendor.mjs")));
for (const method of ["startup", "query", "listSessions", "getSessionMessages", "getSessionInfo"]) {
  if (typeof vendor[method] !== "function") throw new Error(`Claude SDK export is unavailable: ${method}`);
}
await copyFile(path.join(dependencies, "@anthropic-ai/claude-agent-sdk/LICENSE.md"),
  path.join(build, "CLAUDE-SDK-LICENSE.txt"));
for (const name of ["vendor.mjs", "CLAUDE-SDK-LICENSE.txt"]) {
  const generated = path.join(build, name);
  const committed = path.join(source, name);
  if (check.length) {
    if (!(await readFile(generated)).equals(await readFile(committed))) {
      throw new Error(`Generated Claude runtime differs from source: ${name}`);
    }
  } else {
    await copyFile(generated, committed);
  }
}
console.log(`Claude SDK runtime ${check.length ? "verified" : "built"}.`);
