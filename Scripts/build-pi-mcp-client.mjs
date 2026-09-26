import { spawnSync } from "node:child_process";
import { copyFile, mkdir } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";

const repositoryRoot = fileURLToPath(new URL("../", import.meta.url));
const extensionRoot = path.join(
  repositoryRoot, "Packages/BridgeCore/Sources/BridgePiRPC/Resources/PiBridgeExtension",
);
const buildRoot = path.join(repositoryRoot, ".build/pi-mcp-extension-runtime");
await mkdir(buildRoot, { recursive: true });
for (const file of ["package.json", "package-lock.json"]) {
  await copyFile(path.join(extensionRoot, file), path.join(buildRoot, file));
}

const install = spawnSync(process.platform === "win32" ? "npm.cmd" : "npm", [
  "ci", "--ignore-scripts", "--no-audit", "--no-fund",
], { cwd: buildRoot, stdio: "inherit", shell: process.platform === "win32" });
if (install.error) throw install.error;
if (install.status !== 0) throw new Error(`npm ci exited with ${install.status}.`);

const dependencies = path.join(buildRoot, "node_modules");
const esbuild = await import(pathToFileURL(path.join(dependencies, "esbuild/lib/main.js")));
await esbuild.build({
  entryPoints: [path.join(extensionRoot, "mcp-client-entry.mjs")],
  outfile: path.join(extensionRoot, "mcp-client.bundle.cjs"),
  bundle: true,
  platform: "node",
  format: "cjs",
  target: "node22",
  nodePaths: [dependencies],
});
