import assert from "node:assert/strict";
import { cp, mkdir, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const root = new URL("../", import.meta.url);
const output = new URL("dist/", root);
const manifest = JSON.parse(await readFile(new URL(".openai/hosting.json", root), "utf8"));
assert.equal(manifest.d1, "DB");
assert.ok(!manifest.capabilities, "This relay uses its own public capability route");
const queue = (await readFile(new URL("worker/queue.js", root), "utf8"))
  .replace("export class RelayQueue", "class RelayQueue")
  .replace("export async function relayGeneration", "async function relayGeneration");
const worker = (await readFile(new URL("worker/index.js", root), "utf8"))
  .replace('import { RelayQueue, relayGeneration } from "./queue.js";\n', "");
const source = `${queue}\n${worker}`;
const module = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);
assert.equal(typeof module.default?.fetch, "function");
await mkdir(new URL("server/", output), { recursive: true });
await mkdir(new URL(".openai/drizzle/meta/", output), { recursive: true });
await writeFile(new URL("server/index.js", output), source);
await writeFile(new URL(".openai/hosting.json", output), `${JSON.stringify(manifest, null, 2)}\n`);
await cp(new URL("migrations/0000_relay.sql", root), new URL(".openai/drizzle/0000_relay.sql", output));
await writeFile(new URL(".openai/drizzle/meta/_journal.json", output), `${JSON.stringify({
  version: "7", dialect: "sqlite", entries: [
    { idx: 0, version: "6", when: 1792108800000, tag: "0000_relay", breakpoints: true },
  ],
}, null, 2)}\n`);
console.log(`Built and validated ${fileURLToPath(output)}`);
