import { createHash, randomUUID } from 'node:crypto';
import { MessageInput } from './input.mjs';
import { SDKProcessOwner } from './process.mjs';
import { authentication, validateSDKQuery } from './sdk.mjs';
import { HostError, deadline } from './validation.mjs';

export async function queryAccountScope(sdk, config) {
  const processes = new SDKProcessOwner();
  let warm; let query; let drain; let expired = false;
  try {
    warm = await deadline(sdk.startup({
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
    }), 35000);
    query = warm.query(new MessageInput());
    validateSDKQuery(query);
    if (typeof query.accountInfo !== 'function') throw new HostError('account_scope_unavailable');
    drain = (async () => { for await (const _message of query) {} })();
    await deadline(query.initializationResult());
    const account = await deadline(query.accountInfo());
    if (typeof account?.userId !== 'string' || !account.userId.trim()
      || Buffer.byteLength(account.userId) > 512 || /[\x00-\x1f\x7f]/u.test(account.userId)) {
      throw new HostError('account_scope_unavailable');
    }
    return createHash('sha256')
      .update(`codexbridge:qoder-account-scope:v1\0${config.distribution}\0${account.userId}`)
      .digest('hex');
  } catch (error) {
    if (expired || error?.exitCode === 41 || error?.code === 'authentication_required') {
      throw new HostError('authentication_required');
    }
    if (error instanceof HostError) throw error;
    throw new HostError('account_scope_unavailable');
  } finally {
    try { await query?.close(); } catch {}
    try { await warm?.close(); } catch {}
    try { await deadline(drain, 2000); } catch {}
    await processes.close();
  }
}
