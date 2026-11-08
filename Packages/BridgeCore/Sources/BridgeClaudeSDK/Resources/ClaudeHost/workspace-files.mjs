import { lstat, opendir, realpath } from 'node:fs/promises';
import path from 'node:path';
import { absolute, contained, requireValue } from './validation.mjs';

const excluded = new Set(['.git', '.ssh', '.aws', '.cache', 'secrets', 'node_modules', 'build', 'dist']);
const maximumEntries = 4096;
const maximumBytes = 128 * 1024;
const maximumDirectories = 2048;
const maximumScannedEntries = 16384;

export async function workspaceFileServer(sdk, directory) {
  requireValue(typeof sdk.createSdkMcpServer === 'function' && typeof sdk.tool === 'function',
    'workspace_tools_unavailable');
  const root = await realpath(absolute(directory));
  const rootIdentity = await lstat(root, { bigint: true });
  requireValue(rootIdentity.isDirectory() && !rootIdentity.isSymbolicLink(), 'project_unavailable');

  async function listFiles() {
    const paths = [];
    const pending = [{ path: root, relative: '', depth: 0 }];
    let bytes = 0, directories = 0, scanned = 0, truncated = false;
    while (pending.length > 0) {
      const current = pending.pop();
      const identity = await lstat(root, { bigint: true });
      requireValue(identity.dev === rootIdentity.dev && identity.ino === rootIdentity.ino,
        'project_identity_changed');
      if (++directories > maximumDirectories) { truncated = true; break; }
      const metadata = await lstat(current.path);
      requireValue(metadata.isDirectory() && !metadata.isSymbolicLink(), 'project_identity_changed');
      const resolved = await realpath(current.path);
      requireValue(contained(root, resolved) && resolved === current.path, 'path_outside_project');
      const entries = await opendir(current.path);
      for await (const entry of entries) {
        if (++scanned > maximumScannedEntries) { truncated = true; break; }
        const name = entry.name;
        if (excluded.has(name.toLowerCase()) || /^\.env(?:\.|$)/iu.test(name)
          || entry.isSymbolicLink()) continue;
        const relative = current.relative ? current.relative + '/' + name : name;
        const display = entry.isDirectory() ? relative + '/' : relative;
        if (!entry.isDirectory() && !entry.isFile()) continue;
        const size = Buffer.byteLength(JSON.stringify(display)) + 1;
        if (paths.length >= maximumEntries || bytes + size > maximumBytes) {
          truncated = true; break;
        }
        paths.push(display); bytes += size;
        if (entry.isDirectory()) {
          if (current.depth >= 31) truncated = true;
          else pending.push({ path: path.join(current.path, name), relative, depth: current.depth + 1 });
        }
      }
      if (truncated) break;
    }
    return { content: [{ type: 'text', text: JSON.stringify({ paths, truncated }) }] };
  }

  return sdk.createSdkMcpServer({ name: 'bridge_workspace', tools: [
    sdk.tool('list_files', 'List files and directories in the current workspace.', undefined, listFiles),
  ] });
}
