import { accessSync, constants, existsSync, unlinkSync } from 'node:fs';
import { delimiter, isAbsolute, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { createRequire } from 'node:module';
import { WorkspaceProcessInspector } from './workspace-process-inspection.mjs';

const encoded = process.env.CODEX_BRIDGE_PROCESS_LAUNCH;
delete process.env.CODEX_BRIDGE_PROCESS_LAUNCH;
const request = JSON.parse(encoded);
const inspector = new WorkspaceProcessInspector();
await inspector.start();
while (!existsSync(request.gate)) {
  if (!inspector.same(request.host)) process.exit(125);
  await delay(25);
}
unlinkSync(request.gate);
if (request.descriptors.length) {
  const require = createRequire(import.meta.url);
  const provider = createRequire(require.resolve('@deepseek-ai/dsh-subprocess-local/package.json'));
  const koffi = provider('koffi');
  const libc = koffi.load(process.platform === 'darwin' ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  const fcntl = libc.func('int fcntl(int, int, int)');
  for (const descriptor of request.descriptors) {
    if (fcntl(descriptor, 2, 0) !== 0) throw new Error('The process control channel could not be inherited');
  }
}
const [command, ...args] = request.argv;
let executable = command;
if (!isAbsolute(command) && !command.includes('/')) {
  executable = (process.env.PATH ?? '').split(delimiter).map(dir => resolve(process.cwd(), dir || '.', command)).find(path => {
    try { accessSync(path, constants.X_OK); return true; } catch { return false; }
  });
}
if (!executable) throw new Error('The requested executable was not found');
process.execve(executable, [command, ...args], process.env);
