import { Events } from './events.mjs';
import { ModelSettings } from './settings.mjs';
import { Sessions } from './sessions.mjs';
import { McpServers } from './mcp.mjs';
import { BridgeAgents } from './bridge-agents.mjs';
import { AuthState } from './auth-state.mjs';
import { ModelCatalog, ModelSelectionProvenance } from './model-catalog.mjs';
import { randomUUID } from 'node:crypto';
import { ClientTransport } from './client-transport.mjs';
import { ClientEventResponder } from './client-event-responder.mjs';
import { ClientActivity } from './client-activity.mjs';
import { SessionScopes } from './session-scopes.mjs';
import { SessionProjectBinding } from './session-project-binding.mjs';
import { PendingQuestions } from './pending-questions.mjs';
import { sessionContent } from './session-content.mjs';
import { SessionContentCache } from './session-content-cache.mjs';
import { SessionSearch } from './session-search.mjs';
import { ConfigurationActivation, pluginApplication } from './configuration-activation.mjs';
import { PluginOperations } from './plugin-operations.mjs';
import { ScheduleOperations } from './schedule-operations.mjs';

const nativePluginWrites = new Set(['pluginManager/installBundle', 'pluginManager/setBundleEnabled',
  'pluginManager/setPluginEnabled', 'pluginManager/removeBundle', 'pluginManager/setVersionExemption']);

export class Actions {
  constructor(ctx, rpc, home) {
    this.ctx = ctx;
    this.rpc = rpc;
    this.events = new Events(ctx, rpc);
    this.activation = new ConfigurationActivation(home, (id, type, payload) => this.events.emit(id, type, payload));
    this.pluginOperations = new PluginOperations(ctx, home, this.activation,
      (id, type, payload) => this.events.emit(id, type, payload));
    this.modelSelection = new ModelSelectionProvenance(ctx);
    this.settings = new ModelSettings(ctx);
    this.catalog = new ModelCatalog(ctx, providerID => this.events.emit(undefined, 'models.changed', { providerID }),
      { defaultIsExplicit: () => this.modelSelection.isExplicit(), modelDefaults: () => this.settings.modelDefaults() });
    this.auth = new AuthState(ctx.chatgptSiwc, state => {
      if (!state.signingIn) this.catalog.invalidate();
      this.events.emit(undefined, 'auth.changed', state);
    });
    this.removeCatalogListener = ctx.on('llm/adapters-updated', () => {
      this.catalog.invalidate();
      this.events.emit(undefined, 'models.changed', { providerID: '' });
    }, { global: true });
    this.sessions = new Sessions(ctx, rpc, home);
    this.contentCache = new SessionContentCache(home);
    this.sessionSearch = new SessionSearch(ctx, this.sessions);
    this.scopes = new SessionScopes(ctx, home, (id, type, payload) => this.events.emit(id, type, payload));
    this.sessions.scopes = this.scopes;
    this.scheduleOperations = new ScheduleOperations(ctx, this.sessions, home);
    this.projectBinding = new SessionProjectBinding(ctx, this.sessions, this.scopes, this.scheduleOperations);
    this.client = new ClientTransport(ctx, this.scopes);
    this.activity = new ClientActivity(ctx, this.sessions, this.client,
      (id, type, payload) => this.events.emit(id, type, payload), this.scheduleOperations);
    this.clientEvents = new ClientEventResponder(ctx);
    this.mcp = new McpServers(ctx, rpc, home);
    this.bridgeAgents = new BridgeAgents(ctx, rpc, home, this.events, this.sessions);
    this.persistedQuestions = new PendingQuestions(ctx, home, (id, type, payload) => this.events.emit(id, type, payload));
  }
  async call(action, p = {}, signal) {
    const ctx = this.ctx;
    if (action.startsWith('client.')) this.client.updateScope(p.scope);
    switch (action) {
      case 'client.graph': return this.client.graph();
      case 'client.workspacePath': return this.client.scope.workspacePath(p.workspaceId);
      case 'client.workspaceSessionPath': return this.client.workspaceSessionPath(p.sessionId);
      case 'client.workspaceMutate': return this.client.workspaceMutate(p);
      case 'client.bundle': return this.client.bundle(p);
      case 'client.rpc': {
        if (!nativePluginWrites.has(p.endpoint)) return this.client.rpc(p, signal);
        return this.activation.run('plugins', () => this.client.rpc(p, signal),
          result => result.ok ? pluginApplication(result.value) : 'failed');
      }
      case 'client.activity': return this.activity.call(p, signal);
      case 'client.stream.open': return this.client.streams.open(p);
      case 'client.stream.send': return this.client.streams.send(p);
      case 'client.stream.close': return this.client.streams.close(p);
      case 'client.stream.poll': return this.client.streams.poll(p, signal);
      case 'status': return { ready: true, engineVersion: '0.2.1-rc.5',
        capabilities: { durableAdmission: globalThis[Symbol.for('codex-bridge.durable-session-admission')] === true,
          boundedContentRead: typeof ctx.get('sessionPersistence')?.bridgeReadEvent === 'function', titleSearch: true } };
      case 'events': return this.events.poll(p, signal);
      case 'pending.list': return this.pending(signal);
      case 'configuration.status': {
        await this.verifyRestartedPlugins();
        return { ...this.activation.snapshot(), activePluginInstalls: this.pluginOperations.activeCount(),
          pluginOperations: this.pluginOperations.recoverable() };
      }
      case 'schedule.preview': return this.activity.preview(p.change);
      case 'schedule.create': return this.scheduleOperations.create(p);
      case 'schedule.createStatus': return this.scheduleOperations.createStatus(p);
      case 'schedule.pause': return this.scheduleOperations.pause(p);
      case 'schedule.resume': return this.scheduleOperations.resume(p);
      case 'schedule.catchUp': return this.scheduleOperations.catchUp(p);
      case 'schedule.discardMissed': return this.scheduleOperations.discardMissed(p);
      case 'session.list': return this.sessions.list(signal);
      case 'session.create': {
        if (p.scope === 'chatOnly') await this.scopes.set(p.sessionId, p.scope);
        const result = await ctx.sessionController.create({ cwd: p.cwd, ...(p.sessionId ? { sessionId: p.sessionId } : {}),
          ...(p.agentPreset ? { agentPreset: p.agentPreset } : {}) });
        if (p.scope === 'chatOnly' && result.sessionId !== p.sessionId) {
          await this.scopes.set(result.sessionId, 'chatOnly');
          throw new Error('Session creation returned an unexpected identity');
        }
        return result;
      }
      case 'session.scope': return this.scopes.set(p.sessionId, p.scope);
      case 'session.bindingSnapshot': {
        const agent = await this.sessions.agent(p.sessionId);
        const selection = ctx.sessionController.agents.selectionFor(agent).current;
        return { modelSelection: { ...selection }, permissionPreset: ctx.permissionPresets.current(agent.session),
          scope: this.scopes.isChatOnly(p.sessionId) ? 'chatOnly' : 'project', cwd: agent.session.header.cwd };
      }
      case 'session.bindProject': return this.projectBinding.bind(p);
      case 'session.cancelBinding': return this.projectBinding.cancel(p);
      case 'session.continueProject': return this.projectBinding.continue(p);
      case 'session.cancelProjectSelection': {
        await this.sessions.stop(p.sessionId);
        await this.scopes.cancel(p.sessionId);
        return { accepted: true };
      }
      case 'session.rename': return ctx.sessionController.rename(p);
      case 'session.fork': return ctx.sessionController.fork(p);
      case 'session.history': return this.sessions.history(p, signal);
      case 'session.queue': return this.sessions.queue(p.sessionId);
      case 'session.content': return sessionContent(ctx, p, signal, this.contentCache);
      case 'session.search': return this.sessionSearch.search(p, signal);
      case 'session.receipt': return this.sessions.receipt(p);
      case 'session.resumePending': return this.sessions.resumePending(p);
      case 'session.selectModel': return this.selectModel(p);
      case 'session.updateQueue':
        return this.sessions.withExecution(p.sessionId, () => ctx.sessionController.updateQueue(p));
      case 'commands.list': return { items: ctx.commands.list(p.sessionId ? await this.sessions.agent(p.sessionId) : undefined) };
      case 'commands.execute': {
        const value = await this.sessions.withExecution(p.sessionId,
          agent => ctx.commands.execute(agent, p.line, p.submittedAttachments ?? [], signal));
        return value === undefined ? {} : { value };
      }
      case 'session.prompt': {
        const result = await this.sessions.prompt(p, signal);
        this.reconcile(p.sessionId);
        return result;
      }
      case 'session.stop': {
        const result = await this.sessions.stop(p.sessionId);
        await this.scopes.cancel(p.sessionId);
        return result;
      }
      case 'session.stopStatus': return this.sessions.stopStatus(p.sessionId);
      case 'models.list': return this.catalog.list({ refresh: p.refresh === true });
      case 'models.discover': return { models: await ctx.llm.discoverModels('llm-pi-ai', {
        ...(p.provider ? { provider: p.provider } : {}), baseURL: p.baseURL,
        api: p.protocol === 'responses' ? 'openai-responses' : 'openai-completions',
        ...(p.apiKey ? { apiKey: p.apiKey } : {})
      }, signal) };
      case 'skills.list': return ctx.sessionSkillCatalog.list({ sessionId: p.sessionId }, signal);
      case 'settings.get': return { ...await this.settings.get(), activation: this.activation.get('models') };
      case 'settings.save': return { ...await this.activation.run('models', () => this.updateModels(() => this.settings.save(p))),
        activation: this.activation.get('models') };
      case 'settings.remove': return { ...await this.activation.run('models', () => this.updateModels(() => this.settings.remove(p.id))),
        activation: this.activation.get('models') };
      case 'mcp.list': return { ...this.mcp.list(), activation: this.activation.get('mcp') };
      case 'mcp.save': return { ...await this.activation.run('mcp', () => this.mcp.save(p)), activation: this.activation.get('mcp') };
      case 'mcp.remove': return { ...await this.activation.run('mcp', () => this.mcp.remove(p.id)), activation: this.activation.get('mcp') };
      case 'mcp.setEnabled': return { ...await this.activation.run('mcp', () => this.mcp.setEnabled(p.id, p.enabled)), activation: this.activation.get('mcp') };
      case 'auth.begin': return this.beginAuth(() => ctx.chatgptSiwc.beginSignIn());
      case 'auth.addAccount': return this.beginAuth(() => ctx.chatgptSiwc.addAccount());
      case 'auth.cancel': return this.finishAuth(() => ctx.chatgptSiwc.cancelSignIn());
      case 'auth.signOut': return this.finishAuth(() => ctx.chatgptSiwc.signOut());
      case 'auth.switchAccount': return this.finishAuth(() => ctx.chatgptSiwc.switchAccount(p.accountId));
      case 'auth.removeAccount': return this.finishAuth(() => ctx.chatgptSiwc.removeAccount(p.accountId));
      case 'auth.refreshModels': return this.refreshAuth();
      case 'plugins.list': {
        await this.verifyRestartedPlugins();
        return { bundles: await ctx.pluginManager.listBundles(), plugins: await ctx.pluginManager.listPlugins(),
          activation: this.activation.get('plugins') };
      }
      case 'plugins.beginInstall': return this.pluginOperations.begin(p);
      case 'plugins.installStatus': return this.pluginOperations.snapshot(p.requestId);
      case 'plugins.cancelInstall': return this.pluginOperations.cancel(p.requestId);
      case 'plugins.dismissInstall': return this.pluginOperations.dismiss(p.requestId);
      case 'plugins.install': return this.activation.run('plugins', () => this.installPlugin(p.spec, p.requestId, signal), pluginApplication);
      case 'plugins.update': return this.activation.run('plugins', () => this.installPlugin(`${p.name}@latest`, p.requestId, signal), pluginApplication);
      case 'plugins.enable': return this.activation.run('plugins', () => p.kind === 'bundle'
        ? ctx.pluginManager.setBundleEnabled(p.id, p.enabled) : ctx.pluginManager.setPluginEnabled(p.id, p.enabled), pluginApplication);
      case 'plugins.remove': return this.activation.run('plugins', () => ctx.pluginManager.removeBundle(p.name), pluginApplication);
      case 'approval.answer': return this.events.answer('approval', p);
      case 'question.answer': return this.answerQuestion(p);
      case 'subagents.list': return this.subagents(p.sessionId, signal);
      case 'subagents.history': return this.subagentHistory(p);
      case 'subagents.control': return this.controlSubagent(p, signal, this.sessions.stopGate.revision(p.sessionId));
      case 'permissions.get': return this.permissions(p.sessionId);
      case 'permissions.set': {
        const agent = await this.sessions.agent(p.sessionId);
        const rootID = await this.sessions.rootID(p.sessionId);
        if (this.sessions.groups.has(rootID) || agent.status !== 'idle') throw new Error('Cannot change permissions while the session is running');
        ctx.permissionPresets.set(agent.session, p.presetId);
        return this.permissions(p.sessionId);
      }
      default: throw new Error(`Unknown action: ${action}`);
    }
  }
  async selectModel(params) {
    const result = await this.ctx.sessionController.selectModel(params);
    // The upstream session operation persists the default asynchronously.
    await this.ctx.agentDefaultModel.saveSelection(result.selected);
    await this.modelSelection.markExplicit();
    return result;
  }
  async beginAuth(operation) {
    this.auth.stop();
    const status = await operation();
    this.auth.start(status);
    return status;
  }
  async finishAuth(operation) {
    this.auth.stop();
    const status = await operation();
    this.auth.stop();
    this.auth.publish(status);
    return status;
  }
  async refreshAuth() {
    const status = await this.ctx.chatgptSiwc.refreshModels();
    if (!this.auth.isWatching) this.auth.publish(status);
    return status;
  }
  async updateModels(operation) {
    const result = await operation();
    this.catalog.invalidate();
    return result;
  }
  async verifyRestartedPlugins() {
    const state = this.activation.get('plugins');
    if (state.status !== 'restart-required' && !(state.status === 'unknown' && state.verificationPending)) return;
    if (this.pluginVerification) return this.pluginVerification;
    const task = this.verifyPluginInventory();
    this.pluginVerification = task;
    try { await task; } finally { if (this.pluginVerification === task) this.pluginVerification = undefined; }
  }
  async verifyPluginInventory() {
    try {
      const [bundles, plugins] = await Promise.all([this.ctx.pluginManager.listBundles(), this.ctx.pluginManager.listPlugins()]);
      const failed = bundles.some(bundle => bundle.enabled && bundle.error) ||
        plugins.some(plugin => plugin.enabled && plugin.fiberPhase === 'failed');
      const pending = plugins.some(plugin => plugin.enabled && ['loading', 'pending'].includes(plugin.fiberPhase));
      let status = 'applied';
      if (failed) status = 'failed';
      else if (pending) status = 'unknown';
      await this.activation.completeRestart('plugins', status);
    } catch (error) {
      await this.activation.completeRestart('plugins', 'unknown');
      process.stderr.write(`Plugin activation verification failed: ${error.message}\n`);
    }
  }
  async dispose() {
    await this.activity.dispose();
    await this.contentCache.dispose();
    this.scopes.dispose();
    await this.persistedQuestions.dispose();
    await this.pluginOperations.dispose();
    this.removeCatalogListener(); this.auth.stop(); this.catalog.dispose(); this.client.dispose(); this.clientEvents.dispose();
  }
  async installPlugin(spec, requestId = randomUUID(), signal) {
    signal?.throwIfAborted();
    const cancel = () => { void this.ctx.pluginManager.cancelInstall(requestId).catch(error => process.stderr.write(`DSH plugin cancellation failed: ${error.message}\n`)); };
    signal.addEventListener('abort', cancel, { once: true });
    try { return await this.ctx.pluginManager.installBundle(spec, { requestId }); }
    finally { signal.removeEventListener('abort', cancel); }
  }
  reconcile(sessionId) {
    void this.bridgeAgents.reconcile(sessionId).catch(error => process.stderr.write(`DSH subagent recovery failed: ${error.message}\n`));
  }
  async pending(signal) {
    const items = [...this.events.pending.values()].map(({ sessionID, type, payload }) => ({ sessionID, type, payload }));
    items.push(...this.scopes.items());
    signal?.throwIfAborted();
    for (const item of this.persistedQuestions.items()) {
      if (!items.some(other => other.sessionID === item.sessionID && other.type === 'question' && other.payload.callId === item.payload.callId)) items.push(item);
    }
    return { items };
  }
  async answerQuestion(p) {
    if (this.events.pending.has(p.requestId)) return this.events.answer('question', p);
    const pending = this.persistedQuestions.find(p.requestId);
    if (!pending) throw new Error('Question is no longer pending');
    const agent = await this.sessions.agent(pending.sessionID);
    let meta = (await this.ctx.sessionController.inspect(pending.sessionID)).meta;
    while (meta.origin === 'subagent' && meta.parentSession) meta = (await this.ctx.sessionController.inspect(meta.parentSession)).meta;
    const rootAgent = meta.id === pending.sessionID ? agent : await this.sessions.agent(meta.id);
    const { group, generation } = await this.sessions.begin(meta.id, rootAgent);
    try {
      if (!this.ctx.userQuestions.answer(agent, pending.callId, { answers: p.answers })) throw new Error('Question is no longer pending');
      this.persistedQuestions.remove(pending.sessionID, pending.callId);
      return { accepted: true };
    } finally {
      setImmediate(() => void agent.whenIdle().then(() => this.sessions.settle(meta.id, rootAgent, group, generation)));
    }
  }
  async subagents(id, signal) {
    const result = await this.sessions.listChildren(id, signal);
    for (const item of result.items) {
      const binding = [...this.bridgeAgents.bindings].reverse().find(row => row.childID === item.childId);
      if (binding) Object.assign(item, { installationID: binding.installationID, taskID: binding.taskID, status: binding.state });
    }
    return result;
  }
  async subagentHistory(p) {
    const binding = [...this.bridgeAgents.bindings].reverse().find(row => row.childID === p.childId && row.rootSessionID === p.sessionId);
    if (!binding) throw new Error('Bridge subagent not found');
    return this.rpc.request('bridge/subagent', { operation: 'get', ...binding });
  }
  async permissions(id) {
    const catalog = this.ctx.permissionPresets.catalog();
    const agent = id ? await this.sessions.agent(id) : undefined;
    return { presets: catalog.options.map(option => ({ id: option.value, name: option.name })),
      selected: agent ? this.ctx.permissionPresets.current(agent.session) : catalog.defaultPreset };
  }
  async controlSubagent(p, signal, revision) {
    const items = (await this.sessions.listChildren(p.sessionId, signal)).items;
    const child = items.find(item => item.childId === p.childId);
    if (!child) throw new Error('Subagent not found');
    if (p.operation === 'send') await this.sessions.stopGate.resume(p.sessionId, revision);
    if (child.mode === 'external') {
      if (p.operation === 'stop') return this.bridgeAgents.stop(p.childId, p.sessionId);
      if (p.operation === 'send') {
        const result = await this.bridgeAgents.send(p.childId, p.text, p.requestId, p.sessionId);
        this.reconcile(p.sessionId);
        return result;
      }
    }
    if (p.operation === 'stop') {
      this.ctx.subagents.interrupt(p.childId, { kind: 'user', parentSessionId: child.parentSessionId });
      return { accepted: true };
    }
    if (p.operation === 'send') {
      const agent = await this.sessions.agent(child.parentSessionId);
      const rootAgent = p.sessionId === child.parentSessionId ? agent : await this.sessions.agent(p.sessionId);
      const { group, generation } = await this.sessions.begin(p.sessionId, rootAgent);
      try {
        await this.ctx.subagents.prompt({ parentSessionId: child.parentSessionId, childSessionId: p.childId,
          mode: 'continuable', delivery: 'steer', requestId: p.requestId ?? randomUUID(),
          content: [{ type: 'text', text: p.text }] }, signal);
        this.reconcile(p.sessionId);
        return { accepted: true };
      } finally { setImmediate(() => void this.sessions.settle(p.sessionId, rootAgent, group, generation)); }
    }
    throw new Error('Unknown subagent operation');
  }
}
