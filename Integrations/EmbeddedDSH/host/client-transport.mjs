import { createHash, randomUUID } from 'node:crypto';
import { constants, realpathSync } from 'node:fs';
import { lstat, open } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { ClientScope } from './client-scope.mjs';
import { ClientStreams } from './client-streams.mjs';
import { presentHistory, presentProjections } from './presentation.mjs';
import { validateSettingsWrite } from './client-settings.mjs';
import { inspectSession } from './session-inspection.mjs';

const managerEndpoints = new Set([
  'pluginManager/inspect', 'pluginManager/installBundle', 'pluginManager/waitForInstall',
  'pluginManager/cancelInstall', 'pluginManager/setBundleEnabled', 'pluginManager/setPluginEnabled',
  'pluginManager/removeBundle', 'pluginManager/setVersionExemption'
]);

const rpcEndpoints = new Set([
  'session/list', 'session/search', 'session/page', 'session/projections', 'session/attachment', 'session/modelCatalog',
  'skills/list', 'commands/list', 'fileReferences/list', 'llm/listProviders', 'llm/listConfigurableProviders', 'pluginInventory/list',
  'job/kill', 'schedule/list', 'schedule/catalog', 'schedule/history', 'schedule/update', 'schedule/delete',
  'goals/get', 'goals/edit', 'goals/pause', 'goals/resume', 'goals/clear',
  'dynamicCordisRunner/inventory', 'dynamicCordisRunner/syncInspectManifest',
  'pluginManager/listBundles', 'pluginManager/listPlugins', 'pluginManager/registries',
  'pluginManager/listVersionExemptions', 'permissionPresets/catalog', 'settings/describe',
  'settings/mutate', 'settings/update', 'settings/replace', 'settings/openSettingsDocument',
  'credentials/describe', 'credentials/set', 'credentials/unset', ...managerEndpoints
]);
const maxBundleBytes = 32 * 1024 * 1024;
const maxChunkBytes = 64 * 1024;
const maxResponseBytes = 6 * 1024 * 1024;
const maxFrameBytes = 1024 * 1024;
const workspaceOperations = new Map([
  ['workspace/pinSession', 'pinSession'], ['workspace/unpinSession', 'unpinSession'],
  ['workspace/archiveSession', 'archiveSession'], ['workspace/unarchiveSession', 'unarchiveSession']
]);

function currentChunk(graph, url) {
  const relative = url.replace(/^\//, '');
  for (const row of graph.entries) {
    const prefix = `plugins/${row.id}/`;
    if (!relative.startsWith(prefix)) continue;
    const [file, query] = relative.slice(prefix.length).split('?');
    if (/^client\.[A-Za-z0-9][A-Za-z0-9._-]*\.js$/.test(file)
      && file !== 'client.node.js' && !file.startsWith('client.node.')
      && query === `rev=${row.rev}` && relative === `${prefix}${file}?${query}`) return { id: row.id, file };
  }
}

async function readChunk(clientModules, chunk) {
  const clientPath = clientModules.clientPath(chunk.id);
  if (typeof clientPath !== 'string') throw new Error('Client bundle is not in the current graph');
  const path = join(realpathSync(dirname(clientPath)), chunk.file);
  const before = await lstat(path);
  if (!before.isFile() || before.size < 1 || before.size > maxBundleBytes) throw new Error('Invalid client bundle file');
  const handle = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  try {
    const info = await handle.stat();
    if (!info.isFile() || info.dev !== before.dev || info.ino !== before.ino || info.size !== before.size) {
      throw new Error('Client bundle file changed during loading');
    }
    const bytes = Buffer.alloc(info.size);
    let offset = 0;
    while (offset < bytes.length) {
      const result = await handle.read(bytes, offset, bytes.length - offset, offset);
      if (!result.bytesRead) throw new Error('Client bundle file changed during loading');
      offset += result.bytesRead;
    }
    return bytes;
  } finally { await handle.close(); }
}

export class ClientTransport {
  constructor(ctx, sessionScopes) {
    this.ctx = ctx;
    this.sessionScopes = sessionScopes;
    this.scope = new ClientScope(ctx);
    this.streams = new ClientStreams(ctx, this.scope.peer);
    this.streams.isAllowedSession = id => this.scope.sessionIDs.includes(id);
    this.bundles = new Map();
    this.bundleBytes = 0;
    this.graphRevision = '';
  }
  updateScope(scope) {
    if (!this.scope.update(scope)) return;
    this.streams.reset();
    this.streams.peer = this.scope.peer;
  }
  async workspaceSessionPath(sessionId) {
    if (typeof sessionId !== 'string' || !this.scope.sessionIDs.includes(sessionId)) throw new Error('Session is unavailable');
    const { meta } = await inspectSession(this.ctx, sessionId);
    if (typeof meta.cwd !== 'string') throw new Error('Session project is unavailable');
    const path = realpathSync(meta.cwd);
    if (!this.scope.canonicalPaths().has(path)) throw new Error('Session project is unavailable');
    return { path };
  }
  async workspaceMutate({ endpoint, sessionId, projectPath, stopActivity = false }) {
    const method = workspaceOperations.get(endpoint);
    if (!method || typeof projectPath !== 'string' || typeof stopActivity !== 'boolean' ||
        (stopActivity && endpoint !== 'workspace/archiveSession')) throw new Error('Invalid workspace operation');
    const { path } = await this.workspaceSessionPath(sessionId);
    if (path !== realpathSync(projectPath)) throw new Error('Session project does not match');
    const request = { sessionId, ...(stopActivity ? { stopActivity: true } : {}) };
    try {
      const value = await this.ctx.workspaceController[method](request);
      const field = endpoint.includes('archiveSession') ? 'archivedSessionIds' : 'pinnedSessionIds';
      return { ok: true, value: { [field]: value[field].filter(id => this.scope.sessionIDs.includes(id)) } };
    } catch (error) {
      if (error?.isDSHRemoteError === true && typeof error.code === 'string') {
        return { ok: false, error: { code: error.code, message: error.message, details: error.details } };
      }
      throw error;
    }
  }
  graph() { return this.ctx.clientModules.graph(); }
  async bundle({ url, offset = 0, limit = maxChunkBytes }) {
    if (typeof url !== 'string' || !/^\/?plugins\//.test(url) || !Number.isSafeInteger(offset) || offset < 0 ||
        !Number.isSafeInteger(limit) || limit < 1 || limit > maxChunkBytes) throw new Error('Invalid client bundle request');
    const graph = this.graph();
    if (this.graphRevision !== graph.rev) {
      this.graphRevision = graph.rev;
      this.bundles.clear();
      this.bundleBytes = 0;
    }
    const advertised = [...graph.entries, ...graph.batches].some(row => row.url === url);
    const chunk = advertised ? undefined : currentChunk(graph, url);
    if (!advertised && !chunk) throw new Error('Client bundle is not in the current graph');
    let artifact = this.bundles.get(url);
    if (!artifact) {
      let bytes;
      if (chunk) bytes = await readChunk(this.ctx.clientModules, chunk);
      else {
        const response = await this.ctx.clientModules.fetchBundle(new Request(`https://bridge.invalid/${url.replace(/^\//, '')}`));
        if (!response.ok) throw new Error(`Client bundle lookup failed (${response.status})`);
        bytes = Buffer.from(await response.arrayBuffer());
      }
      if (bytes.length > maxBundleBytes) throw new Error('Client bundle exceeds the transport budget');
      if (this.graph().rev !== graph.rev) throw new Error('Client bundle graph changed during loading');
      artifact = { bytes, sha256: createHash('sha256').update(bytes).digest('hex') };
      const existing = this.bundles.get(url);
      if (existing) { this.bundleBytes -= existing.bytes.length; this.bundles.delete(url); }
      while (this.bundleBytes + bytes.length > maxBundleBytes) {
        const oldest = this.bundles.keys().next().value;
        this.bundleBytes -= this.bundles.get(oldest).bytes.length;
        this.bundles.delete(oldest);
      }
      this.bundles.set(url, artifact);
      this.bundleBytes += bytes.length;
    } else {
      this.bundles.delete(url);
      this.bundles.set(url, artifact);
    }
    if (offset > artifact.bytes.length) throw new Error('Invalid client bundle offset');
    return { base64: artifact.bytes.subarray(offset, offset + limit).toString('base64'),
      offset, total: artifact.bytes.length, sha256: artifact.sha256 };
  }
  async rpc({ channel, endpoint, payload, scope }, signal) {
    if (channel !== '/api' || !rpcEndpoints.has(endpoint)) throw new Error('Client RPC endpoint is unavailable');
    if (scope?.globalOnly === true && !managerEndpoints.has(endpoint)) throw new Error('Client RPC endpoint is unavailable');
    if (endpoint === 'fileReferences/list') {
      const agentID = payload?.args?.agentId;
      if (typeof agentID !== 'string' || !this.scope.sessionIDs.includes(agentID) ||
          !this.sessionScopes || this.sessionScopes.isChatOnly(agentID)) throw new Error('Session project is unavailable');
    }
    validateSettingsWrite(this.ctx.settingsController, endpoint, payload?.args ?? {});
    const generation = this.streams.generation;
    const rpcId = randomUUID();
    const request = new Request(`https://bridge.invalid/api/${endpoint}`, { method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ type: 'client-request', rpcId, method: endpoint, payload }), signal });
    const peer = scope?.globalOnly === true ? this.scope.managerPeer : this.scope.peer;
    const response = await this.ctx.connection.createSharedFetchHandler('/api').fetch(request, peer);
    if (!response.ok) throw new Error(`Client RPC transport failed (${response.status})`);
    let envelope, attachments;
    if (response.headers.get('content-type')?.startsWith('multipart/form-data')) {
      const form = await response.formData();
      envelope = JSON.parse(form.get('metadata'));
      attachments = await Promise.all(envelope.attachments.map(async ({ path, part }) => {
        const bytes = Buffer.from(await form.get(part).arrayBuffer());
        if (bytes.length > maxFrameBytes) throw new Error('Client RPC attachment exceeds the transport budget');
        return { path, base64: bytes.toString('base64') };
      }));
    } else envelope = await response.json();
    if (envelope.rpcId !== rpcId || envelope.type !== 'server-response') throw new Error('Invalid client RPC response');
    if (scope?.globalOnly !== true && generation !== this.streams.generation) throw new Error('Client scope changed during the request');
    const result = envelope.result;
    if (endpoint === 'dynamicCordisRunner/inventory' && result.ok) {
      result.value = result.value.filter(row => this.scope.sessionIDs.includes(row.agentId));
    }
    if (endpoint === 'session/page' && result.ok) {
      const history = presentHistory(result.value.records, 700 * 1024);
      result.value = { ...result.value, records: history.records, hasMore: result.value.hasMore || history.truncated };
    }
    if (endpoint === 'session/projections' && result.ok && result.value?.values) {
      let { projections } = presentProjections(result.value);
      const sessionId = payload?.args?.request?.sessionId;
      if (this.contextPolicy && typeof sessionId === 'string') projections = await this.contextPolicy.projections(sessionId, projections, undefined, signal);
      result.value = { ...result.value, values: projections.values };
    }
    const wire = attachments?.length ? { ...result, attachments } : result;
    if (Buffer.byteLength(JSON.stringify(wire)) > maxResponseBytes) throw new Error('Client RPC response exceeds the transport budget');
    return wire;
  }
  dispose() { this.streams.reset(); this.scope.dispose(); this.bundles.clear(); this.bundleBytes = 0; }
}
