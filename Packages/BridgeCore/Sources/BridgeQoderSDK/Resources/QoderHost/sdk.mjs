import { createRequire } from 'node:module';
import { readFile, realpath, stat } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import { promisify } from 'node:util';
import { execFile } from 'node:child_process';
import { requireValue, distribution, absolute, identifier, contained, HostError } from './validation.mjs';

const execute = promisify(execFile);
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
  requireValue(manifest.qoderCliVersion === match[1], 'sdk_cli_version_mismatch');
  return { sdk, sdkVersion: manifest.version, cliVersion: match[1] };
}
export function authentication(sdk) {
  return sdk.qodercliAuth();
}
export function validateSDKQuery(query) {
  for (const method of ['initializationResult', 'getAvailableModels', 'interrupt', 'close']) {
    if (typeof query[method] !== 'function') throw new HostError('sdk_query_contract_unavailable');
  }
}
