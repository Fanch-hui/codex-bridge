import { realpathSync } from 'node:fs';

const globalActions = [
  'session/list', 'session/search', 'session/control', 'session/modelCatalog', 'session/create', 'workspace/follow',
  'llm/listProviders', 'llm/listConfigurableProviders', 'pluginInventory/list',
  'dynamicCordisRunner/inventory', 'dynamicCordisRunner/syncInspectManifest',
  'pluginManager/listBundles', 'pluginManager/listPlugins', 'pluginManager/registries',
  'pluginManager/listVersionExemptions', 'pluginManager/inspect', 'pluginManager/installBundle',
  'pluginManager/waitForInstall', 'pluginManager/cancelInstall', 'pluginManager/setBundleEnabled',
  'pluginManager/setPluginEnabled', 'pluginManager/removeBundle', 'pluginManager/setVersionExemption',
  'permissionPresets/catalog', 'settings/describe', 'settings/mutate', 'settings/update', 'settings/replace',
  'settings/openSettingsDocument', 'credentials/describe', 'credentials/set', 'credentials/unset',
  'workspace/pinSession', 'workspace/unpinSession', 'workspace/archiveSession', 'workspace/unarchiveSession',
  'schedule/catalog',
  'event:commands/change', 'event:llm/adapters-updated', 'event:permission-presets/catalog-changed',
  'event:schedule/changed', 'event:goal/activation-changed',
  'event:plugin-manager/changed', 'event:plugin-manager/install-state', 'event:plugin-manager/install-log',
  'event:settings/document-updated'
];
const sessionActions = [
  'session/list', 'session/search', 'session/control', 'session/follow', 'session/page', 'session/projections',
  'session/attachment', 'session/modelCatalog', 'workspace/follow',
  'skills/list', 'commands/list', 'fileReferences/list', 'job/list', 'job/follow', 'job/kill',
  'schedule/list', 'schedule/history', 'schedule/update', 'schedule/delete',
  'goals/get', 'goals/edit', 'goals/pause', 'goals/resume', 'goals/clear',
  'session/prompt', 'session/cancel', 'session/fork', 'session/rename', 'session/selectModel', 'session/updateQueue', 'commands/execute',
  'event:api-session/activity', 'event:api-session/added', 'event:api-session/error',
  'event:api-session/removed', 'event:api-session/status'
];

export class ClientScope {
  constructor(ctx) {
    this.ctx = ctx;
    this.sessionIDs = [];
    this.workspacePaths = [];
    this.signature = '';
    this.unregister = ctx.remoteAccess.registerPolicy('bridge-ui', {
      bindings: () => this.bindings()
    });
    this.peer = ctx.connection.createPeer({ principal: { kind: 'bridge-ui' }, interactions: 'answer' });
    this.managerPeer = ctx.connection.createPeer({ principal: { kind: 'bridge-ui' }, interactions: 'answer' });
  }
  update(scope) {
    if (scope?.globalOnly === true) return false;
    if (!scope || !Array.isArray(scope.sessionIDs) || !Array.isArray(scope.workspacePaths)) {
      throw new Error('Trusted client scope is required');
    }
    const clean = list => [...new Set(list.filter(value => typeof value === 'string' && value))].sort();
    const sessionIDs = clean(scope.sessionIDs);
    const workspacePaths = clean(scope.workspacePaths);
    const signature = JSON.stringify([sessionIDs, workspacePaths]);
    if (signature === this.signature) return false;
    this.signature = signature;
    this.sessionIDs = sessionIDs;
    this.workspacePaths = workspacePaths;
    const previous = this.peer;
    this.peer = this.ctx.connection.createPeer({ principal: { kind: 'bridge-ui' }, interactions: 'answer' });
    void previous.dispose();
    this.ctx.remoteAccess.invalidate(this.peer.principal);
    return true;
  }
  bindings() {
    const result = [{ role: { name: 'bridge-global', resource: 'global', actions: globalActions }, resource: { kind: 'global' } }];
    for (const id of this.sessionIDs) result.push({
      role: { name: 'bridge-session', resource: 'session', actions: sessionActions }, resource: { kind: 'session', id }
    });
    const paths = this.canonicalPaths();
    for (const workspace of this.ctx.workspaceRegistry.list()) if (paths.has(workspace.path)) result.push({
      role: { name: 'bridge-workspace', resource: 'workspace', actions: ['workspace/follow'] },
      resource: { kind: 'workspace', id: workspace.id }
    });
    return result;
  }
  canonicalPaths() {
    return new Set(this.workspacePaths.flatMap(path => {
      try { return [realpathSync(path)]; } catch { return []; }
    }));
  }
  workspacePath(id) {
    const workspace = this.ctx.workspaceRegistry.get(id);
    if (!workspace || !this.canonicalPaths().has(workspace.path)) throw new Error('Workspace is unavailable');
    return { path: workspace.path };
  }
  dispose() { this.unregister(); void this.peer.dispose(); void this.managerPeer.dispose(); }
}
