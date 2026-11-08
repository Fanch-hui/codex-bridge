import { createHash } from 'node:crypto';
import path from 'node:path';
import { spawnClaude } from './process.mjs';
import { HostError, requireValue } from './validation.mjs';

export const sdkVersion = '0.3.317';

export function supportsLiteralPrompts(version) {
  const match = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/u.exec(version);
  if (!match) return false;
  const parts = match.slice(1, 4).map(Number);
  if (!parts.every(Number.isSafeInteger)) return false;
  const minimum = [2, 1, 248];
  for (let index = 0; index < minimum.length; index++) {
    if (parts[index] !== minimum[index]) return parts[index] > minimum[index];
  }
  return !match[4];
}

export function authenticationScope(status, directory, authMethod, environment = process.env) {
  const identityFields = ['accountId', 'accountUuid', 'account_id', 'account_uuid',
    'organizationId', 'organizationUuid', 'organization_id', 'organization_uuid', 'apiProvider'];
  const identities = identityFields.flatMap(key => {
    const value = status[key];
    return typeof value === 'string' && /^[A-Za-z0-9:_-]{1,128}$/u.test(value) ? [[key, value]] : [];
  });
  const endpointFields = ['ANTHROPIC_BASE_URL', 'ANTHROPIC_BEDROCK_BASE_URL',
    'ANTHROPIC_VERTEX_BASE_URL', 'ANTHROPIC_FOUNDRY_BASE_URL', 'AZURE_AI_PROJECT_ENDPOINT'];
  const endpoints = endpointFields.flatMap(key => {
    try {
      if (!environment[key]) return [];
      const url = new URL(environment[key]);
      return ['https:', 'http:'].includes(url.protocol) ? [[key, url.origin]] : [];
    } catch { return []; }
  });
  const cloudFields = ['CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY',
    'AWS_REGION', 'AWS_DEFAULT_REGION', 'AWS_PROFILE', 'GOOGLE_CLOUD_PROJECT', 'GOOGLE_CLOUD_REGION', 'CLOUD_ML_REGION',
    'ANTHROPIC_VERTEX_PROJECT_ID', 'AZURE_AI_PROJECT_NAME'];
  const cloud = cloudFields.flatMap(key => {
    const value = environment[key];
    return typeof value === 'string' && /^[A-Za-z0-9._:/-]{1,256}$/u.test(value) ? [[key, value]] : [];
  });
  return createHash('sha256').update(JSON.stringify([directory, authMethod, identities, endpoints, cloud])).digest('hex');
}

export function authenticationIdentityScope(status, authMethod, environment = process.env) {
  const fields = ['accountId', 'accountUuid', 'account_id', 'account_uuid', 'email', 'accountEmail'];
  const identity = fields.flatMap(key => {
    const value = status[key];
    return typeof value === 'string' && value.length > 0 && value.length <= 256
      && !/[\u0000-\u001f\u007f]/u.test(value) ? [[key, value]] : [];
  });
  const directCredential = (authMethod === 'oauth_token' && Boolean(environment.CLAUDE_CODE_OAUTH_TOKEN))
    || (authMethod === 'api_key' && Boolean(environment.ANTHROPIC_API_KEY || environment.ANTHROPIC_AUTH_TOKEN));
  return {
    identityScopeDigest: createHash('sha256').update(JSON.stringify([
      authenticationScope(status, '', authMethod, environment), identity,
    ])).digest('hex'),
    identityScopeVerified: identity.length > 0 || directCredential,
  };
}

export async function loadSDK() {
  try {
    const sdk = await import('./vendor.mjs');
    requireValue(typeof sdk.startup === 'function', 'sdk_incompatible');
    return sdk;
  } catch (error) {
    if (error instanceof HostError) throw error;
    throw new HostError('sdk_unavailable');
  }
}

async function runCLI(executable, args) {
  return new Promise((resolve, reject) => {
    const script = /\.(?:js|mjs|tsx|ts|jsx)$/u.test(executable);
    const command = script ? (process.env.CODEX_BRIDGE_CLAUDE_ISOLATED === '1' ? 'node' : process.execPath) : executable;
    const commandArgs = script ? [executable, ...args] : args;
    const child = spawnClaude(command, commandArgs, { stdio: ['ignore', 'pipe', 'ignore'], windowsHide: true });
    const parts = []; let size = 0, settled = false;
    const timer = setTimeout(() => { child.kill('SIGKILL'); finish(new HostError('cli_timeout')); }, 10000);
    function finish(error, result) {
      if (settled) return;
      settled = true; clearTimeout(timer);
      if (error) reject(error); else resolve(result);
    }
    child.stdout.on('data', chunk => {
      size += chunk.length;
      if (size > 65536) { child.kill('SIGKILL'); finish(new HostError('cli_output_limit')); return; }
      parts.push(chunk);
    });
    child.once('error', () => finish(new HostError('cli_unavailable')));
    child.once('close', code => finish(null, { code, text: Buffer.concat(parts).toString('utf8') }));
  });
}

export async function inspectCLI(config) {
  const version = await runCLI(config.cliPath, ['--version']);
  const match = /(?:^|\s)(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)(?:\s|$)/u.exec(version.text);
  requireValue(version.code === 0 && match, 'cli_version_unavailable');
  const auth = await runCLI(config.cliPath, ['auth', 'status']);
  requireValue(auth.code === 0 || auth.code === 1, 'authentication_status_unavailable');
  let status;
  try { status = JSON.parse(auth.text); } catch { throw new HostError('authentication_status_unavailable'); }
  requireValue(status && typeof status === 'object' && typeof status.loggedIn === 'boolean',
    'authentication_status_unavailable');
  const methods = new Set(['none', 'claude.ai', 'oauth_token', 'api_key', 'api_key_helper', 'third_party']);
  const authMethod = methods.has(status.authMethod) ? status.authMethod : 'unknown';
  const directory = typeof status.configDirectory === 'string' && path.isAbsolute(status.configDirectory)
    ? path.resolve(status.configDirectory) : path.resolve(process.env.CLAUDE_CONFIG_DIR || path.join(process.env.HOME || '.', '.claude'));
  const configScopeDigest = authenticationScope(status, directory, authMethod);
  return { cliVersion: match[1], authenticated: status.loggedIn, authMethod, configScopeDigest,
    ...authenticationIdentityScope(status, authMethod) };
}

export function catalog(values) {
  requireValue(Array.isArray(values) && values.length <= 4096, 'invalid_model_catalog');
  const seen = new Set();
  return values.map(value => {
    requireValue(value && typeof value.value === 'string' && value.value.length > 0 && value.value.length <= 256,
      'invalid_model_catalog');
    requireValue(!seen.has(value.value), 'duplicate_model'); seen.add(value.value);
    const known = Array.isArray(value.supportedEffortLevels);
    const efforts = known ? [...new Set(value.supportedEffortLevels)].filter(item =>
      ['low', 'medium', 'high', 'xhigh', 'max'].includes(item)) : [];
    return { id: value.value, name: typeof value.displayName === 'string' ? value.displayName : value.value,
      efforts, effortsKnown: known };
  });
}
