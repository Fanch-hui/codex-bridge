import { createRequire } from 'node:module';
import { readFile, realpath, stat } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import { promisify } from 'node:util';
import { execFile } from 'node:child_process';
import { requireValue, distribution, absolute, identifier, contained, HostError } from './validation.mjs';

const execute = promisify(execFile);

export class SDKLifecycle {
  constructor() { this.states = new Map(); this.closed = false; this.closing = null; }
  async acquire(sdk) {
    while (true) {
      requireValue(!this.closed, 'qoder_host_closed');
      let state = this.states.get(sdk);
      if (state?.stopping) {
        const error = await state.idle;
        if (error) throw error;
        continue;
      }
      if (state?.failure) throw state.failure;
      if (!state) {
        state = { users: 0, stopping: false, failure: null };
        state.idle = new Promise(resolve => { state.resolveIdle = resolve; });
        this.states.set(sdk, state);
      }
      state.users += 1;
      let released;
      return { release: (waitForShutdown = false) => {
        if (!released) released = this.release(sdk, state, waitForShutdown);
        return released;
      } };
    }
  }
  async release(sdk, state, waitForShutdown) {
    state.users -= 1;
    if (state.users > 0) {
      if (waitForShutdown) {
        const error = await state.idle;
        if (error) throw error;
      }
      return;
    }
    state.stopping = true;
    try {
      if (typeof sdk.shutdownDaemon === 'function') await sdk.shutdownDaemon();
    } catch (error) {
      state.failure = new HostError('process_exit_unconfirmed', error);
    }
    state.stopping = false;
    if (!state.failure) this.states.delete(sdk);
    state.resolveIdle(state.failure);
    if (state.failure) throw state.failure;
  }
  close() {
    if (!this.closing) {
      this.closed = true;
      this.closing = Promise.all([...this.states.values()].map(state => state.idle)).then(errors => {
        const failure = errors.find(Boolean);
        if (failure) throw failure;
      });
    }
    return this.closing;
  }
  async using(sdk, operation) {
    const lease = await this.acquire(sdk);
    let result; let failure; let failed = false;
    try { result = await operation(); } catch (error) { failed = true; failure = error; }
    try { await lease.release(); }
    catch (error) {
      if (failed) throw new HostError('process_exit_unconfirmed', new AggregateError([failure, error]));
      throw error;
    }
    if (failed) throw failure;
    return result;
  }
}

export const sdkLifecycle = new SDKLifecycle();

export function packageName(region) {
  return distribution(region) === 'cn' ? '@qodercn-ai/qodercn-agent-sdk' : '@qoder-ai/qoder-agent-sdk';
}
export function sdkBrand(region) {
  return distribution(region) === 'cn' ? 'cn' : 'global';
}
export async function loadSDK(config) {
  const name = packageName(config.distribution);
  const root = absolute(config.sdkRoot);
  const manifest = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
  requireValue(manifest.name === name && manifest.qoderSdkBrand === sdkBrand(config.distribution)
    && typeof manifest.version === 'string', 'sdk_distribution_mismatch');
  requireValue(typeof manifest.qoderCliVersion === 'string', 'sdk_cli_contract_missing');
  identifier(manifest.version, 128);
  requireValue(/^\d+\.\d+\.\d+(?:[-+][0-9a-z.-]+)?$/iu.test(manifest.version), 'invalid_sdk_version');
  const resolver = createRequire(path.join(root, 'package.json'));
  let resolved;
  try { resolved = resolver.resolve(name); }
  catch {
    const exports = manifest.exports?.['.'] ?? manifest.exports;
    const entry = typeof exports === 'string' ? exports : exports?.import ?? exports?.default ?? manifest.main;
    requireValue(typeof entry === 'string', 'sdk_entry_unavailable');
    resolved = path.resolve(root, entry);
  }
  const entry = await realpath(resolved);
  requireValue(contained(await realpath(root), entry), 'sdk_entry_outside_package');
  const sdk = await import(pathToFileURL(entry).href);
  for (const method of ['startup', 'qodercliAuth', 'getSessionInfo']) {
    requireValue(typeof sdk[method] === 'function', 'sdk_contract_unavailable');
  }
  const cli = await realpath(absolute(config.cliPath));
  requireValue((await stat(cli)).isFile(), 'cli_unavailable');
  requireValue(!/\.(cmd|bat)$/iu.test(cli), 'native_cli_required');
  const command = /\.(?:c?js|mjs)$/iu.test(cli) ? absolute(config.nodePath) : cli;
  const args = command === cli ? ['--version'] : [cli, '--version'];
  const output = await execute(command, args, { cwd: absolute(config.cwd), timeout: 10000,
    maxBuffer: 16384, windowsHide: true, env: process.env });
  const match = output.stdout.trim().match(/(?:^|\s)v?(\d+\.\d+\.\d+(?:[-+][0-9a-z.-]+)?)(?:\s|$)/iu);
  requireValue(match, 'cli_version_unavailable');
  // The SDK validates wire protocol compatibility during initialization.
  return { sdk, sdkVersion: manifest.version, cliVersion: match[1] };
}
export function authentication(sdk) {
  return sdk.qodercliAuth();
}
export function isSDKAuthenticationError(error) {
  return error?.exitCode === 41 || error?.code === 'authentication_required'
    || (error?.result?.is_error === true && error.result.terminal_reason === 'auth_required');
}
export function validateSDKQuery(query) {
  for (const method of ['initializationResult', 'getAvailableModels', 'interrupt', 'close']) {
    if (typeof query[method] !== 'function') throw new HostError('sdk_query_contract_unavailable');
  }
}

export function sdkPermissionMode(mode = 'default') {
  return { accept_edits: 'acceptEdits', bypass_permissions: 'bypassPermissions', dont_ask: 'dontAsk' }[mode] ?? mode;
}
