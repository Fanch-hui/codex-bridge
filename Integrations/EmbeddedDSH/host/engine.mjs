import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { initProfile } from '@deepseek-ai/dsh-app-boot';
import { createLaunchEnvironmentSnapshot } from '@deepseek-ai/dsh-launch-environment';
import { runProfile } from '@deepseek-ai/dsh/lib/profile-boot.js';
import { clientRoster } from './client-roster.mjs';

const hostDirectory = dirname(fileURLToPath(import.meta.url));

export async function startEngine(home) {
  process.env.DSH_HOME = home;
  process.env.DSH_TELEMETRY_DISABLED = '1';
  const profile = join(home, 'profiles', 'bridge');
  initProfile(profile, ['@deepseek-ai/dsh-base']);
  const overlay = join(home, 'bridge-host.patch.json');
  mkdirSync(home, { recursive: true });
  const rows = [
    { id: 'credentials', disabled: true },
    { id: 'session-query-sqlite', config: { path: ':memory:', openAt: 'first-search', persistedReadConcurrency: 2 } },
    { id: 'skill-filesystem', config: { agentsHome: join(home, 'agents') } },
    { insert: [
      { id: 'bridge-credentials', name: pathToFileURL(join(hostDirectory, 'credentials.mjs')).href },
      { id: 'workspace', name: '@deepseek-ai/dsh-workspace' },
      { id: 'tool-ask-user', name: '@deepseek-ai/dsh-tool-ask-user', config: { mode: 'timed' } },
      { id: 'session-stats', name: '@deepseek-ai/dsh-session-stats' },
      { id: 'session-turn-outline', name: '@deepseek-ai/dsh-session-turn-outline' },
      { id: 'plugin-inventory', name: '@deepseek-ai/dsh-host-plugin-inventory' },
      { id: 'workspace-changes', name: '@deepseek-ai/dsh-workspace-changes' },
      { id: 'session-skills', name: pathToFileURL(join(hostDirectory, 'skill-catalog.mjs')).href },
      { id: 'settings-controller', name: '@deepseek-ai/dsh-api-settings-controller' },
      { id: 'cordis-host-runner', name: '@deepseek-ai/dsh-cordis-host-runner' },
      { id: 'chatgpt-siwc', name: pathToFileURL(join(hostDirectory, '..', 'node_modules', 'dsh-plugin-chatgpt-siwc', 'lib', 'index.js')).href },
      ...clientRoster()
    ] }
  ];
  writeFileSync(overlay, JSON.stringify(rows));
  const pnpm = join(hostDirectory, '..', 'node_modules', 'pnpm', 'bin', 'pnpm.cjs');
  if (!existsSync(pnpm)) throw new Error('Bundled pnpm is unavailable');
  return runProfile({
    profile: 'bridge', patchFiles: [overlay], args: [],
    packageManager: { command: process.execPath, args: [pnpm] },
    environment: createLaunchEnvironmentSnapshot([{ source: 'process', values: process.env }])
  });
}
