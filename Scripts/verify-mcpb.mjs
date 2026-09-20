import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';

const [bundleArg, fixtureArg] = process.argv.slice(2);
assert(bundleArg && fixtureArg, 'Usage: node Scripts/verify-mcpb.mjs <unpacked-mcpb> <fixture-binary>');
const bundle = resolve(bundleArg);
const sdk = join(bundle, 'node_modules', '@modelcontextprotocol', 'sdk', 'dist', 'esm');
const { Client } = await import(pathToFileURL(join(sdk, 'client', 'index.js')));
const { StdioClientTransport } = await import(pathToFileURL(join(sdk, 'client', 'stdio.js')));
const { StreamableHTTPClientTransport } = await import(pathToFileURL(join(sdk, 'client', 'streamableHttp.js')));
const temporary = await mkdtemp(join(tmpdir(), 'codex-bridge-mcpb-test-'));
const stop = join(temporary, 'stop');
const fixture = spawn(resolve(fixtureArg), ['--stop-file', stop, '--authentication', 'qwen-header'], {
  stdio: ['ignore', 'pipe', 'ignore'],
});
const fixtureExit = once(fixture, 'exit');
const lines = createInterface({ input: fixture.stdout });
const clients = [];
const transports = [];
const deadline = setTimeout(() => {
  fixture.kill('SIGTERM');
  process.exitCode = 1;
  for (const client of clients) void client.close();
}, 30_000);

try {
  const first = await Promise.race([
    once(lines, 'line'),
    fixtureExit.then(() => { throw new Error('MCP fixture exited before readiness'); }),
  ]);
  const ready = JSON.parse(first[0]);
  lines.close();
  const directTransport = new StreamableHTTPClientTransport(new URL(ready.url), {
    requestInit: { headers: { [ready.header_name]: ready.header_value } },
  });
  const proxyTransport = new StdioClientTransport({
    command: process.execPath,
    args: [join(bundle, 'server.mjs')],
    env: {
      ...process.env,
      CODEX_BRIDGE_MCP_URL: ready.url,
      CODEX_BRIDGE_MCP_TOKEN: ready.header_value,
    },
    stderr: 'pipe',
  });
  transports.push(directTransport, proxyTransport);
  for (const transport of transports) {
    const client = new Client({ name: 'codex-bridge-mcpb-test', version: '1.0.0' });
    clients.push(client);
    await client.connect(transport);
    assert.equal(client.getServerVersion().name, 'codex-bridge');
  }
  const [direct, proxy] = clients;
  assert.deepEqual(proxy.getServerCapabilities(), direct.getServerCapabilities());
  const directTools = await direct.listTools();
  assert.deepEqual(await proxy.listTools(), directTools);
  assert(directTools.tools.length > 0);
  assert(directTools.tools.every(tool => tool.annotations.readOnlyHint === true));
  const status = await proxy.callTool({ name: 'bridge_status', arguments: {} });
  assert.equal(status.isError, false);
  assert.equal(status.structuredContent.mcp_state, 'ready');
  const missing = await proxy.callTool({
    name: 'read_thread',
    arguments: { project_id: 'prj_inspector_fixture', thread_id: 'missing' },
  });
  assert.equal(missing.isError, true);
  assert.equal(missing.structuredContent.error.code, 'thread_not_found');
  console.log('MCPB passed: authenticated initialize, unchanged capabilities/tools, bridge_status, structured tool error.');
} finally {
  for (const transport of transports) {
    if (transport.terminateSession) await transport.terminateSession().catch(() => {});
  }
  await Promise.allSettled(clients.map(client => client.close()));
  await writeFile(stop, '');
  await fixtureExit;
  clearTimeout(deadline);
  await rm(temporary, { recursive: true, force: true });
}
