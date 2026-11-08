import { createHash, randomUUID } from 'node:crypto';
import { MessageInput } from './input.mjs';
import { SDKProcessOwner } from './process.mjs';
import { authentication, isSDKAuthenticationError, validateSDKQuery } from './sdk.mjs';
import { HostError, deadline } from './validation.mjs';

export async function queryAccountScope(sdk, config) {
  const processes = new SDKProcessOwner();
  let startup; let warm; let query; let drain; let expired = false; let operationError;
  try {
    startup = Promise.resolve().then(() => sdk.startup({
      options: {
        auth: authentication(sdk, config), cwd: config.cwd,
        pathToQoderCLIExecutable: config.cliPath, transport: sdk.ProcessTransport.default,
        executable: process.execPath, spawnQoderCLIProcess: options => processes.spawn(options),
        sessionId: randomUUID(), persistSession: false, tools: ['Read'], skills: [], mcpServers: {},
        strictMcpConfig: true, settingSources: ['user'], settings: {}, permissionMode: 'default',
        onAuthExpired: () => { expired = true; },
        ...(config.proxy ? { proxy: config.proxy } : {}),
      },
      initializeTimeoutMs: 30000,
    })).then(value => { warm = value; return value; });
    await deadline(startup, 35000);
    query = warm.query(new MessageInput());
    validateSDKQuery(query);
    drain = (async () => { for await (const _message of query) {} })();
    await deadline(query.initializationResult());
    return await accountScopeFromQuery(query, config);
  } catch (error) {
    if (expired || isSDKAuthenticationError(error)) {
      operationError = new HostError('authentication_required', error);
    } else {
      operationError = error instanceof HostError ? error : new HostError('account_scope_unavailable', error);
    }
    throw operationError;
  } finally {
    try { await startup; } catch {}
    const errors = [];
    for (const close of [() => query?.close(), () => warm?.close(),
      () => drain && deadline(drain, 2000), () => processes.close()]) {
      try { await close(); } catch (error) { errors.push(error); }
    }
    if (errors.length) {
      const code = errors.some(error => error?.code === 'process_exit_unconfirmed')
        ? 'process_exit_unconfirmed' : 'cleanup_failed';
      throw new HostError(code, new AggregateError(operationError ? [operationError, ...errors] : errors));
    }
  }
}

export async function accountScopeFromQuery(query, config) {
  if (typeof query.accountInfo !== 'function') throw new HostError('account_scope_unavailable');
  let account;
  try { account = await deadline(query.accountInfo()); }
  catch (error) {
    if (isSDKAuthenticationError(error)) {
      throw new HostError('authentication_required', error);
    }
    throw new HostError('account_scope_unavailable', error);
  }
  if (typeof account?.userId !== 'string' || !account.userId.trim()
    || Buffer.byteLength(account.userId) > 512 || /[\x00-\x1f\x7f]/u.test(account.userId)) {
    throw new HostError('account_scope_unavailable');
  }
  return createHash('sha256')
    .update(`codexbridge:qoder-account-scope:v1\0${config.distribution}\0${account.userId}`)
    .digest('hex');
}
