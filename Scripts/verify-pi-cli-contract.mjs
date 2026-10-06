import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, mkdir, readFile, rm } from 'node:fs/promises';
import path from 'node:path';
import { createInterface } from 'node:readline';

const [installation, expectedVersion] = process.argv.slice(2);
const providers = { '0.87.1': 'azure-openai-responses', '1.0.3': 'azure' };
if (!installation || !Object.hasOwn(providers, expectedVersion)) {
  throw new Error('Usage: node Scripts/verify-pi-cli-contract.mjs <npm-prefix> <0.87.1|1.0.3>');
}
const root = path.resolve(installation);
const packageRoot = path.join(root, 'node_modules/@earendil-works/pi-coding-agent');
const manifest = JSON.parse(await readFile(path.join(packageRoot, 'package.json'), 'utf8'));
assert.equal(manifest.version, expectedVersion, 'Installed Pi version differs from the contract');
const entry = path.join(packageRoot, typeof manifest.bin === 'string' ? manifest.bin : manifest.bin.pi);
const runtime = await mkdtemp(path.join(root, 'isolated-runtime-'));
const environment = {
  HOME: runtime, USERPROFILE: runtime,
  APPDATA: path.join(runtime, 'appdata'), LOCALAPPDATA: path.join(runtime, 'localappdata'),
  TMPDIR: runtime, TMP: runtime, TEMP: runtime,
  PI_CODING_AGENT_DIR: path.join(runtime, 'agent'), PI_OFFLINE: '1',
  PATH: path.dirname(process.execPath),
  AZURE_OPENAI_API_KEY: 'synthetic-contract-key',
  AZURE_OPENAI_RESOURCE_NAME: 'synthetic-contract-resource',
  AZURE_OPENAI_BASE_URL: 'https://synthetic-contract.invalid',
  AZURE_OPENAI_API_VERSION: '2025-01-01',
};
// Windows needs its system directories; all Agent credentials and user paths remain isolated.
for (const key of ['SystemRoot', 'WINDIR']) {
  if (process.env[key]) environment[key] = process.env[key];
}
await mkdir(environment.PI_CODING_AGENT_DIR);
let child;
let exited;
let lines;
let timer;
try {
  child = spawn(process.execPath, [entry, '--mode', 'rpc', '--no-extensions', '--no-skills',
    '--no-prompt-templates', '--no-themes', '--no-session'], {
    cwd: runtime, env: environment, stdio: ['pipe', 'pipe', 'pipe'],
  });
  exited = once(child, 'exit');
  child.stderr.resume();
  lines = createInterface({ input: child.stdout });
  const iterator = lines[Symbol.asyncIterator]();
  timer = setTimeout(() => child.kill(), 30000);
  let sequence = 0;
  async function request(type, fields = {}) {
    const id = `contract-${++sequence}`;
    child.stdin.write(`${JSON.stringify({ id, type, ...fields })}\n`);
    for (;;) {
      const next = await iterator.next();
      if (next.done) throw new Error(`Pi ${expectedVersion}: no ${type} response before exit or timeout`);
      const value = JSON.parse(next.value);
      if (value.type !== 'response' || value.id !== id) continue;
      assert.equal(value.command, type, 'Pi RPC command identity differs');
      assert.equal(value.success, true, `Pi ${expectedVersion}: ${type} failed`);
      return value.data;
    }
  }
  await request('get_state');
  const catalog = await request('get_available_models');
  assert(Array.isArray(catalog?.models), 'Pi model catalog is missing');
  const provider = providers[expectedVersion];
  const model = catalog.models.find(value => value.provider === provider && typeof value.id === 'string');
  assert(model, `Pi ${expectedVersion}: native Azure provider ${provider} is missing`);
  const selected = await request('set_model', { provider, modelId: model.id });
  assert.equal(selected?.provider, provider, 'Pi selected a different provider');
  assert.equal(selected?.id, model.id, 'Pi selected a different model');
  const state = await request('get_state');
  assert.equal(state?.model?.provider, provider, 'Pi state did not retain the selected provider');
  assert.equal(state?.model?.id, model.id, 'Pi state did not retain the selected model');
  console.log(`Pi ${expectedVersion}: isolated RPC, native ${provider} catalog and model selection passed (no inference).`);
} finally {
  clearTimeout(timer);
  lines?.close();
  if (child) {
    child.stdin.end();
    child.kill();
    await exited;
  }
  await rm(runtime, { recursive: true, force: true });
}
