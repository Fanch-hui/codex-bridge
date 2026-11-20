import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { composeEntries, initProfile, loadOptionalPatches, loadProfileDirectory } from '@deepseek-ai/dsh-app-boot';
import { createLaunchEnvironmentSnapshot } from '@deepseek-ai/dsh-launch-environment';
import { INSTALL_ANCHOR, runProfile } from '@deepseek-ai/dsh/lib/profile-boot.js';

const hostDirectory = dirname(fileURLToPath(import.meta.url));
const retained = new Set([
  'llm', 'session', 'typert', 'attachment-local', 'config-editor', 'settings',
  'agent-default-model', 'llm-pi-ai', 'authorization', 'deepseek-account', 'llm-deepseek', 'llm-deepseek-account'
]);

export async function startProviderEngine(home) {
  process.env.DSH_HOME = home;
  process.env.DSH_TELEMETRY_DISABLED = '1';
  const directory = join(home, 'profiles', 'bridge');
  initProfile(directory, ['@deepseek-ai/dsh-base']);
  const profile = loadProfileDirectory('dsh', directory, INSTALL_ANCHOR);
  if (profile.skippedBundles.length) throw new Error('DSH profile bundles are unavailable');
  const global = loadOptionalPatches('dsh', join(home, 'cordis.patch.yml')) ?? [];
  const entries = composeEntries([...profile.layers.map(layer => layer.patches), profile.patches, global]);
  const rows = entries.filter(entry => !retained.has(entry.id)).map(entry => ({ id: entry.id, disabled: true }));
  rows.push({ insert: [
    { id: 'bridge-credentials', name: pathToFileURL(join(hostDirectory, 'credentials.mjs')).href },
    { id: 'settings-controller', name: '@deepseek-ai/dsh-api-settings-controller' },
    { id: 'chatgpt-siwc', name: pathToFileURL(join(hostDirectory, '..', 'node_modules', 'dsh-plugin-chatgpt-siwc', 'lib', 'index.js')).href },
    { id: 'llm-zcode', name: pathToFileURL(join(hostDirectory, '..', 'node_modules', 'dsh-zcode', 'lib', 'index.js')).href },
    { id: 'workbuddy-manager', name: pathToFileURL(join(hostDirectory, '..', 'node_modules', 'dsh-workbuddy-manager', 'lib', 'index.js')).href }
  ] });
  const overlay = join(home, 'bridge-provider.patch.json');
  mkdirSync(home, { recursive: true });
  writeFileSync(overlay, JSON.stringify(rows));
  const pnpm = join(hostDirectory, '..', 'node_modules', 'pnpm', 'bin', 'pnpm.cjs');
  if (!existsSync(pnpm)) throw new Error('Bundled pnpm is unavailable');
  return runProfile({
    profile: 'bridge', patchFiles: [overlay], args: [],
    packageManager: { command: process.execPath, args: [pnpm] },
    environment: createLaunchEnvironmentSnapshot([{ source: 'process', values: process.env }])
  });
}
